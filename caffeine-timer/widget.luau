--!nonstrict
-- Caffeine Timer bar widget.
--
-- Click cycles through keep-awake sessions, resetting the countdown each time:
--   off -> 5 min -> 10 min -> 30 min -> 1 h -> 2 h -> 5 h -> 12 h -> forever -> off
-- While a session runs, the shell's caffeine idle inhibitor is enabled - the
-- same mechanism the built-in Caffeine widget uses, driven over
-- `noctalia msg caffeine-enable` / `caffeine-disable`. When the countdown ends,
-- caffeine is disabled again and a notification is sent.
--
-- The session lives in noctalia.state so every placement of this widget shows
-- the same timer; whichever instance notices the deadline first claims the
-- finish and the others follow through the shared state.

local MINUTE_MS = 60 * 1000
local HOUR_MS = 60 * MINUTE_MS
local TICK_ACTIVE_MS = 1000 -- timed session: refresh the countdown every second
local TICK_IDLE_MS = 5000 -- off or "forever": nothing to count down

-- The click cycle; `ms = nil` means "forever" (no deadline).
local DURATIONS = {
  { key = "durations.five_minutes", ms = 5 * MINUTE_MS },
  { key = "durations.ten_minutes", ms = 10 * MINUTE_MS },
  { key = "durations.thirty_minutes", ms = 30 * MINUTE_MS },
  { key = "durations.one_hour", ms = HOUR_MS },
  { key = "durations.two_hours", ms = 2 * HOUR_MS },
  { key = "durations.five_hours", ms = 5 * HOUR_MS },
  { key = "durations.twelve_hours", ms = 12 * HOUR_MS },
  { key = "durations.forever" },
}

local SESSION_KEY = "caf_session" -- active session table, or nil when off
local FINISHED_KEY = "caf_finished_deadline" -- last deadline we finished, against duplicate notifications

local lastIntervalMs = nil

local function tr(key, subst)
  if subst ~= nil then
    return noctalia.tr(key, subst)
  end
  return noctalia.tr(key)
end

local function settingBool(key, default)
  local value = noctalia.getConfig(key)
  if type(value) == "boolean" then
    return value
  end
  return default
end

local function applyInterval(ms)
  -- Only reset the host timer when the desired interval actually changes.
  if lastIntervalMs ~= ms then
    lastIntervalMs = ms
    noctalia.setUpdateInterval(ms)
  end
end

local function formatCountdown(totalSec)
  if totalSec < 0 then
    totalSec = 0
  end
  local hours = math.floor(totalSec / 3600)
  local minutes = math.floor((totalSec % 3600) / 60)
  local seconds = totalSec % 60
  if hours > 0 then
    return string.format("%d:%02d", hours, minutes)
  end
  return string.format("%d:%02d", minutes, seconds)
end

local function cancelHintLabel()
  local right = settingBool("right_click_cancels", true)
  local middle = settingBool("middle_click_cancels", true)
  if right and middle then
    return tr("widget.cancel_both")
  elseif right then
    return tr("widget.cancel_right")
  elseif middle then
    return tr("widget.cancel_middle")
  end
  return nil
end

local function tooltipRows(session)
  local rows = {}

  if session == nil then
    table.insert(rows, { key = tr("widget.caffeine"), value = tr("widget.off") })
    table.insert(rows, { key = tr("widget.click"), value = tr("widget.click_start", { duration = tr(DURATIONS[1].key) }) })
    return rows
  end

  table.insert(rows, { key = tr("widget.caffeine"), value = tr(session.key) })

  if session.deadlineMs ~= nil then
    local remainingSec = math.ceil((session.deadlineMs - noctalia.nowMs()) / 1000)
    table.insert(rows, { key = tr("widget.remaining"), value = formatCountdown(remainingSec) })
    table.insert(rows, { key = tr("widget.ends_at"), value = noctalia.formatTime("{:%H:%M}", math.floor(session.deadlineMs / 1000)) })
    local nextDuration = DURATIONS[session.index + 1]
    local nextLabel = nextDuration ~= nil and tr("widget.click_next", { duration = tr(nextDuration.key) }) or tr("widget.cancel")
    table.insert(rows, { key = tr("widget.click"), value = nextLabel })
  else
    table.insert(rows, { key = tr("widget.click"), value = tr("widget.cancel") })
  end

  local hint = cancelHintLabel()
  if hint ~= nil then
    table.insert(rows, { key = hint, value = tr("widget.cancel") })
  end

  return rows
end

