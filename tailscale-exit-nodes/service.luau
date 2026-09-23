--!nonstrict
-- Background service for simple-tailscale: monitors connection & exit nodes

local POLL_CONNECTED_MS = 2000
local POLL_DISCONNECTED_MS = 4000

local isRunning = false
local activeExitNode = nil -- { id = string, name = string, ip = string, online = bool } or nil
local exitNodes = {} -- array of exit node tables
local isBusy = false

local function trim(s)
  return noctalia.string.trim(tostring(s or ""))
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

local function parseStatus(jsonStr)
  if not jsonStr or jsonStr == "" then return end
  local ok, data = pcall(function() return noctalia.json.decode(jsonStr) end)
  if not ok or type(data) ~= "table" then return end

  local backendState = data.BackendState or "Stopped"
  isRunning = (backendState == "Running")

  local peers = data.Peer or {}
  local nodes = {}
  local currentExit = nil

  for peerId, peer in pairs(peers) do
    if peer.ExitNodeOption == true then
      local ip = (peer.TailscaleIPs and peer.TailscaleIPs[1]) or ""
      local name = cleanTailscaleName(peer.DNSName, peer.HostName or peerId)
      local isExit = (peer.ExitNode == true)
      local isOnline = (peer.Online == true)

      local nodeObj = {
        id = peerId,
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

  -- Sort by Tailscale name alphabetically
  table.sort(nodes, function(a, b) return a.name:lower() < b.name:lower() end)

  exitNodes = nodes
  activeExitNode = currentExit

  noctalia.state.set("ts_running", isRunning)
  noctalia.state.set("ts_exit_node", activeExitNode)
  noctalia.state.set("ts_exit_nodes", exitNodes)
  noctalia.state.set("ts_busy", isBusy)
end

local function refreshStatus(callback)
  noctalia.runAsync("tailscale status --json", function(result)
    local out = ""
    if type(result) == "table" then
      out = result.stdout or ""
    elseif type(result) == "string" then
      out = result
    end
    if out ~= "" then
      parseStatus(out)
    end
    if callback then callback() end
  end, 10000)
end

local function executeCommand(cmdStr)
  isBusy = true
  noctalia.state.set("ts_busy", true)
  noctalia.runAsync(cmdStr, function()
    refreshStatus(function()
      isBusy = false
      noctalia.state.set("ts_busy", false)
    end)
  end, 20000)
end

noctalia.state.watch("ts_command", function(cmd)
  if type(cmd) ~= "table" then return end
  local action = cmd.action

  if action == "toggle_connect" then
    if isRunning then
      executeCommand("tailscale down")
    else
      executeCommand("tailscale up --operator=$USER")
    end
  elseif action == "connect" then
    executeCommand("tailscale up --operator=$USER")
  elseif action == "disconnect" then
    executeCommand("tailscale down")
  elseif action == "select_exit_node" then
    local target = cmd.target or ""
    if target == "" then
      executeCommand("tailscale set --exit-node=")
    else
      if not isRunning then
        executeCommand("tailscale up --operator=$USER --exit-node=" .. target)
      else
        executeCommand("tailscale set --exit-node=" .. target)
      end
    end
  elseif action == "refresh" then
    refreshStatus()
  end
end)

function update()
  if not isBusy then
    refreshStatus()
  end
  noctalia.setUpdateInterval(isRunning and POLL_CONNECTED_MS or POLL_DISCONNECTED_MS)
end

-- Initial state
noctalia.state.set("ts_running", false)
noctalia.state.set("ts_exit_node", nil)
noctalia.state.set("ts_exit_nodes", {})
noctalia.state.set("ts_busy", false)

refreshStatus()
noctalia.setUpdateInterval(POLL_CONNECTED_MS)
