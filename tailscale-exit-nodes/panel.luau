--!nonstrict
-- Popup panel for Tailscale: clean connection toggle & exit node picker

local isRunning = noctalia.state.get("ts_running") or false
local needsLogin = noctalia.state.get("ts_needs_login") or false
local backendState = "Stopped"
local activeExitNode = noctalia.state.get("ts_exit_node")
local exitNodes = noctalia.state.get("ts_exit_nodes") or {}
local isBusy = noctalia.state.get("ts_busy") or false
local cmdSeq = 0

local function nowMs()
  if type(noctalia.nowMs) == "function" then
    local ms = noctalia.nowMs()
    if type(ms) == "number" and ms > 0 then
      return ms
    end
  end
  return os.time() * 1000
end

local function applyStateTable(st)
  if type(st) ~= "table" then return false end
  backendState = tostring(st.backendState or "Stopped")
  isRunning = st.running == true
  needsLogin = st.needsLogin == true
  activeExitNode = st.activeExitNode
  exitNodes = type(st.exitNodes) == "table" and st.exitNodes or {}
  isBusy = st.busy == true
  return true
end

applyStateTable(noctalia.state.get("ts_state"))

local function sendCommand(action, target)
  cmdSeq = cmdSeq + 1
  noctalia.state.set("ts_command", {
    seq = nowMs() * 1000 + cmdSeq,
    action = action,
    target = target,
  })
end

local function renderToggle(checked, enabled, onToggle)
  local trackFill = checked and "primary" or "surface_variant"
  local knobFill = checked and "on_primary" or "on_surface_variant"
  local justify = checked and "end" or "start"

  return ui.row({
    width = 44,
    height = 24,
    radius = 12,
    fill = trackFill,
    align = "center",
    justify = justify,
    padding = 2,
    onClick = function()
      if enabled then
        onToggle()
      end
    end,
  }, {
    ui.box({
      width = 20,
      height = 20,
      radius = 10,
      fill = knobFill,
    }),
  })
end

local function renderExitNodeRow(node)
  local isSelected = (activeExitNode ~= nil and (activeExitNode.id == node.id or (node.ip ~= "" and activeExitNode.ip == node.ip)))
  local isOnline = node.online

  local rowFill = isSelected and "primary/0.12" or "surface_variant/0.3"
  local dotColor = isOnline and "primary" or "outline"
  local titleColor = isSelected and "primary" or "on_surface"
  local statusText = isSelected and "Active exit node" or (isOnline and "Available" or "Offline")
  local statusColor = isSelected and "primary" or "on_surface_variant"

  return ui.row({
    key = "exit-node-" .. tostring(node.id),
    align = "center",
    gap = 10,
    padding = 10,
    radius = 8,
    fill = rowFill,
  }, {
    ui.box({ width = 8, height = 8, radius = 4, fill = dotColor }),
    ui.glyph({
      name = "world",
      size = 18,
      color = isSelected and "primary" or "on_surface_variant",
    }),
    ui.column({ flexGrow = 1, gap = 2, align = "stretch" }, {
      ui.label({
        text = node.name,
        fontWeight = isSelected and "bold" or "medium",
        fontSize = 13,
        color = titleColor,
        maxLines = 1,
      }),
      ui.label({
        text = statusText .. (node.ip ~= "" and (" • " .. node.ip) or ""),
        fontSize = 11,
        color = statusColor,
        maxLines = 1,
      }),
    }),
    ui.button({
      glyph = isSelected and "check" or "player-play",
      variant = isSelected and "primary" or "default",
      enabled = not isBusy and (isOnline or isSelected),
      tooltip = isSelected and "Disconnect from this exit node" or "Use as exit node",
      onClick = function()
        if isSelected then
          sendCommand("select_exit_node", "")
        else
          local target = (node.ip and node.ip ~= "") and node.ip or node.name
          sendCommand("select_exit_node", target)
        end
      end,
    }),
  })
end

local function getSubtitleText()
  if isBusy then
    return "Updating..."
  elseif needsLogin then
    return "Login required"
  elseif backendState == "Starting" then
    return "Connecting..."
  elseif isRunning then
    if activeExitNode then
      return "Connected via " .. activeExitNode.name
    end
    return "Connected"
  else
    return "Disconnected"
  end
end

local function render()
  local subtitleColor = isRunning and "primary" or (needsLogin and "error" or "on_surface_variant")

  -- Header with title, live subtitle, main toggle switch, refresh and close buttons
  local header = ui.row({ align = "center", gap = 10 }, {
    ui.glyph({
      name = isRunning and "network" or (needsLogin and "alert-triangle" or "network-off"),
      size = 22,
      color = subtitleColor,
    }),
    ui.column({ flexGrow = 1, gap = 1 }, {
      ui.label({ text = "Tailscale", fontSize = 16, fontWeight = "bold" }),
      ui.label({
        text = getSubtitleText(),
        fontSize = 12,
        color = subtitleColor,
      }),
    }),
    renderToggle(isRunning, not isBusy, function()
      sendCommand("toggle_connect")
    end),
    ui.button({
      glyph = "refresh",
      variant = "ghost",
      enabled = not isBusy,
      onClick = function() sendCommand("refresh") end,
    }),
    ui.button({
      glyph = "close",
      variant = "ghost",
      onClick = function() panel.close() end,
    }),
  })

  -- Exit nodes list or state prompt
  local listChildren = {}
  if needsLogin then
    table.insert(listChildren, ui.column({ align = "center", justify = "center", padding = 32, gap = 12 }, {
      ui.glyph({ name = "alert-triangle", size = 32, color = "error" }),
      ui.label({
        text = "Tailscale authentication required",
        fontSize = 13,
        fontWeight = "bold",
        color = "on_surface",
      }),
      ui.label({
        text = "Your node key has expired or requires sign-in.",
        fontSize = 12,
        color = "on_surface_variant",
      }),
      ui.button({
        text = "Log in to Tailscale",
        glyph = "external-link",
        variant = "primary",
        enabled = not isBusy,
        onClick = function() sendCommand("login") end,
      }),
    }))
  elseif #exitNodes == 0 then
    table.insert(listChildren, ui.column({ align = "center", justify = "center", padding = 32, gap = 8 }, {
      ui.glyph({ name = "world-off", size = 32, color = "on_surface_variant" }),
      ui.label({
        text = isRunning and "No exit nodes found on your tailnet" or "Connect to Tailscale to see exit nodes",
        fontSize = 12,
        color = "on_surface_variant",
      }),
    }))
  else
    for _, node in ipairs(exitNodes) do
      table.insert(listChildren, renderExitNodeRow(node))
    end
  end

  local exitScroll = ui.scroll({ flexGrow = 1, gap = 6, align = "stretch" }, listChildren)

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    header,
    exitScroll,
  }))
end

function onOpen(_context)
  if not applyStateTable(noctalia.state.get("ts_state")) then
    isRunning = noctalia.state.get("ts_running") or false
    needsLogin = noctalia.state.get("ts_needs_login") or false
    activeExitNode = noctalia.state.get("ts_exit_node")
    exitNodes = noctalia.state.get("ts_exit_nodes") or {}
    isBusy = noctalia.state.get("ts_busy") or false
  end
  sendCommand("refresh")
  render()
end

function onClose()
end

noctalia.state.watch("ts_state", function(st)
  if applyStateTable(st) then
    render()
  end
end)

render()
