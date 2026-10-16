--!nonstrict

local haUrlRaw = noctalia.getConfig("ha_url")
local haToken = noctalia.getConfig("ha_token")

local MANAGED_ENTITIES_FILE = "managed_entities.json"

local function nowMs()
  if type(noctalia.nowMs) == "function" then
    local ms = noctalia.nowMs()
    if type(ms) == "number" and ms > 0 then
      return ms
    end
  end
  return os.time() * 1000
end

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
    local ok, parsed = pcall(function()
      return noctalia.json.decode(data)
    end)
    if ok and type(parsed) == "table" then return parsed end
  end
  return {}
end

local entities = {}
local managedSet = {}

local function setEntities(list)
  entities = {}
  managedSet = {}
  if type(list) == "table" then
    for _, id in ipairs(list) do
      if type(id) == "string" and id ~= "" and not managedSet[id] then
        managedSet[id] = true
        table.insert(entities, id)
      end
    end
  end
  -- Also include any configured shortcut entities so they stay live
  for i = 1, 4 do
    local sEid = noctalia.getConfig("shortcut_entity_" .. tostring(i))
    if type(sEid) == "string" and sEid ~= "" and not managedSet[sEid] then
      managedSet[sEid] = true
      table.insert(entities, sEid)
    end
  end
end

setEntities(loadManagedEntities())

local function buildSnapshotTemplate()
  local nonMediaIds = {}
  for _, id in ipairs(entities) do
    if type(id) == "string" and id ~= "" and not id:match("^media_player%.") then
      table.insert(nonMediaIds, id)
    end
  end
  local idsJson = noctalia.json.encode(nonMediaIds) or "[]"
  return [=[[{% set ns = namespace(first=true) %}{% for eid in ]=]
    .. idsJson
    .. [=[ %}{% set s = states[eid] %}{% if s %}{% if not ns.first %},{% endif %}{% set ns.first = false %}{"entity_id":{{ s.entity_id | tojson }},"state":{{ s.state | tojson }},"attributes":{"friendly_name":{{ s.attributes.get("friendly_name", "") | tojson }},"unit_of_measurement":{{ s.attributes.get("unit_of_measurement", "") | tojson }},"icon":{{ s.attributes.get("icon") | tojson }},"brightness":{{ s.attributes.get("brightness") | tojson }},"color_temp_kelvin":{{ s.attributes.get("color_temp_kelvin") | tojson }},"color_temp":{{ s.attributes.get("color_temp") | tojson }},"rgb_color":{{ s.attributes.get("rgb_color") | tojson }},"hs_color":{{ s.attributes.get("hs_color") | tojson }},"supported_color_modes":{{ s.attributes.get("supported_color_modes", []) | tojson }}}}{% endif %}{% endfor %}{% for s in states.media_player %}{% if not ns.first %},{% endif %}{% set ns.first = false %}{"entity_id":{{ s.entity_id | tojson }},"state":{{ s.state | tojson }},"attributes":{"friendly_name":{{ s.attributes.get("friendly_name", "") | tojson }},"volume_level":{{ (s.attributes.get("volume_level") | tojson) }},"is_volume_muted":{{ (s.attributes.get("is_volume_muted") | tojson) }},"media_title":{{ (s.attributes.get("media_title") | tojson) }},"media_artist":{{ (s.attributes.get("media_artist") | tojson) }},"media_album_name":{{ (s.attributes.get("media_album_name") | tojson) }},"entity_picture":{{ (s.attributes.get("entity_picture") | tojson) }},"group_members":{{ (s.attributes.get("group_members", []) | tojson) }},"mass_player_type":{{ (s.attributes.get("mass_player_type") | tojson) }},"app_id":{{ (s.attributes.get("app_id") | tojson) }},"supported_features":{{ (s.attributes.get("supported_features", 0) | tojson) }}}}{% endfor %}]]=]
end

local status = "unconfigured"
local entityStates = {}
local sseActive = false
local streamHandle = nil
local lastStreamActivityMs = 0

