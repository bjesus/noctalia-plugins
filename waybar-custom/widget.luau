--!nonstrict
-- Waybar Custom Command Widget for Noctalia
-- Implements the waybar-custom(5) specification. Fully driven by widget settings.

-- Utility: Pure Luau UTF-8 length
local function utf8Len(str: string): number
  local len = 0
  for i = 1, #str do
    local b = str:byte(i)
    if b < 0x80 or b >= 0xC0 then
      len += 1
    end
  end
  return len
end

-- Utility: Pure Luau UTF-8 substring
local function utf8Sub(str: string, maxChars: number): string
  local charCount = 0
  for i = 1, #str do
    local b = str:byte(i)
    if b < 0x80 or b >= 0xC0 then
      charCount += 1
      if charCount > maxChars then
        return str:sub(1, i - 1)
      end
    end
  end
  return str
end

-- Utility: Convert codepoint to UTF-8 character string
local function codepointToUtf8(cp: number): string
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(
      0xC0 + math.floor(cp / 0x40),
      0x80 + (cp % 0x40)
    )
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40)
    )
  elseif cp < 0x110000 then
    return string.char(
      0xF0 + math.floor(cp / 0x40000),
      0x80 + (math.floor(cp / 0x1000) % 0x40),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40)
    )
  end
  return ""
end