local function render(session)
  if session == nil then
    barWidget.setGlyph("caffeine-off")
    barWidget.setGlyphColor("on_surface")
    barWidget.setText("")
  else
    barWidget.setGlyph("caffeine-on")
    barWidget.setGlyphColor("primary")
    if session.deadlineMs == nil then
      barWidget.setText(settingBool("show_remaining", true) and tr("widget.forever_symbol") or "")
    elseif settingBool("show_remaining", true) then
      barWidget.setText(formatCountdown(math.ceil((session.deadlineMs - noctalia.nowMs()) / 1000)))
    else
      barWidget.setText("")
    end
  end

  barWidget.setTooltip(tooltipRows(session))
end

local function enableCaffeine()
  noctalia.runAsync("noctalia msg caffeine-enable", function(result)
    local ok = true
    local out = ""
    if type(result) == "table" then
      ok = result.exitCode == 0
      out = result.stdout or ""
    elseif type(result) == "string" then
      out = result
    end
    if not ok or out:match("^%s*error") then
      noctalia.log("caffeine-timer: could not enable caffeine (" .. noctalia.string.trim(out) .. ")")
      -- Don't run a countdown we cannot honour: cancel and tell the user.
      noctalia.state.set(SESSION_KEY, nil)
      noctalia.notifyError(tr("notify.unavailable_title"), tr("notify.unavailable_body"))
    end
  end)
end

local function disableCaffeine()
  -- Detached on purpose; also safe to call from onExit after the VM is gone.
  noctalia.runAsync("noctalia msg caffeine-disable")
end

local function handleExpiry(session)
  if session == nil or session.deadlineMs == nil then
    return false
  end
  if noctalia.nowMs() < session.deadlineMs then
    return false
  end

  -- Clear the shared session first so another placement of this widget does
  -- not repeat the finish, then release the inhibitor and notify.
  noctalia.state.set(SESSION_KEY, nil)
  disableCaffeine()

  if noctalia.state.get(FINISHED_KEY) ~= session.deadlineMs then
    noctalia.state.set(FINISHED_KEY, session.deadlineMs)
    if settingBool("notify_on_finish", true) then
      noctalia.notify(tr("notify.done_title"), tr("notify.done_body", { duration = tr(session.key) }))
    end
  end

  return true
end

local function startSession(index, wasActive)
  local duration = DURATIONS[index]
  local session = { index = index, key = duration.key }
  if duration.ms ~= nil then
    session.deadlineMs = noctalia.nowMs() + duration.ms
  end
  noctalia.state.set(SESSION_KEY, session)
  if not wasActive then
    enableCaffeine()
  end
  render(session)
  applyInterval(duration.ms ~= nil and TICK_ACTIVE_MS or TICK_IDLE_MS)
end

local function cancelSession()
  if noctalia.state.get(SESSION_KEY) == nil then
    return
  end
  noctalia.state.set(SESSION_KEY, nil)
  disableCaffeine()
  render(nil)
  applyInterval(TICK_IDLE_MS)
end

local function tick()
  local session = noctalia.state.get(SESSION_KEY)
  if handleExpiry(session) then
    session = nil
  end
  render(session)
  applyInterval(session ~= nil and session.deadlineMs ~= nil and TICK_ACTIVE_MS or TICK_IDLE_MS)
end

function update()
  tick()
end

function onClick()
  local session = noctalia.state.get(SESSION_KEY)
  if session == nil then
    startSession(1, false) -- first click starts at the shortest duration
    return
  end
  local nextIndex = session.index + 1
  if nextIndex > #DURATIONS then
    cancelSession() -- a click past "forever" cancels the timer
  else
    startSession(nextIndex, true)
  end
end

function onRightClick()
  if settingBool("right_click_cancels", true) then
    cancelSession()
  end
end

function onMiddleClick()
  if settingBool("middle_click_cancels", true) then
    cancelSession()
  end
end

function onIpc(event, _payload)
  if event == "next" then
    onClick()
  elseif event == "cancel" then
    cancelSession()
  end
end

function onExit(signal)
  -- Signal 0 is a host teardown (disable/uninstall/reload): release the
  -- inhibitor so it does not outlive the widget. SIGINT/SIGTERM (2/15) mean the
  -- whole shell is stopping and the inhibitor is released with it.
  if signal ~= 0 then
    return
  end
  if noctalia.state.get(SESSION_KEY) ~= nil then
    noctalia.runAsync("noctalia msg caffeine-disable")
  end
end

noctalia.state.watch(SESSION_KEY, function(value)
  render(value)
end)

-- Initial state: resume a session left over from a reload (making sure the
-- inhibitor matches), finish one that expired while we were down, or start idle.
local session = noctalia.state.get(SESSION_KEY)
if session ~= nil and handleExpiry(session) then
  session = nil
elseif session ~= nil then
  enableCaffeine()
end
render(session)
applyInterval(session ~= nil and session.deadlineMs ~= nil and TICK_ACTIVE_MS or TICK_IDLE_MS)
