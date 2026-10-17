--!nonstrict

local entityStates = {}
local status = "unconfigured"
local lastChosenSpeaker = nil

local render

-- Utility: Pure Luau UTF-8 length
local function utf8Len(str: string): number
    if not str or str == "" then return 0 end
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
    if not str or str == "" or maxChars <= 0 then return "" end
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

-- Utility: Pure Luau UTF-8 clipping with ellipsis
local function clipWithEllipsis(str: string, maxChars: number): string
    if not str or str == "" or maxChars <= 0 then return "" end
    if utf8Len(str) <= maxChars then return str end
    if maxChars <= 3 then
        return utf8Sub(str, maxChars)
    end
    local truncated = utf8Sub(str, maxChars - 3):gsub("[%s%-–•/%.]+$", "")
    return truncated .. "..."
end

local function getFormatPattern()
    local fmt = noctalia.getConfig("music_format")
    if type(fmt) == "string" and fmt ~= "" then
        return fmt
    end
    return "{title} - {artist}"
end

local function getMaxLength(): number
    local v = noctalia.getConfig("music_max_length")
    if type(v) == "number" then
        return math.floor(v)
    end
    if type(v) == "string" then
        local n = tonumber(v)
        if n then return math.floor(n) end
    end
    return 0
end

local function getTargetSpeakerEid()
    local spk = noctalia.getConfig("music_target_speaker")
    if type(spk) == "string" and spk ~= "" then
        return spk
    end
    return ""
end

local function formatTrack(formatStr: string, title: string?, artist: string?, album: string?, speaker: string?): string
    local fields = {
        title = title or "",
        artist = artist or "",
        album = album or "",
        speaker = speaker or "",
        player = speaker or "",
    }

    local res = formatStr:gsub("{%s*([%w_]+)%s*(:?[^}]*)}", function(key, mod)
        local val = fields[key:lower()]
        if val == nil then
            return nil
        end
        if mod and mod ~= "" then
            local limit = tonumber(mod:match(":%s*(%d+)"))
            if limit and limit >= 0 then
                return clipWithEllipsis(val, limit)
            end
        end
        return val
    end)

    res = noctalia.string.trim(res)
    -- Clean up trailing / leading hyphens or dividers if some fields were empty
    res = res:gsub("^[%s%-–•/]+", ""):gsub("[%s%-–•/]+$", "")
    return res
end

local function hasTitle(e)
    return type(e) == "table" and type(e.media_title) == "string" and e.media_title ~= ""
end

local function isMaPlayer(e)
    return type(e) == "table" and type(e.mass_player_type) == "string" and e.mass_player_type ~= ""
end

local function resolveGroupMetadata(player)
    if not player or hasTitle(player) then
        return player
    end
    local members = player.group_members
    if type(members) == "table" then
        for _, mEid in ipairs(members) do
            local mEnt = entityStates[mEid]
            if mEnt and mEnt.state == "playing" and hasTitle(mEnt) then
                return mEnt
            end
        end
        for _, mEid in ipairs(members) do
            local mEnt = entityStates[mEid]
            if mEnt and hasTitle(mEnt) then
                return mEnt
            end
        end
    end
    return player
end

local function playerRank(e)
    local score = 0
    if isMaPlayer(e) then score = score + 4 end
    if hasTitle(e) then score = score + 2 end
    if lastChosenSpeaker and e.entity_id == lastChosenSpeaker then score = score + 1 end
    return score
end

local function getActivePlayer()
    local targetSpeakerEid = getTargetSpeakerEid()

    -- 1. If user set a specific target speaker in widget setting and it is playing
    if targetSpeakerEid ~= "" and entityStates[targetSpeakerEid] then
        local e = entityStates[targetSpeakerEid]
        if e.domain == "media_player" and e.state == "playing" then
            return e
        end
    end

    -- 2. Find all currently playing media players and pick the best one deterministically
    local playing = {}
    for _, e in pairs(entityStates) do
        if type(e) == "table" and e.domain == "media_player" and e.state == "playing" then
            table.insert(playing, e)
        end
    end

    if #playing > 0 then
        table.sort(playing, function(a, b)
            local rA = playerRank(a)
            local rB = playerRank(b)
            if rA ~= rB then return rA > rB end
            return (a.entity_id or "") < (b.entity_id or "")
        end)
        return playing[1]
    end

    -- 3. If none playing, return specified target speaker if available
    if targetSpeakerEid ~= "" and entityStates[targetSpeakerEid] then
        return entityStates[targetSpeakerEid]
    end

    return nil
end

render = function()
    local player = getActivePlayer()
    local isPlaying = player and player.state == "playing"

    barWidget.setGlyph(isPlaying and "music" or "disc")
    barWidget.setGlyphColor(isPlaying and "primary" or "on_surface_variant")

    if player and isPlaying then
        local metaSource = resolveGroupMetadata(player) or player
        local title = metaSource.media_title or ""
        local artist = metaSource.media_artist or ""
        local album = metaSource.media_album_name or ""
        local speaker = player.friendly_name or player.entity_id or ""

        local label = formatTrack(getFormatPattern(), title, artist, album, speaker)
        if label == "" then
            label = player.friendly_name or "Music"
        end

        local maxLen = getMaxLength()
        if maxLen > 0 then
            label = clipWithEllipsis(label, maxLen)
        end

        barWidget.setText(label)
        barWidget.setTooltip(string.format("%s\nArtist: %s\nAlbum: %s\nSpeaker: %s",
            title ~= "" and title or "Unknown",
            artist ~= "" and artist or "Unknown",
            album ~= "" and album or "Unknown",
            player.friendly_name or player.entity_id or "Speaker"
        ))
    else
        barWidget.setText("")
        barWidget.setTooltip("Music Assistant (Idle)")
    end
end

noctalia.state.watch("entities", function(value)
    entityStates = value or {}
    if render then render() end
end)

noctalia.state.watch("last_chosen_speaker", function(value)
    lastChosenSpeaker = value
    if render then render() end
end)

noctalia.state.watch("connection_status", function(value)
    status = value or "unconfigured"
    if render then render() end
end)

function update()
    noctalia.setUpdateInterval(3000)
    entityStates = noctalia.state.get("entities") or {}
    lastChosenSpeaker = noctalia.state.get("last_chosen_speaker")
    status = noctalia.state.get("connection_status") or "unconfigured"
    render()
end

function onClick()
    noctalia.togglePanel("bjesus/ha-ma:music")
end

function onRightClick()
    noctalia.runAsync("noctalia msg plugin bjesus/ha-ma:connection all toggle_pause")
end

function onConfigChanged()
    if render then render() end
end