-- Utility: Decode HTML / XML entities (&lt;, &gt;, &amp;, &quot;, &#39;, &#123;, &#x1F;, etc.)
local function decodeHtmlEntities(str: string): string
  if not str or str == "" then
    return ""
  end
  local s = str
  -- Decimal numeric entities &#123;
  s = s:gsub("&#(%d+);", function(n)
    local num = tonumber(n)
    if num then
      return codepointToUtf8(num)
    end
    return "&#" .. n .. ";"
  end)

  -- Hexadecimal numeric entities &#x1F600;
  s = s:gsub("&#[xX](%x+);", function(h)
    local num = tonumber(h, 16)
    if num then
      return codepointToUtf8(num)
    end
    return "&#x" .. h .. ";"
  end)

  -- Named entities
  s = s:gsub("&quot;", '"')
  s = s:gsub("&apos;", "'")
  s = s:gsub("&#39;", "'")
  s = s:gsub("&lt;", "<")
  s = s:gsub("&gt;", ">")
  s = s:gsub("&nbsp;", " ")
  -- &amp; is decoded last so entities like &amp;lt; are not double decoded
  s = s:gsub("&amp;", "&")

  return s
end

-- Utility: Unescape literal backslashes (\n, \t, \r, \", \\)
local function unescapeBackslashes(str: string): string
  if not str or str == "" then
    return ""
  end
  local s = str:gsub("\\n", "\n")
  s = s:gsub("\\t", "\t")
  s = s:gsub("\\r", "\r")
  s = s:gsub('\\"', '"')
  s = s:gsub("\\\\", "\\")
  return s
end

-- Utility: Strip HTML / Pango markup tags like <span ...>, <b>, </u>, <big>
local function stripMarkupTags(str: string): string
  if not str or str == "" then
    return ""
  end
  return (str:gsub("</?[%a][%w%-%_:]*[^>]*>", ""))
end

-- Clean and format content according to escape setting
local function cleanContent(str: string, escapeMode: boolean): string
  if not str or str == "" then
    return ""
  end
  local s = unescapeBackslashes(str)
  if not escapeMode then
    s = stripMarkupTags(s)
    s = decodeHtmlEntities(s)
  end
  return s
end

-- Utility: Extract first balanced JSON object from string (handles trailing garbage like "}")
local function extractFirstJson(s: string): string
  local depth = 0
  local inStr = false
  local escape = false
  for i = 1, #s do
    local c = s:sub(i, i)
    if escape then
      escape = false
    elseif c == "\\" then
      if inStr then
        escape = true
      end
    elseif c == '"' then
      inStr = not inStr
    elseif not inStr then
      if c == "{" then
        depth += 1
      elseif c == "}" then
        depth -= 1
        if depth == 0 then
          return s:sub(1, i)
        end
      end
    end
  end
  return s
end

-- Helper: resolve icon according to percentage or class/alt/text
local function resolveIcon(icons: any, alt: string?, classes: any, rawText: string?, percentage: number?): string
  if type(icons) ~= "table" then
    return ""
  end

  -- Array form (percentage indexed from 0% to 100%)
  if icons[1] ~= nil then
    local n = #icons
    if n == 0 then return "" end
    if n == 1 then return tostring(icons[1]) end
    local pct = tonumber(percentage) or 0
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    local idx = math.floor((pct / 100) * (n - 1) + 0.5) + 1
    if idx < 1 then idx = 1 end
    if idx > n then idx = n end
    return tostring(icons[idx] or "")
  end

  -- Dictionary / Map form
  if alt and alt ~= "" and icons[alt] ~= nil then
    return tostring(icons[alt])
  end

  if type(classes) == "table" then
    for _, c in ipairs(classes) do
      if c and icons[tostring(c)] ~= nil then
        return tostring(icons[tostring(c)])
      end
    end
  elseif type(classes) == "string" and classes ~= "" and icons[classes] ~= nil then
    return tostring(icons[classes])
  end

  if rawText and rawText ~= "" and icons[rawText] ~= nil then
    return tostring(icons[rawText])
  end

  if icons["default"] ~= nil then
    return tostring(icons["default"])
  end

  return ""
end

-- Helper: apply format replacements
local function applyFormat(fmt: string, text: string, alt: string, percentage: any, icon: string): string
  local safeText = text:gsub("%%", "%%%%")
  local safeAlt = (alt or ""):gsub("%%", "%%%%")
  local safeIcon = (icon or ""):gsub("%%", "%%%%")
  local safePct = (percentage ~= nil and tostring(percentage) or ""):gsub("%%", "%%%%")

  local res = fmt
  res = res:gsub("{text}", safeText)
  res = res:gsub("{}", safeText)
  res = res:gsub("{alt}", safeAlt)
  res = res:gsub("{icon}", safeIcon)
  res = res:gsub("{percentage}", safePct)
  return res
end

-- Helper: padding & alignment
local function applyPadding(text: string, minLen: number, alignVal: any): string
  local curLen = utf8Len(text)
  if curLen >= minLen then
    return text
  end
  local diff = minLen - curLen
  local a = tostring(alignVal or "left"):lower()
  if a == "1" or a == "right" then
    return string.rep(" ", diff) .. text
  elseif a == "0.5" or a == "center" then
    local left = math.floor(diff / 2)
    local right = diff - left
    return string.rep(" ", left) .. text .. string.rep(" ", right)
  else
    return text .. string.rep(" ", diff)
  end
end

-- Runtime state
local cfg = {}
local isRunning = false
local streamActive = false
local needsRerun = false

local function loadConfig()
  local function getStr(key: string, defaultVal: string): string
    local v = noctalia.getConfig(key)
    if type(v) == "string" and v ~= "" then
      return v
    end
    return defaultVal
  end

  local function getBool(key: string, defaultVal: boolean): boolean
    local v = noctalia.getConfig(key)
    if type(v) == "boolean" then
      return v
    end
    return defaultVal
  end

  local function getInt(key: string, defaultVal: number): number
    local v = noctalia.getConfig(key)
    if type(v) == "number" then
      return math.floor(v)
    end
    return defaultVal
  end

  local formatIcons = {}
  local rawIcons = noctalia.getConfig("format_icons")
  if type(rawIcons) == "string" and rawIcons ~= "" then
    local ok, decoded = pcall(function() return noctalia.json.decode(rawIcons) end)
    if ok and type(decoded) == "table" then
      formatIcons = decoded
    end
  elseif type(rawIcons) == "table" then
    formatIcons = rawIcons
  end

  cfg = {
    exec = getStr("exec", ""),
    exec_if = getStr("exec_if", ""),
    interval = getInt("interval", 0),
    restart_interval = getInt("restart_interval", 0),
    return_type = getStr("return_type", ""),
    format = getStr("format", "{}"),
    format_icons = formatIcons,
    max_length = getInt("max_length", 0),
    min_length = getInt("min_length", 0),
    align = getStr("align", "left"),
    hide_empty_text = getBool("hide_empty_text", false),
    escape = getBool("escape", false),
    exec_on_event = getBool("exec_on_event", true),
    tooltip = getBool("tooltip", true),
    tooltip_format = getStr("tooltip_format", ""),
    on_click = getStr("on_click", ""),
    on_click_right = getStr("on_click_right", ""),
    on_click_middle = getStr("on_click_middle", ""),
    on_scroll_up = getStr("on_scroll_up", ""),
    on_scroll_down = getStr("on_scroll_down", ""),
    on_update = getStr("on_update", ""),
  }
end

local renderOutput
local executeCommand

renderOutput = function(rawOutput: string)
  local trimmed = noctalia.string.trim(rawOutput or "")
  local rawText = ""
  local alt = ""
  local rawTooltip = nil
  local classes = nil
  local percentage = nil

  if trimmed:sub(1, 1) == "{" then
    local ok, data = pcall(function() return noctalia.json.decode(trimmed) end)
    if not ok then
      local cleanJson = extractFirstJson(trimmed)
      ok, data = pcall(function() return noctalia.json.decode(cleanJson) end)
    end

    if ok and type(data) == "table" then
      rawText = tostring(data.text or "")
      alt = tostring(data.alt or "")
      rawTooltip = data.tooltip
      classes = data.class
      if data.percentage ~= nil then
        percentage = tonumber(data.percentage)
      end
    else
      local textMatch = trimmed:match('"text"%s*:%s*"(.-)"%s*[,}]') or trimmed:match('"text"%s*:%s*"([^"]*)"')
      local tipMatch = trimmed:match('"tooltip"%s*:%s*"(.-)"%s*[,}]') or trimmed:match('"tooltip"%s*:%s*"([^"]*)"')
      if textMatch then
        rawText = textMatch
        rawTooltip = tipMatch
      else
        rawText = trimmed
      end
    end
  else
    if cfg.return_type == "json" then
      rawText = trimmed
    else
      local lines = {}
      for line in rawOutput:gmatch("[^\r\n]+") do
        table.insert(lines, line)
      end
      rawText = lines[1] or ""
      rawTooltip = lines[2]
      classes = lines[3]
    end
  end

  local icon = resolveIcon(cfg.format_icons, alt, classes, rawText, percentage)
  local formatted = applyFormat(cfg.format, rawText, alt, percentage, icon)
  formatted = cleanContent(formatted, cfg.escape)

  if cfg.max_length > 0 and utf8Len(formatted) > cfg.max_length then
    formatted = utf8Sub(formatted, cfg.max_length)
  end

  if cfg.min_length > 0 then
    formatted = applyPadding(formatted, cfg.min_length, cfg.align)
  end

  if cfg.hide_empty_text and noctalia.string.trim(formatted) == "" then
    barWidget.setVisible(false)
  else
    barWidget.setVisible(true)
  end

  barWidget.setText(formatted)

  if not cfg.tooltip then
    barWidget.clearTooltip()
  else
    if cfg.tooltip_format ~= "" then
      local tip = applyFormat(cfg.tooltip_format, rawText, alt, percentage, icon)
      barWidget.setTooltip(cleanContent(tip, cfg.escape))
    elseif rawTooltip and rawTooltip ~= "" then
      barWidget.setTooltip(cleanContent(tostring(rawTooltip), cfg.escape))
    else
      barWidget.clearTooltip()
    end
  end

  if cfg.on_update ~= "" then
    noctalia.runAsync(cfg.on_update)
  end
end

local function startStream()
  if cfg.exec == "" or streamActive then
    return
  end

  local function launchStream()
    streamActive = true
    local started = noctalia.runStream(cfg.exec, function(line)
      if line and line ~= "" then
        renderOutput(line)
      end
    end)

    if not started then
      streamActive = false
      noctalia.log("waybar-custom: failed to start stream for " .. cfg.exec)
      local restartSec = cfg.restart_interval > 0 and cfg.restart_interval or 5
      noctalia.setUpdateInterval(restartSec * 1000)
    else
      noctalia.setUpdateInterval(10000)
    end
  end

  if cfg.exec_if ~= "" then
    noctalia.runAsync(cfg.exec_if, function(res)
      if res.exitCode == 0 then
        launchStream()
      else
        barWidget.setVisible(false)
        streamActive = false
        noctalia.setUpdateInterval(5000)
      end
    end, 10000)
  else
    launchStream()
  end
end

executeCommand = function()
  if cfg.exec == "" then
    return
  end

  local function runExec()
    isRunning = true
    noctalia.runAsync(cfg.exec, function(res)
      isRunning = false
      if res.exitCode == 0 or (res.stdout and res.stdout ~= "") then
        renderOutput(res.stdout)
      end

      if needsRerun then
        needsRerun = false
        executeCommand()
      end
    end, 60000)
  end

  if cfg.exec_if ~= "" then
    noctalia.runAsync(cfg.exec_if, function(res)
      if res.exitCode == 0 then
        runExec()
      else
        barWidget.setVisible(false)
      end
    end, 10000)
  else
    runExec()
  end
end

local function run()
  if cfg.exec == "" then
    return
  end

  if cfg.interval == 0 then
    if not streamActive then
      startStream()
    end
  elseif cfg.interval == -1 then
    executeCommand()
    noctalia.setUpdateInterval(86400000)
  else
    local pollMs = math.max(100, cfg.interval * 1000)
    noctalia.setUpdateInterval(pollMs)
    if not isRunning then
      executeCommand()
    else
      needsRerun = true
    end
  end
end

local function triggerEvent(cmd: string)
  if cmd and cmd ~= "" then
    noctalia.runAsync(cmd)
  end
  if cfg.exec_on_event then
    if cfg.interval ~= 0 then
      executeCommand()
    end
  end
end

-- Initialize configuration and start execution
loadConfig()
run()

function update()
  if cfg.interval == 0 then
    if not streamActive then
      startStream()
    end
  else
    executeCommand()
  end
end

function onClick()
  triggerEvent(cfg.on_click)
end

function onRightClick()
  triggerEvent(cfg.on_click_right)
end

function onMiddleClick()
  triggerEvent(cfg.on_click_middle)
end

function onScroll(axis: string, steps: number, startsGesture: boolean)
  if steps < 0 then
    triggerEvent(cfg.on_scroll_up)
  elseif steps > 0 then
    triggerEvent(cfg.on_scroll_down)
  end
end

function onIpc(event: string, payload: string?)
  if event == "refresh" or event == "update" or event == "signal" then
    executeCommand()
  elseif event == "set" then
    renderOutput(payload or "")
  end
end

function onConfigChanged()
  loadConfig()
  run()
end

function onExit(signal: number, reason: string)
  streamActive = false
end