local MAX_RECONNECT_RETRIES = 10
local CONNECTED_POLL_INTERVAL_MS = 1000
local RECONNECT_POLL_INTERVAL_MS = 1000
local BACKOFF_POLL_INTERVAL_MS = 60000
-- The host allows 30s transfer + 10s connect, so past 35s the callback is gone.
local REQUEST_TIMEOUT_MS = 35000
-- The host allows 8 async callbacks per runtime.
local MAX_SNAPSHOT_REQUESTS_IN_FLIGHT = 4
local ENTITY_FLUSH_INTERVAL_MS = 150
local SNAPSHOT_COOLDOWN_MS = 600
-- HA sends "data: ping" every 50s on /api/stream; >65s of silence means the stream died silently.
local STREAM_SILENCE_TIMEOUT_MS = 65000

local retryCount = 0
local maxRetriesNotified = false
local authFailureNotified = false
local backoff = false
local connectionRequestInFlight = false
local requestStartedAtMs = nil

local entitiesDirty = false
local lastEntityFlushMs = 0

local snapshotToken = 0
local snapshotActive = false
local snapshotStartedAtMs = 0
local lastSnapshotAtMs = 0
local snapshotQueue = {}
local snapshotPending = {}
local snapshotInFlight = 0

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
        if callback then callback({ ok = false, status = 0, body = "No response" }) end
        return
      end

      if callback then
        callback({
          ok = response.status >= 200 and response.status < 300,
          status = response.status,
          body = response.body
        })
      end
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

  -- Stored in Kelvin (2000..6500) for the panel slider
  local colorTemp = -1
  if attrs.color_temp_kelvin and attrs.color_temp_kelvin > 0 then
    colorTemp = math.floor(attrs.color_temp_kelvin + 0.5)
  elseif attrs.color_temp and attrs.color_temp > 0 then
    if attrs.color_temp > 1000 then
      colorTemp = math.floor(attrs.color_temp + 0.5)
    else
      colorTemp = math.floor(1000000 / attrs.color_temp + 0.5)
    end
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
  lastEntityFlushMs = nowMs()
end

-- Every publish is re-decoded by every watcher, so bursts get coalesced over wall-clock ms.
local function markEntitiesDirty()
  entitiesDirty = true
  if (nowMs() - lastEntityFlushMs) >= ENTITY_FLUSH_INTERVAL_MS then
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

local function haServiceCall(endpoint, payload)
  haRequest(endpoint, "POST", payload, function(res)
    if res.ok and res.body and res.body ~= "" then
      local ok, changed = pcall(function()
        return noctalia.json.decode(res.body)
      end)
      if ok and type(changed) == "table" then
        for _, st in ipairs(changed) do
          if type(st) == "table" and st.entity_id then
            updateEntity(st.entity_id, st)
          end
        end
      end
    end
  end)
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
  local data = currentEvent.data
  if not data or data == "" or data == "ping" then return end
  local quickEid = data:match('"entity_id"%s*:%s*"([^"]+)"')
  if quickEid and not isManaged(quickEid) then return end

  local ok, parsed = pcall(function()
    return noctalia.json.decode(data)
  end)
  if not ok or type(parsed) ~= "table" then return end
  if eventTypeOf(parsed) ~= "state_changed" then return end
  local inner = parsed.data or {}
  if inner.entity_id and inner.new_state then
    updateEntity(inner.entity_id, inner.new_state)
  end
end

local function processSSELine(rawLine)
  lastStreamActivityMs = nowMs()
  if type(rawLine) ~= "string" then return end
  local line = rawLine:gsub("\r$", "")

  if line == "" then
    tryDispatch()
    currentEvent = {}
  elseif line:match("^event:") then
    if currentEvent.data and currentEvent.data ~= "" then tryDispatch() end
    currentEvent = { event = line:match("^event:%s*(.+)") or "" }
  elseif line:match("^data:") then
    local data = line:match("^data:%s*(.+)") or ""
    if data == "" or data == "ping" then
      currentEvent = {}
      return
    end
    -- Fast pre-filter before full JSON decode: skip unmanaged entities (99% of HA sensor noise)
    local quickEid = data:match('"entity_id"%s*:%s*"([^"]+)"')
    if quickEid and not isManaged(quickEid) then
      currentEvent = {}
      return
    end

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
  for eid, state in pairs(snapshotPending) do
    if eid:match("^media_player%.") then
      merged[eid] = state
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
        local ok, state = pcall(function()
          return noctalia.json.decode(res.body)
        end)
        if ok and type(state) == "table" and state.entity_id then
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

