--!nonstrict
-- Background service for simple-tailscale: monitors connection & exit nodes

local POLL_CONNECTED_MS = 2000
local POLL_DISCONNECTED_MS = 4000
local BUSY_TIMEOUT_MS = 15000
local POLL_TIMEOUT_MS = 12000

local backendState = "Stopped"
local isRunning = false
local needsLogin = false
local authUrl = ""
local activeExitNode = nil -- { id = string, name = string, ip = string, online = bool } or nil
local exitNodes = {} -- array of exit node tables
local isBusy = false
local busySince = 0

local pollInFlight = false
local pollStartedAt = 0
local pollGeneration = 0
local lastSignature = ""
local lastCmdSeq = -1

local CONNECT_CMD = "(curl -sf --unix-socket /run/tailscale/tailscaled.sock -X PATCH -H 'Content-Type: application/json' -d '{\"WantRunningSet\":true,\"WantRunning\":true}' http://local-tailscaled.sock/localapi/v0/prefs >/dev/null 2>&1 || tailscale up --timeout=5s >/dev/null 2>&1 || true); "
  .. "for i in 1 2 3 4 5 6 7 8 9 10 11 12; do "
  .. "st=$(tailscale status --json 2>/dev/null); "
  .. "case \"$st\" in "
  .. "*'\"BackendState\": \"Running\"'*) break ;; "
  .. "*'\"BackendState\": \"NeedsLogin\"'*) "
  .. "case \"$st\" in *'\"AuthURL\": \"http'*) break ;; "
  .. "*) if [ \"$i\" = \"2\" ]; then curl -sf --unix-socket /run/tailscale/tailscaled.sock -X POST http://local-tailscaled.sock/localapi/v0/login-interactive >/dev/null 2>&1 || true; fi ;; "
  .. "esac ;; "
  .. "esac; "
  .. "sleep 0.25; "
  .. "done"

local DISCONNECT_CMD = "curl -sf --unix-socket /run/tailscale/tailscaled.sock -X PATCH -H 'Content-Type: application/json' -d '{\"WantRunningSet\":true,\"WantRunning\":false}' http://local-tailscaled.sock/localapi/v0/prefs >/dev/null 2>&1 || tailscale down"

local function nowMs()
  if type(noctalia.nowMs) == "function" then
    local ms = noctalia.nowMs()
    if type(ms) == "number" and ms > 0 then
      return ms
    end
  end
  return os.time() * 1000
end

local function trim(s)
  return noctalia.string.trim(tostring(s or ""))
end

local function shellQuote(s)
  return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function openBrowserUrl(url)
  local clean = trim(url)
  if clean:match("^https?://[%w%.%-%_%~%:%/%?%#%[%]%@%!%$%&%'%(%)%*%+%,%;%=%%]+$") then
    local q = shellQuote(clean)
    noctalia.runAsync("gio open " .. q .. " || xdg-open " .. q)
  end
end

local function cleanTailscaleName(dnsName, fallbackHost)
  local raw = tostring(dnsName or "")
  if raw ~= "" then
    -- Strip trailing dot and tailnet domain suffixes (e.g. .my-tailnet.ts.net. -> exit-node)
    local short = raw:match("^([^.]+)")
    if short and short ~= "" then
      return short
    end
  end
  return fallbackHost or ""
end

local function firstIPv4(ips)
  if type(ips) ~= "table" then return "" end
  for _, ip in ipairs(ips) do
    local s = tostring(ip or ""):gsub("/.*$", "")
    if s:match("^%d+%.%d+%.%d+%.%d+$") then
      return s
    end
  end
  return tostring(ips[1] or ""):gsub("/.*$", "")
end

local function buildSignature()
  local parts = {
    backendState,
    tostring(isRunning),
    tostring(needsLogin),
    authUrl,
    tostring(isBusy),
    activeExitNode and (activeExitNode.id .. ":" .. tostring(activeExitNode.online)) or "",
  }
  for _, n in ipairs(exitNodes) do
    table.insert(parts, table.concat({
      tostring(n.id),
      tostring(n.name),
      tostring(n.ip),
      tostring(n.online),
      tostring(n.selected),
    }, ":"))
  end
  return table.concat(parts, "|")
end

local function publishState(force)
  local sig = buildSignature()
  if not force and sig == lastSignature then
    return
  end
  lastSignature = sig

  noctalia.state.set("ts_state", {
    backendState = backendState,
    running = isRunning,
    needsLogin = needsLogin,
    authUrl = authUrl,
    activeExitNode = activeExitNode,
    exitNodes = exitNodes,
    busy = isBusy,
  })
  noctalia.state.set("ts_running", isRunning)
  noctalia.state.set("ts_needs_login", needsLogin)
  noctalia.state.set("ts_auth_url", authUrl)
  noctalia.state.set("ts_exit_node", activeExitNode)
  noctalia.state.set("ts_exit_nodes", exitNodes)
  noctalia.state.set("ts_busy", isBusy)
end

