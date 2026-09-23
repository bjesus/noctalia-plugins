--!nonstrict

local haUrlRaw = noctalia.getConfig("ha_url")
local haToken = noctalia.getConfig("ha_token")

local MANAGED_ENTITIES_FILE = "managed_entities.json"

local function getCleanUrl()
  local u = noctalia.getConfig("ha_url")
  if type(u) ~= "string" or u == "" then u = haUrlRaw end
  if type(u) ~= "string" then return "" end
  return (u:gsub("/+$", ""))
end

local function getCleanToken()
  local t = noctalia.getConfig("ha_token")
  if type(t) ~= "string" or t == "" then t = haToken end
  if type(t) ~= "string" then return "" end
  return noctalia.string.trim(t)
end

local function extractMediaPlayers(raw)
  if type(raw) ~= "string" or raw == "" then return {} end
  local list = {}
  local pos = 1
  local len = #raw
  while pos <= len do
    local s1, e1 = raw:find('"entity_id":"media_player.', pos, true)
    local s2, e2 = raw:find('"entity_id": "media_player.', pos, true)
    local s, e
    if s1 and s2 then
      if s1 < s2 then s, e = s1, e1 else s, e = s2, e2 end
    elseif s1 then
      s, e = s1, e1
    elseif s2 then
      s, e = s2, e2
    else
      break
    end

    local objStart = s
    while objStart > 1 and raw:byte(objStart) ~= 123 do
      objStart = objStart - 1
    end

    local depth = 0
    local inStr = false
    local esc = false
    local objEnd = nil
    for i = objStart, len do
      local b = raw:byte(i)
      if esc then
        esc = false
      elseif b == 92 then
        esc = true
      elseif b == 34 then
        inStr = not inStr
      elseif not inStr then
        if b == 123 then
          depth = depth + 1
        elseif b == 125 then
          depth = depth - 1
          if depth == 0 then
            objEnd = i
            break
          end
        end
      end
    end

    if objEnd then
      local chunk = raw:sub(objStart, objEnd)
      local ok, parsed = pcall(function()
        return noctalia.json.decode(chunk)
      end)
      if ok and type(parsed) == "table" and parsed.entity_id then
        table.insert(list, parsed)
      end
      pos = objEnd + 1
    else
      pos = e + 1
    end
  end
  return list
end

local function isConfigured()
  return getCleanUrl() ~= "" and getCleanToken() ~= ""
end

local function loadManagedEntities()
  local dataDir, dirErr = noctalia.pluginDataDir()
  if not dataDir then
    noctalia.log("Cannot resolve plugin data dir: " .. (dirErr or "unknown"))
    return {}
  end

  local data = noctalia.readFile(dataDir .. "/" .. MANAGED_ENTITIES_FILE)
  if data and data ~= "" then
    local parsed = noctalia.json.decode(data)
    if type(parsed) == "table" then return parsed end
  end
  return {}
end

local entities = {}
local managedSet = {}

local function setEntities(list)
  entities = list
  managedSet = {}
  for _, id in ipairs(entities) do
    managedSet[id] = true
  end
end

setEntities(loadManagedEntities())

local status = "unconfigured"
local entityStates = {}
local sseActive = false
local streamHandle = nil

local MAX_RECONNECT_RETRIES = 10
local CONNECTED_POLL_INTERVAL_MS = 1000
local RECONNECT_POLL_INTERVAL_MS = 1000
local BACKOFF_POLL_INTERVAL_MS = 60000
-- The host allows 30s transfer + 10s connect, so past 35s the callback is gone.
local REQUEST_TIMEOUT_SECONDS = 35
-- The host allows 8 async callbacks per runtime.
local MAX_SNAPSHOT_REQUESTS_IN_FLIGHT = 4
local ENTITY_FLUSH_INTERVAL_SECONDS = 0.2

local retryCount = 0
local maxRetriesNotified = false
local authFailureNotified = false
local backoff = false
local connectionRequestInFlight = false
local requestStartedAt = nil

local entitiesDirty = false
local lastEntityFlush = 0