function fetchSnapshot(force)
  local now = nowMs()
  if not force and snapshotActive and (now - snapshotStartedAtMs) < SNAPSHOT_COOLDOWN_MS then
    return
  end
  if not force and not snapshotActive and (now - lastSnapshotAtMs) < SNAPSHOT_COOLDOWN_MS then
    return
  end

  snapshotToken = snapshotToken + 1
  local token = snapshotToken
  snapshotActive = true
  snapshotStartedAtMs = now
  lastSnapshotAtMs = now
  snapshotInFlight = 0
  snapshotPending = {}
  snapshotQueue = {}

  -- Single combined request via Home Assistant template API for all managed entities + media players
  local tpl = buildSnapshotTemplate()
  local launched = haRequest("/api/template", "POST", { template = tpl }, function(res)
    if token ~= snapshotToken then return end
    if res.ok and res.body and res.body ~= "" then
      local ok, allItems = pcall(function()
        return noctalia.json.decode(res.body)
      end)
      if ok and type(allItems) == "table" then
        local seenMediaPlayers = {}
        for _, s in ipairs(allItems) do
          local eid = type(s) == "table" and s.entity_id or nil
          if type(eid) == "string" and eid ~= "" then
            local processed = processEntity(s)
            if processed then
              -- Keep any fresher SSE update that arrived while the template request was in flight
              local finalState = snapshotPending[eid] or processed
              entityStates[eid] = finalState
              snapshotPending[eid] = finalState
              if eid:match("^media_player%.") then
                seenMediaPlayers[eid] = true
              end
            end
          end
        end
        for eid in pairs(entityStates) do
          if eid:match("^media_player%.") and not seenMediaPlayers[eid] then
            entityStates[eid] = nil
          end
        end
        finishSnapshot()
        return
      end
    end

    -- Fallback to individual /api/states/<entity_id> GET requests if template failed
    for _, id in ipairs(entities) do
      if type(id) == "string" and id ~= "" then
        table.insert(snapshotQueue, id)
      end
    end
    pumpSnapshot()
  end)

  if not launched then
    snapshotActive = false
  end
end

function connect()
  if not isConfigured() or connectionRequestInFlight then return end

  requestStartedAtMs = nowMs()
  connectionRequestInFlight = true

  local launched = haRequest("/api/", "GET", nil, function(res)
    connectionRequestInFlight = false
    requestStartedAtMs = nil

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

    fetchSnapshot(true)
    syncUpdateInterval()
  end)

  if not launched then
    connectionRequestInFlight = false
    requestStartedAtMs = nil
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
  lastStreamActivityMs = nowMs()

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
  if type(cmd) == "table" then
    cmd = cmd.action
  end
  if cmd == "refresh" then
    if status == "connected" then
      if not sseActive then startSSEStream() end
      fetchSnapshot(false)
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
    if status == "connected" then
      fetchSnapshot(true)
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
      fetchSnapshot(false)
    else
      connect()
    end
  end
end)