local function parseStatus(jsonStr)
  if not jsonStr or jsonStr == "" then return false end
  local ok, data = pcall(function() return noctalia.json.decode(jsonStr) end)
  if not ok or type(data) ~= "table" then return false end

  backendState = tostring(data.BackendState or "Stopped")
  isRunning = (backendState == "Running")
  needsLogin = (backendState == "NeedsLogin")
  authUrl = trim(data.AuthURL)

  local exitStatusId = ""
  if type(data.ExitNodeStatus) == "table" and data.ExitNodeStatus.ID then
    exitStatusId = tostring(data.ExitNodeStatus.ID)
  end

  local peers = data.Peer or {}
  local nodes = {}
  local currentExit = nil

  for peerId, peer in pairs(peers) do
    if type(peer) == "table" then
      local peerNodeId = tostring(peer.ID or peerId)
      local isExit = (peer.ExitNode == true) or (exitStatusId ~= "" and peerNodeId == exitStatusId)
      if peer.ExitNodeOption == true or isExit then
        local ip = firstIPv4(peer.TailscaleIPs)
        local name = cleanTailscaleName(peer.DNSName, peer.HostName or peerId)
        local isOnline = (peer.Online == true)

        local nodeObj = {
          id = tostring(peerId),
          name = name,
          ip = ip,
          online = isOnline,
          selected = isExit,
        }
        table.insert(nodes, nodeObj)

        if isExit then
          currentExit = nodeObj
        end
      end
    end
  end

  -- Sort by Tailscale name alphabetically
  table.sort(nodes, function(a, b) return a.name:lower() < b.name:lower() end)

  exitNodes = nodes
  activeExitNode = currentExit
  return true
end

local function refreshStatus(callback, forcePublish)
  local now = nowMs()
  if pollInFlight and not callback and (now - pollStartedAt) < POLL_TIMEOUT_MS then
    return
  end

  pollInFlight = true
  pollStartedAt = now
  pollGeneration = pollGeneration + 1
  local gen = pollGeneration

  local launched = noctalia.runAsync("tailscale status --json", function(result)
    if gen ~= pollGeneration then
      if callback then callback() end
      return
    end
    pollInFlight = false
    pollStartedAt = 0

    local out = ""
    if type(result) == "table" then
      out = result.stdout or ""
    elseif type(result) == "string" then
      out = result
    end
    if out ~= "" then
      parseStatus(out)
    end
    publishState(forcePublish == true)
    if callback then callback() end
  end, 10000)

  if not launched then
    pollInFlight = false
    pollStartedAt = 0
    publishState(forcePublish == true)
    if callback then callback() end
  end
end

local function executeCommand(cmdStr, onDone)
  isBusy = true
  busySince = nowMs()
  publishState(true)

  local launched = noctalia.runAsync(cmdStr, function(result)
    if type(result) == "table" and result.exitCode and result.exitCode ~= 0 then
      local errMsg = trim(result.stderr ~= "" and result.stderr or result.stdout)
      if errMsg ~= "" then
        noctalia.log("tailscale command failed: " .. errMsg)
        noctalia.notifyError("Tailscale", errMsg)
      end
    end
    refreshStatus(function()
      isBusy = false
      busySince = 0
      publishState(true)
      if onDone then onDone(result) end
    end, true)
  end, 15000)

  if not launched then
    isBusy = false
    busySince = 0
    publishState(true)
    if onDone then onDone(nil) end
  end
end

local function connectOrLogin()
  if needsLogin and authUrl ~= "" then
    openBrowserUrl(authUrl)
  end
  local openedUrl = (needsLogin and authUrl ~= "") and authUrl or ""
  executeCommand(CONNECT_CMD, function()
    if needsLogin and authUrl ~= "" and authUrl ~= openedUrl then
      openBrowserUrl(authUrl)
    end
  end)
end

noctalia.state.watch("ts_command", function(cmd)
  if type(cmd) ~= "table" then return end
  if type(cmd.seq) == "number" then
    if cmd.seq == lastCmdSeq then return end
    lastCmdSeq = cmd.seq
  end

  local action = cmd.action

  if action == "toggle_connect" then
    if isRunning then
      executeCommand(DISCONNECT_CMD)
    else
      connectOrLogin()
    end
  elseif action == "connect" or action == "login" then
    connectOrLogin()
  elseif action == "disconnect" then
    executeCommand(DISCONNECT_CMD)
  elseif action == "select_exit_node" then
    local target = trim(cmd.target)
    if target == "" then
      executeCommand("tailscale set --exit-node=")
    elseif not isRunning then
      executeCommand("tailscale set --exit-node=" .. shellQuote(target) .. " && " .. CONNECT_CMD, function()
        if needsLogin and authUrl ~= "" then
          openBrowserUrl(authUrl)
        end
      end)
    else
      executeCommand("tailscale set --exit-node=" .. shellQuote(target))
    end
  elseif action == "refresh" then
    refreshStatus(nil, true)
  end
end)

function update()
  local now = nowMs()
  if isBusy and busySince > 0 and (now - busySince) >= BUSY_TIMEOUT_MS then
    isBusy = false
    busySince = 0
    publishState(true)
  end
  if not isBusy then
    refreshStatus(nil, false)
  end
  local interval = (isRunning or needsLogin or backendState == "Starting") and POLL_CONNECTED_MS or POLL_DISCONNECTED_MS
  noctalia.setUpdateInterval(interval)
end

-- Initial state
publishState(true)
refreshStatus(nil, true)
noctalia.setUpdateInterval(POLL_CONNECTED_MS)