local snapshotToken = 0
local snapshotActive = false
local snapshotStartedAt = 0
local snapshotQueue = {}
local snapshotPending = {}
local snapshotInFlight = 0

local lastWatchdogProbe = 0
local WATCHDOG_INTERVAL_SECONDS = 15

local function syncUpdateInterval()
  if status == "connected" and sseActive then
    noctalia.setUpdateInterval(CONNECTED_POLL_INTERVAL_MS)
  elseif backoff then
    noctalia.setUpdateInterval(BACKOFF_POLL_INTERVAL_MS)
  else
    noctalia.setUpdateInterval(RECONNECT_POLL_INTERVAL_MS)
  end
end

local function setStatus(next, reason)
  if status == next then return end
  status = next
  noctalia.state.set("connection_status", status)
  noctalia.log("connection status -> " .. status .. (reason and (" (" .. reason .. ")") or ""))

  if status == "connected" then
    authFailureNotified = false
  elseif status == "auth_failed" and not authFailureNotified then
    authFailureNotified = true
    noctalia.notifyError(noctalia.tr("notifications.auth_failed"))
  end

  syncUpdateInterval()
end

local function haRequest(endpoint, method, body, callback)
  if not isConfigured() then return false end

  local url = getCleanUrl() .. endpoint
  local cleanToken = getCleanToken()

  local jsonBody
  if body then
    jsonBody = noctalia.json.encode(body)
  end

  local headers = {
    "Authorization: Bearer " .. cleanToken,
  }
  if jsonBody then
    table.insert(headers, "Content-Type: application/json")
  end

  return noctalia.http({
      url = url,
      method = method,
      body = jsonBody,
      headers = headers,
      allow_insecure_tls = true,
  }, function(response: HttpResponse)
      if not response then
        callback({ ok = false, status = 0, body = "No response" })
        return
      end

      callback({
        ok = response.status >= 200 and response.status < 300,
        status = response.status,
        body = response.body
      })
  end)
end

local function supportsColorMode(modes, targets)
  if type(modes) ~= "table" then return false end
  for _, mode in ipairs(modes) do
    for _, target in ipairs(targets) do
      if mode == target then return true end
    end
  end
  return false
end

local function processEntity(state)
  if not state then return nil end

  local attrs = state.attributes or {}
  local modes = attrs.supported_color_modes or {}

  -- stored as mireds for the panel slider
  local colorTemp = -1
  if attrs.color_temp_kelvin and attrs.color_temp_kelvin > 0 then
    colorTemp = math.floor(1000000 / attrs.color_temp_kelvin + 0.5)
  elseif attrs.color_temp and attrs.color_temp > 0 then
    colorTemp = attrs.color_temp
  end

  local currentColor = ""
  if type(attrs.rgb_color) == "table" and #attrs.rgb_color == 3 then
    currentColor = attrs.rgb_color[1] .. "," .. attrs.rgb_color[2] .. "," .. attrs.rgb_color[3]
  end

  return {
    entity_id = state.entity_id,
    state = state.state,
    friendly_name = attrs.friendly_name or state.entity_id,
    domain = state.entity_id:match("^([^.]+)"),
    unit = attrs.unit_of_measurement or "",
    icon = attrs.icon,
    brightness = attrs.brightness or -1,
    color_temp = colorTemp,
    hue = (type(attrs.hs_color) == "table") and (attrs.hs_color[1] or 0) or 0,
    current_color = currentColor,
    supports_brightness = supportsColorMode(modes, {"brightness","color_temp","hs","xy","rgb","rgbw","rgbww"}),
    supports_color_temp = supportsColorMode(modes, {"color_temp"}),
    supports_rgb = supportsColorMode(modes, {"hs","xy","rgb","rgbw","rgbww"}),
    -- Media player attributes
    volume_level = attrs.volume_level,
    is_volume_muted = attrs.is_volume_muted,
    media_title = attrs.media_title,
    media_artist = attrs.media_artist,
    media_album_name = attrs.media_album_name,
    entity_picture = attrs.entity_picture,
    group_members = attrs.group_members or {},
    app_id = attrs.app_id,
    mass_player_type = attrs.mass_player_type,
    supported_features = attrs.supported_features or 0,
  }