-- Accept optimistic updates and service response states from panels/shortcuts/widgets
noctalia.state.watch("entity_patch", function(patchMsg)
  if type(patchMsg) ~= "table" then return end
  local updated = false

  if type(patchMsg.states) == "table" then
    for _, st in ipairs(patchMsg.states) do
      if type(st) == "table" and type(st.entity_id) == "string" and isManaged(st.entity_id) then
        local processed = processEntity(st)
        if processed then
          entityStates[st.entity_id] = processed
          if snapshotActive then snapshotPending[st.entity_id] = processed end
          updated = true
        end
      end
    end
  end

  if type(patchMsg.eid) == "string" and type(patchMsg.fields) == "table" then
    local eid = patchMsg.eid
    local cur = entityStates[eid]
    if cur then
      for k, v in pairs(patchMsg.fields) do
        cur[k] = v
      end
      if snapshotActive and snapshotPending[eid] then
        for k, v in pairs(patchMsg.fields) do
          snapshotPending[eid][k] = v
        end
      end
      updated = true
    end
  end

  if updated then
    publishEntities()
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

  local now = nowMs()

  if entitiesDirty and (now - lastEntityFlushMs) >= ENTITY_FLUSH_INTERVAL_MS then
    publishEntities()
  end

  if snapshotActive then
    if (now - snapshotStartedAtMs) > REQUEST_TIMEOUT_MS then
      noctalia.log("Entity snapshot timed out; publishing what arrived")
      finishSnapshot()
    elseif #snapshotQueue > 0 then
      pumpSnapshot()
    end
  end

  if connectionRequestInFlight and (now - (requestStartedAtMs or 0)) > REQUEST_TIMEOUT_MS then
    connectionRequestInFlight = false
    requestStartedAtMs = nil
    setStatus("disconnected", "request timed out")
  end

  if status == "connected" and not sseActive then
    setStatus("disconnected", "stream missing")
  end

  -- Stream inactivity watchdog: HA sends "data: ping" every 50s on /api/stream.
  -- Only restart the stream if it has been completely silent for >65s.
  if status == "connected" and sseActive and lastStreamActivityMs > 0 then
    if (now - lastStreamActivityMs) > STREAM_SILENCE_TIMEOUT_MS then
      noctalia.log("SSE stream silent for >65s; restarting connection")
      if streamHandle then
        streamHandle.stop()
        streamHandle = nil
      end
      sseActive = false
      setStatus("disconnected", "stream silent timeout")
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

local function getAvailableSpeakers()
  local rawSpeakers = {}
  local hasMaSpeakers = false
  for eid, entity in pairs(entityStates) do
    if entity.domain == "media_player" then
      local st = entity.state
      if st and st ~= "unavailable" and st ~= "unknown" then
        table.insert(rawSpeakers, entity)
        if entity.mass_player_type and entity.mass_player_type ~= "" then
          hasMaSpeakers = true
        end
      end
    end
  end

  local activeSpeakers = {}
  if hasMaSpeakers then
    for _, entity in ipairs(rawSpeakers) do
      if entity.mass_player_type and entity.mass_player_type ~= "" then
        table.insert(activeSpeakers, entity)
      end
    end
  else
    activeSpeakers = rawSpeakers
  end

  table.sort(activeSpeakers, function(a, b)
    local nameA = (a.friendly_name or a.entity_id or ""):lower()
    local nameB = (b.friendly_name or b.entity_id or ""):lower()
    return nameA < nameB
  end)

  return activeSpeakers
end

local function resolveSelectedSpeaker()
  local availableSpeakers = getAvailableSpeakers()
  if #availableSpeakers == 0 then
    return nil, nil
  end

  local availableMap = {}
  for _, spk in ipairs(availableSpeakers) do
    availableMap[spk.entity_id] = spk
  end

  -- Find currently playing speakers
  local playing = {}
  for _, spk in ipairs(availableSpeakers) do
    if spk.state == "playing" then
      table.insert(playing, spk.entity_id)
    end
  end

  -- 1. "by default, it should be on the currently playing speaker"
  if #playing == 1 then
    return playing[1], availableMap[playing[1]]
  end

  -- 2. "and if that isn't available or if there are a few, it should go to latest choosen speaker"
  local lastChosen = noctalia.state.get("last_chosen_speaker")
  if lastChosen and availableMap[lastChosen] then
    return lastChosen, availableMap[lastChosen]
  end

  if #playing > 0 then
    return playing[1], availableMap[playing[1]]
  end

  return availableSpeakers[1].entity_id, availableSpeakers[1]
end

function onIpc(event, payload)
  if not event or event == "" then return end
  event = event:lower()

  if event == "toggle_pause" or event == "toggle-pause" or event == "play_pause" or event == "play-pause" or event == "toggle" then
    local targetEid, targetEntity = resolveSelectedSpeaker()
    if not targetEid then return end
    local isPlaying = targetEntity and targetEntity.state == "playing"
    if targetEntity then
      targetEntity.state = isPlaying and "paused" or "playing"
      publishEntities()
    end
    haServiceCall("/api/services/media_player/media_play_pause", { entity_id = targetEid })
    local name = targetEntity and targetEntity.friendly_name or targetEid
    noctalia.notify("Music Assistant", (isPlaying and "Pausing " or "Playing on ") .. name)

  elseif event == "play" then
    local targetEid, targetEntity = resolveSelectedSpeaker()
    if not targetEid then return end
    if targetEntity then
      targetEntity.state = "playing"
      publishEntities()
    end
    haServiceCall("/api/services/media_player/media_play", { entity_id = targetEid })
    local name = targetEntity and targetEntity.friendly_name or targetEid
    noctalia.notify("Music Assistant", "Playing on " .. name)

  elseif event == "pause" then
    local targetEid, targetEntity = resolveSelectedSpeaker()
    if not targetEid then return end
    if targetEntity then
      targetEntity.state = "paused"
      publishEntities()
    end
    haServiceCall("/api/services/media_player/media_pause", { entity_id = targetEid })
    local name = targetEntity and targetEntity.friendly_name or targetEid
    noctalia.notify("Music Assistant", "Pausing " .. name)

  elseif event == "stop" then
    local targetEid, targetEntity = resolveSelectedSpeaker()
    if not targetEid then return end
    if targetEntity then
      targetEntity.state = "idle"
      publishEntities()
    end
    haServiceCall("/api/services/media_player/media_stop", { entity_id = targetEid })
    local name = targetEntity and targetEntity.friendly_name or targetEid
    noctalia.notify("Music Assistant", "Stopped " .. name)

  elseif event == "next" or event == "next_track" or event == "next-track" then
    local targetEid = resolveSelectedSpeaker()
    if not targetEid then return end
    haServiceCall("/api/services/media_player/media_next_track", { entity_id = targetEid })

  elseif event == "previous" or event == "previous_track" or event == "previous-track" or event == "prev" then
    local targetEid = resolveSelectedSpeaker()
    if not targetEid then return end
    haServiceCall("/api/services/media_player/media_previous_track", { entity_id = targetEid })

  elseif event == "volume_up" or event == "volume-up" or event == "volume_down" or event == "volume-down" then
    local targetEid, targetEntity = resolveSelectedSpeaker()
    if not targetEid then return end
    local step = tonumber(payload) or 0.05
    if step > 1.0 then step = step / 100.0 end

    local currentVol = targetEntity and targetEntity.volume_level or 0.5
    local newVol
    if event:match("up") then
      newVol = math.min(1.0, currentVol + step)
    else
      newVol = math.max(0.0, currentVol - step)
    end
    if targetEntity then
      targetEntity.volume_level = newVol
      if entityStates[targetEid] then
        entityStates[targetEid].volume_level = newVol
      end
      publishEntities()
    end
    haServiceCall("/api/services/media_player/volume_set", { entity_id = targetEid, volume_level = newVol })
    local name = targetEntity and targetEntity.friendly_name or targetEid
    noctalia.notify(name, string.format("Volume: %d%%", math.floor(newVol * 100 + 0.5)))

  elseif event == "volume_mute" or event == "volume-mute" or event == "mute" then
    local targetEid, targetEntity = resolveSelectedSpeaker()
    if not targetEid then return end
    local isMuted = targetEntity and targetEntity.is_volume_muted or false
    local newMuted = not isMuted
    if targetEntity then
      targetEntity.is_volume_muted = newMuted
      if entityStates[targetEid] then
        entityStates[targetEid].is_volume_muted = newMuted
      end
      publishEntities()
    end
    haServiceCall("/api/services/media_player/volume_mute", { entity_id = targetEid, is_volume_muted = newMuted })
    local name = targetEntity and targetEntity.friendly_name or targetEid
    noctalia.notify(name, newMuted and "Muted" or "Unmuted")

  elseif event == "select_speaker" or event == "set_speaker" then
    if payload and payload ~= "" then
      local matchedEid = nil
      for eid, e in pairs(entityStates) do
        if e.domain == "media_player" then
          if eid == payload or (e.friendly_name and e.friendly_name:lower() == payload:lower()) then
            matchedEid = eid
            break
          end
        end
      end
      if matchedEid then
        noctalia.state.set("last_chosen_speaker", matchedEid)
        local name = entityStates[matchedEid] and entityStates[matchedEid].friendly_name or matchedEid
        noctalia.notify("Music Assistant", "Selected: " .. name)
      end
    end
  end
end

noctalia.state.set("connection_status", status)
noctalia.state.set("entity_count", 0)
noctalia.state.set("entities", {})

if isConfigured() then
  setStatus("connecting", "startup")
  connect()
end

syncUpdateInterval()
