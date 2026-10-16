--!nonstrict

local entityStates = {}
local status = "unconfigured"
local lastChosenSpeaker = nil

local render

local function getFormatPattern()
    local fmt = noctalia.getConfig("music_format")
    if type(fmt) == "string" and fmt ~= "" then
        return fmt
    end
    return "{title} - {artist}"
end

local function getTargetSpeakerEid()
    local spk = noctalia.getConfig("music_target_speaker")
    if type(spk) == "string" and spk ~= "" then
        return spk
    end
    return ""
end

local function formatTrack(formatStr, title, artist, album)
    local res = formatStr
    res = res:gsub("{title}", title or "")
    res = res:gsub("{artist}", artist or "")
    res = res:gsub("{album}", album or "")
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

        local label = formatTrack(getFormatPattern(), title, artist, album)
        if label == "" then
            label = player.friendly_name or "Music"
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