end

local function publishEntities()
  local count = 0
  for _ in pairs(entityStates) do
    count = count + 1
  end
  noctalia.state.set("entities", entityStates)
  noctalia.state.set("entity_count", count)
  entitiesDirty = false
  lastEntityFlush = os.clock()
end

-- Every publish is re-decoded by every watcher, so bursts get coalesced.
local function markEntitiesDirty()
  entitiesDirty = true
  if (os.clock() - lastEntityFlush) >= ENTITY_FLUSH_INTERVAL_SECONDS then
    publishEntities()
  end
end

local function isManaged(entityId)
  if type(entityId) == "string" and entityId:match("^media_player%.") then
    return true
  end
  return managedSet[entityId] == true
end

local function updateEntity(entityId, newState)
  if not isManaged(entityId) then return end

  local processed = processEntity(newState)
  if not processed then return end

  entityStates[entityId] = processed
  if snapshotActive then
    -- don't let the in-flight round overwrite fresher live data
    snapshotPending[entityId] = processed
  end
  markEntitiesDirty()
end

local currentEvent = {
    data = "",
    event = "",
}

local function eventTypeOf(parsed)
  if currentEvent.event and currentEvent.event ~= "" then
    return currentEvent.event
  end
  return parsed.event_type
end

local function tryDispatch()
  if not currentEvent.data or currentEvent.data == "" then return end
  local ok, parsed = pcall(function()
    return noctalia.json.decode(currentEvent.data)
  end)
  if not ok or type(parsed) ~= "table" then return end
  if eventTypeOf(parsed) ~= "state_changed" then return end
  local inner = parsed.data or {}
  if inner.entity_id and inner.new_state then
    updateEntity(inner.entity_id, inner.new_state)
  end
end

local function processSSELine(line)
  if line == "" then
    tryDispatch()
    currentEvent = {}
  elseif line:match("^event:") then
    if currentEvent.data then tryDispatch() end
    currentEvent = { event = line:match("^event:%s*(.+)") or "" }
  elseif line:match("^data:") then
    local data = line:match("^data:%s*(.+)") or ""
    local ok, parsed = pcall(function()
      return noctalia.json.decode(data)
    end)
    if ok and type(parsed) == "table" then
      if eventTypeOf(parsed) == "state_changed" then
        local inner = parsed.data or {}
        if inner.entity_id and inner.new_state then
          updateEntity(inner.entity_id, inner.new_state)
          currentEvent = {}
          return
        end
      end
    end
    if currentEvent.data and currentEvent.data ~= "" then
      currentEvent.data = currentEvent.data .. "\n" .. data
    else
      currentEvent.data = data
    end
  end
end

local pumpSnapshot
local finishSnapshot
local fetchSnapshot
local startSSEStream
local connect

function finishSnapshot()
  snapshotActive = false
  snapshotToken = snapshotToken + 1

  local merged = {}
  for _, id in ipairs(entities) do
    merged[id] = snapshotPending[id] or entityStates[id]
  end
  -- Preserve all media_players!
  for eid, state in pairs(entityStates) do
    if eid:match("^media_player%.") then
      merged[eid] = snapshotPending[eid] or state
    end
  end
  entityStates = merged
  snapshotPending = {}
  snapshotQueue = {}
  publishEntities()
end

function pumpSnapshot()
  if not snapshotActive then return end

  local token = snapshotToken

  while snapshotInFlight < MAX_SNAPSHOT_REQUESTS_IN_FLIGHT and #snapshotQueue > 0 do
    local entityId = snapshotQueue[1]
    snapshotInFlight = snapshotInFlight + 1

    local launched = haRequest("/api/states/" .. entityId, "GET", nil, function(res)
      if token ~= snapshotToken then return end
      snapshotInFlight = snapshotInFlight - 1

      if res.status == 404 then
        noctalia.log("Entity not found in Home Assistant: " .. entityId)
      elseif res.ok and res.body and res.body ~= "" then
        local state = noctalia.json.decode(res.body)
        if type(state) == "table" and state.entity_id then
          snapshotPending[entityId] = processEntity(state)
        end
      end

      pumpSnapshot()
      if snapshotActive and snapshotInFlight == 0 and #snapshotQueue == 0 then
        finishSnapshot()
      end
    end)

    if not launched then
      snapshotInFlight = snapshotInFlight - 1
      return
    end

    table.remove(snapshotQueue, 1)
  end

  if snapshotInFlight == 0 and #snapshotQueue == 0 then
    finishSnapshot()
  end
