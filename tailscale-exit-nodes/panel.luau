--!nonstrict
-- Popup panel for Tailscale: clean connection toggle & exit node picker

local isRunning = noctalia.state.get("ts_running") or false
local activeExitNode = noctalia.state.get("ts_exit_node")
local exitNodes = noctalia.state.get("ts_exit_nodes") or {}
local isBusy = noctalia.state.get("ts_busy") or false

local function sendCommand(action, target)
  noctalia.state.set("ts_command", { action = action, target = target })
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
  local isSelected = (activeExitNode ~= nil and (activeExitNode.id == node.id or activeExitNode.ip == node.ip))
  local isOnline = node.online

  local rowFill = isSelected and "primary/0.12" or "surface_variant/0.3"
  local dotColor = isOnline and "primary" or "outline"
  local titleColor = isSelected and "primary" or "on_surface"
  local statusText = isSelected and "Active exit node" or (isOnline and "Available" or "Offline")
  local statusColor = isSelected and "primary" or "on_surface_variant"

  return ui.row({
    key = "exit-node-" .. node.id,
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
      enabled = not isBusy and (isOnline or not isSelected),
      tooltip = isSelected and "Disconnect from this exit node" or "Use as exit node",
      onClick = function()
        if isSelected then
          sendCommand("select_exit_node", "")
        else
          sendCommand("select_exit_node", node.name)
        end
      end,
    }),
  })
end

local function render()
  -- Header with title, live subtitle, main toggle switch, refresh and close buttons
  local header = ui.row({ align = "center", gap = 10 }, {
    ui.glyph({
      name = isRunning and "network" or "network-off",
      size = 22,
      color = isRunning and "primary" or "on_surface_variant",
    }),
    ui.column({ flexGrow = 1, gap = 1 }, {
      ui.label({ text = "Tailscale", fontSize = 16, fontWeight = "bold" }),
      ui.label({
        text = isBusy and "Updating..." or (isRunning and (activeExitNode and ("Connected via " .. activeExitNode.name) or "Connected") or "Disconnected"),
        fontSize = 12,
        color = isRunning and "primary" or "on_surface_variant",
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

  -- Exit nodes list directly
  local listChildren = {}
  if #exitNodes == 0 then
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
  isRunning = noctalia.state.get("ts_running") or false
  activeExitNode = noctalia.state.get("ts_exit_node")
  exitNodes = noctalia.state.get("ts_exit_nodes") or {}
  isBusy = noctalia.state.get("ts_busy") or false
  sendCommand("refresh")
  render()
end

function onClose()
end

noctalia.state.watch("ts_running", function(val)
  isRunning = val == true
  render()
end)

noctalia.state.watch("ts_exit_node", function(val)
  activeExitNode = val
  render()
end)

noctalia.state.watch("ts_exit_nodes", function(val)
  exitNodes = val or {}
  render()
end)

noctalia.state.watch("ts_busy", function(val)
  isBusy = val == true
  render()
end)

render()
