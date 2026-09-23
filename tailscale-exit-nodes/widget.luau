--!nonstrict
-- Bar widget for Tailscale: shows status icon and opens the panel on click

local isRunning = noctalia.state.get("ts_running") or false
local activeExitNode = noctalia.state.get("ts_exit_node")

local function render()
  local glyph = isRunning and (activeExitNode and "world" or "network") or "network-off"
  local glyphColor = isRunning and "primary" or "on_surface_variant"

  barWidget.setGlyph(glyph)
  barWidget.setGlyphColor(glyphColor)

  if isRunning then
    if activeExitNode then
      barWidget.setText(activeExitNode.name)
      barWidget.setTooltip("Tailscale: Connected (" .. activeExitNode.name .. ")")
    else
      barWidget.setText("")
      barWidget.setTooltip("Tailscale: Connected")
    end
  else
    barWidget.setText("")
    barWidget.setTooltip("Tailscale: Disconnected")
  end
end

function onClick()
  noctalia.togglePanel("bjesus/tailscale-exit-nodes:panel")
end

noctalia.state.watch("ts_running", function(val)
  isRunning = val == true
  render()
end)

noctalia.state.watch("ts_exit_node", function(val)
  activeExitNode = val
  render()
end)

render()