end

function fetchSnapshot()
  snapshotToken = snapshotToken + 1
  snapshotActive = true
  snapshotStartedAt = os.clock()
  snapshotInFlight = 0
  snapshotPending = {}
  snapshotQueue = {}
  local queueSet = {}
  for _, id in ipairs(entities) do
    if type(id) == "string" and id ~= "" then
      table.insert(snapshotQueue, id)
      queueSet[id] = true
    end
  end

  -- Fetch /api/states to discover all media_player entities automatically
  haRequest("/api/states", "GET", nil, function(res)
    if res.ok and res.body and res.body ~= "" then
      local mediaPlayers = extractMediaPlayers(res.body)
      local seenMediaPlayers = {}
      for _, s in ipairs(mediaPlayers) do
        local eid = type(s) == "table" and s.entity_id or nil
        if type(eid) == "string" and eid:match("^media_player%.") then
          local processed = processEntity(s)
          if processed then
            entityStates[eid] = processed
            snapshotPending[eid] = processed
            seenMediaPlayers[eid] = true
          end
        end
      end
      for eid in pairs(entityStates) do
        if eid:match("^media_player%.") and not seenMediaPlayers[eid] then
          entityStates[eid] = nil
        end
      end
      markEntitiesDirty()
    end
  end)

  pumpSnapshot()
end

function connect()
  if not isConfigured() or connectionRequestInFlight then return end

  requestStartedAt = os.clock()
  connectionRequestInFlight = true

  local launched = haRequest("/api/", "GET", nil, function(res)
    connectionRequestInFlight = false
    requestStartedAt = nil

    if res.status == 0 then
      noctalia.log("Cannot reach Home Assistant (connection failed)")
      setStatus("unreachable", "transport failure")
      return
    end

    if res.status == 401 or res.status == 403 then
      setStatus("auth_failed", "http " .. tostring(res.status))
      return
    end

    if not res.ok then
      noctalia.log("Home Assistant API probe failed: status " .. tostring(res.status))
      setStatus("disconnected", "http " .. tostring(res.status))
      return
    end

    retryCount = 0
    maxRetriesNotified = false
    backoff = false
    setStatus("connected", "api reachable")

    if not startSSEStream() then
      setStatus("disconnected", "stream failed to start")
      return
    end

    fetchSnapshot()
    syncUpdateInterval()
  end)

  if not launched then
    connectionRequestInFlight = false
    requestStartedAt = nil
    setStatus("unreachable", "request not launched")
  end
end

function startSSEStream()
  if sseActive then return true end

  local cleanToken = getCleanToken()
  if cleanToken == "" then
    return false
  end

  local url = getCleanUrl() .. "/api/stream?restrict=state_changed"

  noctalia.log("Starting SSE stream")
  currentEvent = { data = "", event = "" }

  local handle
  handle = noctalia.httpStream({
    url = url,
    headers = {
      "Accept: text/event-stream",
      "Authorization: Bearer " .. cleanToken,
    },
    allow_insecure_tls = true,
  }, function(line)
    processSSELine(line)
  end, function(result)
    if streamHandle ~= handle then return end

    streamHandle = nil
    sseActive = false
    currentEvent = {}

    if result and (result.status == 401 or result.status == 403) then
      setStatus("auth_failed", "stream http " .. tostring(result.status))
      return
    end

    -- 404 here means this HA serves no /api/stream, which otherwise looks like a flaky link.
    noctalia.log("SSE stream closed (status " .. tostring(result and result.status or 0) .. ")")
    setStatus("disconnected", "stream closed")
    syncUpdateInterval()
  end)

  if not handle then
    noctalia.log("Failed to start SSE stream")
    return false
  end

  streamHandle = handle
  sseActive = true
  syncUpdateInterval()
  return true
