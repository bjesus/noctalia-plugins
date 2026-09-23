--!nonstrict

local formatPattern = noctalia.getConfig("music_format")
if not formatPattern or formatPattern == "" then
    formatPattern = "{title} - {artist}"
end

local targetSpeakerEid = noctalia.getConfig("music_target_speaker")

local entityStates = {}
local status = "unconfigured"

local render

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

local function getActivePlayer()
    -- If user set a specific target speaker in widget setting
    if targetSpeakerEid and targetSpeakerEid ~= "" and entityStates[targetSpeakerEid] then
        local e = entityStates[targetSpeakerEid]
        if e.domain == "media_player" and e.state == "playing" then
            return e
        end
    end

    -- Otherwise find any media player currently playing
    for _, e in pairs(entityStates) do
        if e.domain == "media_player" and e.state == "playing" then
            return e
        end
    end

    -- If none playing, return specified speaker if paused
    if targetSpeakerEid and targetSpeakerEid ~= "" and entityStates[targetSpeakerEid] then
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
        local title = player.media_title or ""
        local artist = player.media_artist or ""
        local album = player.media_album_name or ""

        local label = formatTrack(formatPattern, title, artist, album)
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

noctalia.state.watch("connection_status", function(value)
    status = value or "unconfigured"
    if render then render() end
end)

function update()
    noctalia.setUpdateInterval(3000)
    entityStates = noctalia.state.get("entities") or {}
    status = noctalia.state.get("connection_status") or "unconfigured"
    render()
end

function onClick()
    noctalia.togglePanel("pozzoo/hassio:music")
end

function onRightClick()
    local player = getActivePlayer()
    if player and player.entity_id then
        noctalia.runAsync(string.format(
            "noctalia msg service-call pozzoo/hassio:connection media_player/media_play_pause %s",
            player.entity_id
        ))
    end
end