end

noctalia.state.watch("command", function(cmd)
  if cmd == "refresh" then
    -- Do NOT clear sseActive: that bypasses startSSEStream()'s duplicate guard.
    if status == "connected" then
      if not sseActive then startSSEStream() end
      fetchSnapshot()
    else
      connect()
    end
  elseif cmd == "reload_entities" then
    local override = noctalia.state.get("entities_override")
    if type(override) == "table" then
      setEntities(override)
    else
      setEntities(loadManagedEntities())
    end
    -- Filtering is client-side, so only the snapshot needs refetching.
    if status == "connected" then
      fetchSnapshot()
    else
      connect()
    end
  end
end)

noctalia.state.watch("panel_open_signal", function(value)
  if value then
    retryCount = 0
    maxRetriesNotified = false
    backoff = false
    syncUpdateInterval()
    if status == "connected" then
      if not sseActive then startSSEStream() end
      fetchSnapshot()
    else
      connect()
    end
  end
end)

function update()
  if not isConfigured() then
    setStatus("unconfigured", "no url or token")
    if streamHandle then
      streamHandle.stop()
      streamHandle = nil
    end
    sseActive = false
    syncUpdateInterval()
    return
  end

  if entitiesDirty and (os.clock() - lastEntityFlush) >= ENTITY_FLUSH_INTERVAL_SECONDS then
    publishEntities()
  end

  if snapshotActive then
    if (os.clock() - snapshotStartedAt) > REQUEST_TIMEOUT_SECONDS then
      noctalia.log("Entity snapshot timed out; publishing what arrived")
      finishSnapshot()
    else
      pumpSnapshot()
    end
  end

  if connectionRequestInFlight and (os.clock() - (requestStartedAt or 0)) > REQUEST_TIMEOUT_SECONDS then
    connectionRequestInFlight = false
    requestStartedAt = nil
    setStatus("disconnected", "request timed out")
  end

  if status == "connected" and not sseActive then
    setStatus("disconnected", "stream missing")
  end

  -- Watchdog: probe HA every 15s to detect silent stream drops
  if status == "connected" and sseActive and not snapshotActive then
    if (os.clock() - lastWatchdogProbe) >= WATCHDOG_INTERVAL_SECONDS then
      lastWatchdogProbe = os.clock()
      haRequest("/api/", "GET", nil, function(res)
        if not res.ok then
          noctalia.log("Watchdog: connection probe failed (" .. tostring(res.status) .. "), restarting connection")
          if streamHandle then
            streamHandle.stop()
            streamHandle = nil
          end
          sseActive = false
          setStatus("disconnected", "watchdog probe failed")
        end
      end)
    end
  end

  -- Reconverge the store in case a publish was dropped mid-callback.
  if noctalia.state.get("connection_status") ~= status then
    noctalia.state.set("connection_status", status)
  end

  if status ~= "connected" and not connectionRequestInFlight then
    retryCount = retryCount + 1
    if retryCount >= MAX_RECONNECT_RETRIES and not backoff then
      backoff = true
      if not maxRetriesNotified then
        maxRetriesNotified = true
        if not authFailureNotified then
          noctalia.notifyError(noctalia.tr("notifications.reconnect_failed", { count = MAX_RECONNECT_RETRIES }))
        end
      end
    end

    setStatus("connecting", "attempt " .. tostring(retryCount))
    connect()
  end

  syncUpdateInterval()
end

function onExit()
  if streamHandle then
    streamHandle.stop()
    streamHandle = nil
  end
  sseActive = false
  snapshotActive = false
end

noctalia.state.set("connection_status", status)
noctalia.state.set("entity_count", 0)
noctalia.state.set("entities", {})

if isConfigured() then
  setStatus("connecting", "startup")
  connect()
end

syncUpdateInterval()
