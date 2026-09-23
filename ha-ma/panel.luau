--!nonstrict

local haUrlRaw = noctalia.getConfig("ha_url")
local haToken = noctalia.getConfig("ha_token")

local entityStates = {}
local status = "unconfigured"
local expandedEntityId = nil
local sliderDraft = {}
local sliderDirty = {}

local pendingToggle = {}
local pendingSince = {} -- entity_id -> os.clock() when toggle was requested

local PENDING_TIMEOUT_SECONDS = 8
local renderScheduled = false

-- Panel navigation: "devices" | "music" | "speakers" | "browser"
local activeTab = "devices"
local allEntities = {}
local browserLoading = false
local browserLoadingSince = nil
local browserFailed = false

local BROWSER_TIMEOUT_SECONDS = 20
local MAX_BROWSER_ROWS = 200
local searchText = ""
local monitoredEntities = {} -- current monitored list (owned here, saved to file)
local panelOpenCount = 0

-- Music Assistant state
local maSearchQuery = ""
local maSearching = false
local maSearchCategory = "all" -- "all" | "artists" | "albums" | "playlists" | "tracks"
local maSearchResults = { artists = {}, albums = {}, playlists = {}, tracks = {} }
local maSelectedSpeaker = nil -- Default target player
local maConfigEntryId = nil

-- Music Assistant Library state
local maLibSubTab = "albums" -- "albums" | "artists" | "tracks" | "radio" | "playlists"
local maLibItems = { albums = {}, artists = {}, tracks = {}, radio = {}, playlists = {} }
local maLibLoading = { albums = false, artists = false, tracks = false, radio = false, playlists = false }
local maLibLoaded = { albums = false, artists = false, tracks = false, radio = false, playlists = false }

local function getCleanUrl()
    if type(haUrlRaw) ~= "string" then return "" end
    return (haUrlRaw:gsub("/$", ""))
end

local function tr(key, subst)
    return noctalia.tr("panel." .. key, subst)
end

local function getStatusText()
    if status == "connected" then
        return noctalia.tr("widget.status_connected")
    elseif status == "connecting" then
        return noctalia.tr("widget.status_connecting")
    elseif status == "disconnected" then
        return noctalia.tr("widget.status_disconnected")
    elseif status == "unreachable" then
        return noctalia.tr("widget.status_unreachable")
    elseif status == "auth_failed" then
        return noctalia.tr("widget.status_auth_failed")
    else
        return noctalia.tr("widget.status_unconfigured")
    end
end

local function getCleanToken()
    if type(haToken) ~= "string" then return "" end
    return haToken:gsub("^%s+", ""):gsub("%s+$", "")
end

local function haPost(path, body, callback, onFailure)
    local url = getCleanUrl()
    local cleanToken = getCleanToken()
    if not url or url == "" or cleanToken == "" then
        if onFailure then onFailure() end
        return
    end
    local encodedBody = noctalia.json.encode(body)

    noctalia.http({
        url = url .. path,
        method = "POST",
        headers = {
            "Authorization: Bearer " .. cleanToken,
            "Content-Type: application/json",
        },
        body = encodedBody,
        allow_insecure_tls = true,
    }, function(response: HttpResponse)
        local httpStatus = response and response.status or 0
        if httpStatus >= 200 and httpStatus < 300 then
            if callback then callback(response) end
            return
        end
        noctalia.log("Home Assistant rejected " .. path .. ": status " .. tostring(httpStatus))
        if onFailure then onFailure() end
    end)
end

local function haGet(path, callback, onFailure)
    local url = getCleanUrl()
    local cleanToken = getCleanToken()
    if not url or url == "" or cleanToken == "" then
        if onFailure then onFailure() end
        return
    end

    noctalia.http({
        url = url .. path,
        method = "GET",
        headers = {
            "Authorization: Bearer " .. cleanToken,
        },
        allow_insecure_tls = true,
    }, function(response: HttpResponse)
        local httpStatus = response and response.status or 0
        if httpStatus >= 200 and httpStatus < 300 then
            if callback then callback(response) end
            return
        end
        noctalia.log("Home Assistant GET failed " .. path .. ": status " .. tostring(httpStatus))
        if onFailure then onFailure() end
    end)
end

local function callService(domain, service, entityId, extraData, onFailure)
    local payload = { entity_id = entityId }
    if extraData then
        for k, v in pairs(extraData) do
            payload[k] = v
        end
    end
    haPost("/api/services/" .. domain .. "/" .. service, payload, nil, onFailure)
end

local MANAGED_ENTITIES_FILE = "managed_entities.json"

local function managedEntitiesPath()
    local dataDir, dirErr = noctalia.pluginDataDir()
    if not dataDir then
        noctalia.log("Cannot resolve plugin data dir: " .. (dirErr or "unknown"))
        return nil
    end
    return dataDir .. "/" .. MANAGED_ENTITIES_FILE
end

local function loadMonitoredEntities()
    local path = managedEntitiesPath()
    local data = path and noctalia.readFile(path)
    if data and data ~= "" then
        local parsed = noctalia.json.decode(data)
        if type(parsed) == "table" then
            monitoredEntities = parsed
            return
        end
    end
    monitoredEntities = {}
end

local function saveMonitoredEntities()
    local path = managedEntitiesPath()
    if not path then
        noctalia.notifyError(noctalia.tr("shortcut.title"), tr("save_failed_no_data_dir"))
        return
    end

    local encodedEntities = noctalia.json.encode(monitoredEntities)
    local ok, writeErr = noctalia.writeFile(path, encodedEntities)
    if not ok then
        noctalia.log("Failed to save managed entities: " .. (writeErr or "unknown"))
        noctalia.notifyError(noctalia.tr("shortcut.title"), tr("save_failed"))
        return
    end
    noctalia.state.set("entities_override", monitoredEntities)
    noctalia.state.set("command", "reload_entities")
end

local function isPinned(entityId)
    for _, eid in ipairs(monitoredEntities) do
        if eid == entityId then return true end
    end
    return false
end


local function movePinned(entityId, direction)
    local idx = nil
    for i, eid in ipairs(monitoredEntities) do
        if eid == entityId then
            idx = i
            break
        end
    end
    if not idx then return end
    local targetIdx = idx + direction
    if targetIdx < 1 or targetIdx > #monitoredEntities then return end

    local temp = monitoredEntities[idx]
    monitoredEntities[idx] = monitoredEntities[targetIdx]
    monitoredEntities[targetIdx] = temp

    saveMonitoredEntities()
    render()
end

local function toggleBrowserPin(entityId)
    if not entityId then return end
    local newList, found = {}, false
    for _, eid in ipairs(monitoredEntities) do
        if eid == entityId then found = true
        else table.insert(newList, eid) end
    end
    if not found then table.insert(newList, entityId) end
    monitoredEntities = newList
    saveMonitoredEntities()
    render()
end

-- Resolve Music Assistant config entry
local function ensureMaConfigEntry(callback)
    if maConfigEntryId then
        if callback then callback(maConfigEntryId) end
        return
    end

    haGet("/api/config/config_entries/entry", function(response)
        local entries = noctalia.json.decode(response.body)
        if type(entries) == "table" then
            for _, e in ipairs(entries) do
                if e.domain == "music_assistant" then
                    maConfigEntryId = e.entry_id
                    break
                end
            end
        end
        if not maConfigEntryId then
            maConfigEntryId = "01K97GZFW2EECSC2YGRDQP81DN" -- fallback from discovery
        end
        if callback then callback(maConfigEntryId) end
    end, function()
        maConfigEntryId = "01K97GZFW2EECSC2YGRDQP81DN"
        if callback then callback(maConfigEntryId) end
    end)
end

-- Fast entity browser parsing
local ENTITY_LIST_TEMPLATE =
    [=[{% for s in (states | sort(attribute='entity_id')) %}{{ s.entity_id }}	{{ s.name | replace('\t',' ') | replace('\n',' ') }}
{% endfor %}]=]
local ENTITY_ID_TEMPLATE =
    [=[{% for s in (states | sort(attribute='entity_id')) %}{{ s.entity_id }}
{% endfor %}]=]

local MAX_RECORD_SCAN = 1024
local pendingParseBody = nil
local pendingParseLabel = nil
local pendingParseOnUnusable = nil
local pendingParseCursor = 1
local pendingParseResults = nil
local PARSE_RECORDS_PER_TICK = 1000

local function finishBrowserLoad(list, failed)
    allEntities = list
    browserLoading = false
    browserLoadingSince = nil
    browserFailed = failed == true
    render()
end

local function startParse(body, label, onUnusable)
    pendingParseBody = body
    pendingParseLabel = label
    pendingParseOnUnusable = onUnusable
    pendingParseCursor = 1
    pendingParseResults = {}
end

local function stepParse()
    local body = pendingParseBody
    local results = pendingParseResults
    local len = string.len(body)
    local cur = pendingParseCursor
    local recordsProcessed = 0

    while cur <= len and recordsProcessed < PARSE_RECORDS_PER_TICK do
        local tab = string.find(body, "\t", cur, true)
        local nl = string.find(body, "\n", cur, true)
        if not nl then
            nl = len + 1
        end

        local entityId, friendlyName
        if tab and tab < nl then
            entityId = string.sub(body, cur, tab - 1)
            friendlyName = string.sub(body, tab + 1, nl - 1)
        else
            entityId = string.sub(body, cur, nl - 1)
            friendlyName = entityId
        end

        entityId = noctalia.string.trim(entityId)
        friendlyName = noctalia.string.trim(friendlyName)

        if entityId ~= "" then
            local dot = string.find(entityId, ".", 1, true)
            table.insert(results, {
                entity_id = entityId,
                friendly_name = friendlyName ~= "" and friendlyName or entityId,
                domain = dot and string.sub(entityId, 1, dot - 1) or entityId,
            })
        end

        cur = nl + 1
        recordsProcessed = recordsProcessed + 1
    end

    pendingParseCursor = cur

    if cur > len then
        pendingParseBody = nil
        pendingParseResults = nil
        finishBrowserLoad(results, false)
    end
end

local function fetchAllEntities()
    if browserLoading then return end
    browserLoading = true
    browserLoadingSince = os.clock()
    browserFailed = false
    render()

    haPost("/api/template", { template = ENTITY_LIST_TEMPLATE }, function(resp)
        startParse(resp.body, "full", function()
            haPost("/api/template", { template = ENTITY_ID_TEMPLATE }, function(resp2)
                startParse(resp2.body, "ids", function()
                    finishBrowserLoad({}, true)
                end)
            end, function() finishBrowserLoad({}, true) end)
        end)
        stepParse()
    end, function()
        finishBrowserLoad({}, true)
    end)
end

-- Pending toggle reconciliation
local function isPendingTimedOut(eid, now)
    local start = pendingSince[eid]
    return not start or (now - start) > PENDING_TIMEOUT_SECONDS
end

local function clearPending(eid)
    pendingToggle[eid] = nil
    pendingSince[eid] = nil
end

local function reconcilePending(now)
    local changed = false
    for eid, expected in pairs(pendingToggle) do
        local real = entityStates[eid]
        if not real or real.state == expected or isPendingTimedOut(eid, now) then
            clearPending(eid)
            changed = true
        end
    end
    return changed
end

local function initDraft(eid)
    if not sliderDraft[eid] then
        local current = entityStates[eid]
        local isOff = not current or current.state == "off"
        local bVal = 0
        if not isOff then
            bVal = (current.brightness and current.brightness > 0) and current.brightness or 255
        end
        sliderDraft[eid] = {
            brightness = bVal,
            color_temp = (current and current.color_temp and current.color_temp > 0) and current.color_temp or 4000,
            hue = (current and current.hue) or 0,
            volume = (current and current.volume_level) and math.floor(current.volume_level * 100 + 0.5) or 50,
        }
    end
end

local function actEntity(eid)
    local entity = entityStates[eid]
    if not entity then return end
    local d = entity.domain
    if d == "script" then
        callService("script", "turn_on", eid)
    elseif d == "automation" then
        callService("automation", "trigger", eid)
    elseif d == "media_player" then
        local isPlaying = entity.state == "playing"
        callService("media_player", isPlaying and "media_pause" or "media_play", eid)
    else
        local newState = entity.state == "on" and "off" or "on"
        pendingToggle[eid] = newState
        pendingSince[eid] = os.clock()
        callService(d, "toggle", eid, nil, function()
            clearPending(eid)
            render()
        end)
        render()
    end
end

local function expandEntity(eid)
    if expandedEntityId == eid then
        expandedEntityId = nil
    else
        sliderDraft[eid] = nil
        sliderDirty[eid] = nil
        expandedEntityId = eid
    end
    render()
end

function onNoop() end

-- Light controls
local function onLightBrightnessSlide(eid, value)
    initDraft(eid)
    local val = math.floor((tonumber(value) or 255) + 0.5)
    sliderDraft[eid].brightness = val
    render()
end

local function onLightBrightnessCommit(eid, value)
    initDraft(eid)
    local val = (sliderDraft[eid] and sliderDraft[eid].brightness) or math.floor((tonumber(value) or 0) + 0.5)
    sliderDraft[eid].brightness = val
    if val <= 0 then
        pendingToggle[eid] = "off"
        pendingSince[eid] = os.clock()
        haPost("/api/services/light/turn_off", { entity_id = eid }, function()
            clearPending(eid)
            render()
        end)
    else
        pendingToggle[eid] = "on"
        pendingSince[eid] = os.clock()
        haPost("/api/services/light/turn_on", {
            entity_id = eid,
            brightness = val,
        }, function()
            clearPending(eid)
            render()
        end)
    end
    render()
end

local function onColorTempSlide(eid, value)
    initDraft(eid)
    sliderDraft[eid].color_temp = math.floor((tonumber(value) or 4000) + 0.5)
    render()
end

local function onColorTempCommit(eid, value)
    local val = math.floor((tonumber(value) or 4000) + 0.5)
    initDraft(eid)
    sliderDraft[eid].color_temp = val
    haPost("/api/services/light/turn_on", {
        entity_id = eid,
        color_temp_kelvin = val,
    })
end

local function onHueSlide(eid, value)
    initDraft(eid)
    sliderDraft[eid].hue = math.floor((tonumber(value) or 0) + 0.5)
    render()
end

local function onHueCommit(eid, value)
    local val = math.floor((tonumber(value) or 0) + 0.5)
    initDraft(eid)
    sliderDraft[eid].hue = val
    haPost("/api/services/light/turn_on", {
        entity_id = eid,
        hs_color = { val, 100 },
    })
end

-- Media controls
local function onMediaPlayPause(eid)
    local entity = entityStates[eid]
    if not entity then return end
    callService("media_player", "media_play_pause", eid)
end

local function onMediaNext(eid)
    callService("media_player", "media_next_track", eid)
end

local function onMediaPrev(eid)
    callService("media_player", "media_previous_track", eid)
end

local function onMediaMute(eid)
    local entity = entityStates[eid]
    local isMuted = entity and entity.is_volume_muted or false
    callService("media_player", "volume_mute", eid, { is_volume_muted = not isMuted })
end

local function onMediaVolumeSlide(eid, value)
    initDraft(eid)
    sliderDraft[eid].volume = math.floor((tonumber(value) or 50) + 0.5)
    render()
end

local function onMediaVolumeCommit(eid, value)
    local pct = math.floor((tonumber(value) or 50) + 0.5)
    initDraft(eid)
    sliderDraft[eid].volume = pct
    callService("media_player", "volume_set", eid, { volume_level = pct / 100.0 })
end

-- Speaker grouping
local function onToggleJoinSpeaker(masterEid, targetEid, isJoined)
    if isJoined then
        callService("media_player", "unjoin", targetEid)
    else
        callService("media_player", "join", masterEid, { group_members = { targetEid } })
    end
end

-- Music Assistant actions
local function searchMusicAssistant(query)
    if not query or noctalia.string.trim(query) == "" then
        maSearchResults = { artists = {}, albums = {}, playlists = {}, tracks = {} }
        maSearching = false
        render()
        return
    end

    maSearching = true
    render()

    ensureMaConfigEntry(function(entry_id)
        local payload = {
            config_entry_id = entry_id,
            name = query,
        }
        haPost("/api/services/music_assistant/search?return_response=true", payload, function(resp)
            maSearching = false
            local data = noctalia.json.decode(resp.body)
            local sr = (type(data) == "table" and data.service_response) or {}
            maSearchResults = {
                artists = sr.artists or {},
                albums = sr.albums or {},
                playlists = sr.playlists or {},
                tracks = sr.tracks or {},
            }
            render()
        end, function()
            maSearching = false
            maSearchResults = { artists = {}, albums = {}, playlists = {}, tracks = {} }
            render()
        end)
    end)
end

local function fetchMaLibrary(category, force)
    if not force and (maLibLoaded[category] or maLibLoading[category]) then
        return
    end

    maLibLoading[category] = true
    render()

    ensureMaConfigEntry(function(entry_id)
        -- Map UI category to MA media_type: "albums" -> "album", "artists" -> "artist", etc.
        local mediaTypeMap = {
            albums = "album",
            artists = "artist",
            tracks = "track",
            radio = "radio",
            playlists = "playlist",
        }
        local mtype = mediaTypeMap[category] or "album"
        local payload = {
            config_entry_id = entry_id,
            media_type = mtype,
            limit = 50,
        }
        haPost("/api/services/music_assistant/get_library?return_response=true", payload, function(resp)
            maLibLoading[category] = false
            maLibLoaded[category] = true
            local ok, data = pcall(function()
                return resp and resp.body and noctalia.json.decode(resp.body)
            end)
            if ok and type(data) == "table" then
                local sr = data.service_response or {}
                maLibItems[category] = sr.items or {}
            else
                maLibItems[category] = {}
            end
            render()
        end, function()
            maLibLoading[category] = false
            maLibLoaded[category] = true
            maLibItems[category] = {}
            render()
        end)
    end)
end

local function playMaItem(itemUri, mediaType)
    local player = maSelectedSpeaker
    if not player then
        for eid, e in pairs(entityStates) do
            if e.domain == "media_player" then player = eid; break end
        end
    end
    local playerName = (entityStates[player] and entityStates[player].friendly_name) or player
    haPost("/api/services/music_assistant/play_media", {
        entity_id = player,
        media_id = itemUri,
        enqueue = "play",
    })
    noctalia.notify(noctalia.tr("panel.music_assistant_title"), "Playing on " .. playerName)
end

-- Helpers
local function isControllable(domain)
    return domain == "light" or domain == "switch" or domain == "input_boolean"
        or domain == "fan" or domain == "cover" or domain == "lock" or domain == "media_player"
end

local function isAutomation(domain)
    return domain == "automation" or domain == "script"
end

local function isSensor(domain)
    return domain == "sensor" or domain == "binary_sensor" or domain == "weather" or domain == "number"
end

local function domainGlyph(domain)
    local g = {
        light = "bulb", switch = "toggle-right", input_boolean = "toggle-right",
        sensor = "chart-line", binary_sensor = "activity", climate = "temperature",
        cover = "door", fan = "wind", lock = "lock", media_player = "device-speaker",
        weather = "cloud", automation = "robot", script = "player-play",
    }
    return g[domain] or "smart-home"
end


local function resolveLightGlyph(entity, isOn)
    local fn = (entity.friendly_name or ""):lower()
    local eid = (entity.entity_id or ""):lower()
    local name = fn .. " " .. eid

    -- Check explicit HA icon
    if entity.icon and type(entity.icon) == "string" then
        local stripped = entity.icon:gsub("^mdi:", ""):gsub("^ph:", ""):gsub("_", "-")
        if stripped ~= "lightbulb" and stripped ~= "circle-outline" then
            return stripped
        end
    end

    -- Match room names
    if name:find("living", 1, true) or name:find("couch", 1, true) or name:find("salon", 1, true) then
        return "sofa"
    elseif name:find("bed", 1, true) or name:find("sleep", 1, true) then
        return "bed"
    elseif name:find("kitchen", 1, true) or name:find("cook", 1, true) or name:find("dining", 1, true) then
        return "coffee"
    elseif name:find("bath", 1, true) or name:find("shower", 1, true) or name:find("toilet", 1, true) or name:find("wc", 1, true) then
        return "bath"
    elseif name:find("office", 1, true) or name:find("desk", 1, true) or name:find("work", 1, true) or name:find("study", 1, true) then
        return "device-laptop"
    elseif name:find("balcony", 1, true) or name:find("terrace", 1, true) or name:find("patio", 1, true) or name:find("deck", 1, true) then
        return "plant"
    elseif name:find("sauna", 1, true) then
        return "flame"
    elseif name:find("wardrobe", 1, true) or name:find("closet", 1, true) or name:find("coat", 1, true) then
        return "hanger"
    elseif name:find("entrance", 1, true) or name:find("hall", 1, true) or name:find("corridor", 1, true) or name:find("entry", 1, true) then
        return "door"
    end

    return isOn and "bulb" or "bulb-off"
end

local function stateGlyph(domain, isOn, entity)
    if domain == "light" then
        if entity then return resolveLightGlyph(entity, isOn) end
        return isOn and "bulb" or "bulb-off"
    elseif domain == "switch" or domain == "input_boolean" then return isOn and "toggle-right" or "toggle-left"
    elseif domain == "fan" then return isOn and "wind" or "wind-off"
    elseif domain == "lock" then return isOn and "lock" or "lock-open"
    elseif domain == "cover" then return isOn and "door-open" or "door"
    elseif domain == "media_player" then
        if entity and entity.state == "playing" then return "player-pause" end
        return "player-play"
    end
    return domainGlyph(domain)
end

local function entityStateLabel(entity)
    if isSensor(entity.domain) then
        return entity.state .. (entity.unit ~= "" and " " .. entity.unit or "")
    end
    if entity.domain == "light" and entity.state == "on" and entity.brightness and entity.brightness >= 0 then
        local pct = math.floor(entity.brightness / 255 * 100 + 0.5)
        return tr("state_on_brightness", { percent = pct })
    end
    if entity.domain == "media_player" then
        if entity.media_title and entity.media_title ~= "" then
            local s = entity.media_title
            if entity.media_artist and entity.media_artist ~= "" then
                s = s .. " — " .. entity.media_artist
            end
            return s
        end
    end
    return entity.state
end

-- Building Entity Cards

-- Artwork & thumbnail caching
local downloadedImages = {} -- url -> local_path
local downloadingImages = {} -- url -> boolean

local function getThumbCacheDir()
    local dataDir = noctalia.pluginDataDir() or "/tmp"
    return dataDir .. "/thumbs"
end

local function hashString(str)
    local hash = 5381
    for i = 1, #str do
        local b = string.byte(str, i)
        hash = (hash * 33 + b) % 2147483647
    end
    return string.format("%x", hash)
end

local function cleanFilename(str)
    local prefix = str:gsub("[^%w]", "_")
    if #prefix > 20 then prefix = prefix:sub(-20) end
    return prefix .. "_" .. hashString(str)
end

local function getImagePath(url)
    if not url or url == "" then return nil end
    if downloadedImages[url] and noctalia.fileExists(downloadedImages[url]) then
        return downloadedImages[url]
    end

    -- Construct full URL if relative path from HA (e.g. /api/media_player_proxy/...)
    local fullUrl = url
    if url:sub(1, 1) == "/" then
        fullUrl = getCleanUrl() .. url
    end

    local cacheDir = getThumbCacheDir()
    local hash = cleanFilename(url) .. ".jpg"
    local localPath = cacheDir .. "/" .. hash

    if noctalia.fileExists(localPath) then
        downloadedImages[url] = localPath
        return localPath
    end

    if not downloadingImages[url] then
        downloadingImages[url] = true
        local cleanToken = getCleanToken()
        local authHeader = ""
        if url:sub(1, 1) == "/" and cleanToken ~= "" then
            authHeader = [=[-H "Authorization: Bearer ]=] .. cleanToken .. [=["]=]
        end
        local cmd = string.format("mkdir -p %q && curl -k -s -L %s -o %q %q", cacheDir, authHeader, localPath, fullUrl)
        noctalia.runAsync(cmd, function()
            downloadingImages[url] = nil
            if noctalia.fileExists(localPath) then
                downloadedImages[url] = localPath
                if not renderScheduled then
                    renderScheduled = true
                    panel.setWantsSecondTicks(true)
                end
            end
        end)
    end

    return nil
end

local function renderCover(url, size, fallbackGlyph, radius)
    radius = radius or 8
    local localPath = getImagePath(url)
    if localPath then
        return ui.column({
            width = size,
            height = size,
            radius = radius,
            align = "center",
            justify = "center",
        }, {
            ui.image({
                path = localPath,
                width = size,
                height = size,
                radius = radius,
                fit = "cover",
            }),
        })
    end
    return ui.column({
        width = size,
        height = size,
        radius = radius,
        fill = "surface_variant/0.4",
        align = "center",
        justify = "center",
    }, {
        ui.glyph({ name = fallbackGlyph or "music", size = math.floor(size * 0.55), color = "on_surface_variant" }),
    })
end

local function buildLightExpandedSection(entity)
    local eid = entity.entity_id
    initDraft(eid)
    local draft = sliderDraft[eid]
    local rows = {}

    if entity.supports_color_temp then
        local ctk = draft.color_temp
        table.insert(rows, ui.row({ align = "center", gap = 8 }, {
            ui.glyph({ name = "temperature", size = 16, color = "on_surface_variant" }),
            ui.slider({
                min = 2000, max = 6500, step = 50, value = ctk,
                onChange = function(v) onColorTempSlide(eid, v) end,
                onDragEnd = function(v) onColorTempCommit(eid, v) end,
                flexGrow = 1,
            }),
            ui.label({ text = math.floor(ctk) .. "K", fontSize = 12, color = "on_surface_variant" }),
        }))
    end

    if entity.supports_rgb then
        local hv = draft.hue
        table.insert(rows, ui.row({ align = "center", gap = 8 }, {
            ui.glyph({ name = "palette", size = 16, color = "on_surface_variant" }),
            ui.slider({
                min = 0, max = 360, step = 1, value = hv,
                onChange = function(v) onHueSlide(eid, v) end,
                onDragEnd = function(v) onHueCommit(eid, v) end,
                flexGrow = 1,
            }),
            ui.label({ text = math.floor(hv) .. "°", fontSize = 12, color = "on_surface_variant" }),
        }))
    end

    if #rows == 0 then return nil end
    return ui.column({ gap = 8, padding = 4 }, rows)
end

local function buildEntityCard(entity)
    local pending = pendingToggle[entity.entity_id]
    local isOn = (pending or entity.state) == "on" or entity.state == "playing"
    local domain = entity.domain
    local isExpanded = expandedEntityId == entity.entity_id

    local canExpand = domain == "light" and (entity.supports_color_temp or entity.supports_rgb)

    local expandBtn
    if canExpand then
        expandBtn = ui.button({
            glyph = isExpanded and "chevron-up" or "chevron-down",
            onClick = function() expandEntity(entity.entity_id) end,
        })
    end

    local isPending = pending ~= nil
    local iconClick = isPending and onNoop
        or (isControllable(domain) or isAutomation(domain)) and function() actEntity(entity.entity_id) end or onNoop
    local iconGlyph = isPending and "loader"
        or isAutomation(domain) and "player-play" or stateGlyph(domain, isOn, entity)

    -- Primary Row
    local rowChildren = {}
    if domain == "media_player" and entity.entity_picture and entity.entity_picture ~= "" then
        table.insert(rowChildren, renderCover(entity.entity_picture, 42, "device-speaker", 6))
    else
        table.insert(rowChildren, ui.button({ glyph = iconGlyph, onClick = iconClick }))
    end

    table.insert(rowChildren, ui.column({ flexGrow = 1, minWidth = 180, gap = 2, align = "stretch" }, {
        ui.label({ text = entity.friendly_name or entity.entity_id, fontWeight = "medium", maxLines = 1 }),
        ui.label({ text = entityStateLabel(entity), color = "on_surface_variant", fontSize = 12, maxLines = 1 }),
    }))

    if expandBtn then table.insert(rowChildren, expandBtn) end

    local cardChildren = { ui.row({ align = "center", gap = 8 }, rowChildren) }

    -- If light: sleek row with only entity icon and slider!
    if domain == "light" then
        initDraft(entity.entity_id)
        local bv = sliderDraft[entity.entity_id].brightness
        if not isOn then
            bv = 0
        end
        local pct = math.floor(bv / 255 * 100 + 0.5)
        return ui.row({
            key = "card-" .. entity.entity_id,
            align = "center",
            gap = 12,
            padding = 8,
            radius = 8,
            fill = isOn and "primary/0.08" or "surface_variant/0.3",
        }, {
            ui.button({
                glyph = iconGlyph,
                variant = isOn and "primary" or "default",
                onClick = iconClick,
                tooltip = entity.friendly_name or entity.entity_id,
            }),
            ui.slider({
                min = 0, max = 255, step = 1, value = bv,
                onChange = function(v) onLightBrightnessSlide(entity.entity_id, v) end,
                onDragEnd = function(v) onLightBrightnessCommit(entity.entity_id, v) end,
                flexGrow = 1,
            }),
            ui.label({ text = pct .. "%", fontSize = 12, color = "on_surface_variant", width = 36 }),
        })
    end

    -- Default inline controls for Media Players
    if domain == "media_player" then
        initDraft(entity.entity_id)
        local curVol = sliderDraft[entity.entity_id].volume
        local isMuted = entity.is_volume_muted or false
        local isPlaying = entity.state == "playing"

        -- Controls Row: Prev, Play/Pause, Next, Mute
        local ctrlRow = ui.row({ align = "center", gap = 6 }, {
            ui.button({ glyph = "player-skip-back", onClick = function() onMediaPrev(entity.entity_id) end }),
            ui.button({ glyph = isPlaying and "player-pause" or "player-play", onClick = function() onMediaPlayPause(entity.entity_id) end }),
            ui.button({ glyph = "player-skip-forward", onClick = function() onMediaNext(entity.entity_id) end }),
            ui.button({ glyph = isMuted and "volume-off" or "volume", onClick = function() onMediaMute(entity.entity_id) end }),
            ui.slider({
                min = 0, max = 100, step = 1, value = curVol,
                onChange = function(v) onMediaVolumeSlide(entity.entity_id, v) end,
                onDragEnd = function(v) onMediaVolumeCommit(entity.entity_id, v) end,
                flexGrow = 1,
            }),
            ui.label({ text = curVol .. "%", fontSize = 12, color = "on_surface_variant", width = 36 }),
        })
        table.insert(cardChildren, ctrlRow)
    end

    -- Color/Hue section if expanded
    if isExpanded and canExpand then
        local exp = buildLightExpandedSection(entity)
        if exp then table.insert(cardChildren, exp) end
    end

    return ui.column({
        key = "card-" .. entity.entity_id,
        gap = 6,
        padding = 8,
        radius = 8,
        fill = "surface_variant/0.4",
        align = "stretch",
    }, cardChildren)
end

local function getOrderedIds()
    local ids, seen = {}, {}
    for _, eid in ipairs(monitoredEntities) do
        if entityStates[eid] then
            table.insert(ids, eid)
            seen[eid] = true
        end
    end
    return ids
end

-- Tab 1: Monitored Devices
local function buildDevicesView()
    local ids = getOrderedIds()
    if #ids == 0 then
        return ui.column({ align = "center", justify = "center", flexGrow = 1, gap = 8 }, {
            ui.glyph({ name = "smart-home", size = 36, color = "on_surface_variant" }),
            ui.label({ text = tr("no_entities_monitored"), color = "on_surface_variant" }),
            ui.button({ text = "Open Browser", glyph = "search", onClick = function()
                activeTab = "browser"
                fetchAllEntities()
            end }),
        })
    end

    local cards = {}
    for _, eid in ipairs(ids) do
        local card = buildEntityCard(entityStates[eid])
        table.insert(cards, card)
    end
    return ui.scroll({ flexGrow = 1, gap = 8, align = "stretch" }, cards)
end

-- Tab 2: Music Assistant Search & Browse
local function buildMusicAssistantView()
    local children = {}

    local isSearching = noctalia.string.trim(maSearchQuery) ~= ""

    -- Search bar with clear button
    local searchRowChildren = {
        ui.input({
            key = "ma_search",
            placeholder = "Search artists, tracks, albums...",
            flexGrow = 1,
            onSubmit = function(text)
                maSearchQuery = text or ""
                searchMusicAssistant(maSearchQuery)
            end,
            onChange = function(text)
                maSearchQuery = text or ""
            end,
        }),
    }

    if isSearching then
        table.insert(searchRowChildren, ui.button({
            glyph = "x",
            variant = "default",
            onClick = function()
                maSearchQuery = ""
                searchMusicAssistant("")
            end,
        }))
    end

    table.insert(searchRowChildren, ui.button({
        glyph = "search",
        variant = isSearching and "primary" or "default",
        onClick = function() searchMusicAssistant(maSearchQuery) end,
    }))

    table.insert(children, ui.row({ align = "center", gap = 8 }, searchRowChildren))

    -- If search query is active, show search results mode
    if isSearching then
        if maSearching then
            table.insert(children, ui.column({ align = "center", justify = "center", flexGrow = 1, gap = 8 }, {
                ui.glyph({ name = "loader", size = 32, color = "primary" }),
                ui.label({ text = tr("ma_searching"), color = "on_surface_variant" }),
            }))
            return ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children)
        end

        -- Category filter tabs for search
        local catRow = ui.row({ align = "center", gap = 6 }, {
            ui.button({
                text = "All",
                variant = maSearchCategory == "all" and "primary" or "default",
                onClick = function() maSearchCategory = "all"; render() end,
            }),
            ui.button({
                text = tr("ma_artists"),
                variant = maSearchCategory == "artists" and "primary" or "default",
                onClick = function() maSearchCategory = "artists"; render() end,
            }),
            ui.button({
                text = tr("ma_albums"),
                variant = maSearchCategory == "albums" and "primary" or "default",
                onClick = function() maSearchCategory = "albums"; render() end,
            }),
            ui.button({
                text = tr("ma_playlists"),
                variant = maSearchCategory == "playlists" and "primary" or "default",
                onClick = function() maSearchCategory = "playlists"; render() end,
            }),
            ui.button({
                text = tr("ma_tracks"),
                variant = maSearchCategory == "tracks" and "primary" or "default",
                onClick = function() maSearchCategory = "tracks"; render() end,
            }),
        })
        table.insert(children, catRow)

        local resultsList = {}

        local function getArtistString(item)
            if type(item.artists) == "table" and #item.artists > 0 then
                local aNames = {}
                for _, a in ipairs(item.artists) do
                    if type(a) == "table" and a.name and a.name ~= "" then
                        table.insert(aNames, a.name)
                    elseif type(a) == "string" and a ~= "" then
                        table.insert(aNames, a)
                    end
                end
                if #aNames > 0 then return table.concat(aNames, ", ") end
            end
            if type(item.artist_string) == "string" and item.artist_string ~= "" then
                return item.artist_string
            end
            if type(item.artist) == "string" and item.artist ~= "" then
                return item.artist
            end
            return nil
        end

        local function getItemSubtitle(item, mediaType)
            local parts = {}
            local artist = getArtistString(item)
            if artist then table.insert(parts, artist) end

            if mediaType == "track" then
                if type(item.album) == "table" and item.album.name and item.album.name ~= "" then
                    table.insert(parts, item.album.name)
                elseif type(item.album) == "string" and item.album ~= "" then
                    table.insert(parts, item.album)
                end
            end

            if type(item.version) == "string" and item.version ~= "" then
                table.insert(parts, "(" .. item.version .. ")")
            end

            if #parts > 0 then
                return table.concat(parts, " • ")
            end
            return nil
        end

        local function addSection(title, items, mediaType, fallbackGlyph)
            if #items == 0 then return end
            table.insert(resultsList, ui.label({ key = "sec-" .. title, text = title, fontWeight = "bold", color = "primary", fontSize = 14 }))
            for i, item in ipairs(items) do
                local itemName = item.name or "Unknown"
                local itemSub = getItemSubtitle(item, mediaType)
                local itemUri = item.uri
                local itemImg = item.image or item.fanart_image or item.discart_image

                local infoChildren = {
                    ui.label({ text = itemName, fontWeight = "medium", maxLines = 1 }),
                }
                if itemSub and itemSub ~= "" then
                    table.insert(infoChildren, ui.label({ text = itemSub, color = "on_surface_variant", fontSize = 12, maxLines = 1 }))
                end

                table.insert(resultsList, ui.row({
                    key = "ma-s-" .. mediaType .. "-" .. i,
                    align = "center",
                    gap = 12,
                    padding = 8,
                    radius = 8,
                    fill = "surface_variant/0.3",
                }, {
                    renderCover(itemImg, 44, fallbackGlyph, 6),
                    ui.column({ flexGrow = 1, gap = 2, align = "stretch" }, infoChildren),
                    ui.button({
                        glyph = "player-play",
                        variant = "primary",
                        onClick = function() playMaItem(itemUri, mediaType) end,
                    }),
                }))
            end
        end

        if maSearchCategory == "all" or maSearchCategory == "tracks" then
            addSection("Tracks", maSearchResults.tracks, "track", "music")
        end
        if maSearchCategory == "all" or maSearchCategory == "albums" then
            addSection("Albums", maSearchResults.albums, "album", "disc")
        end
        if maSearchCategory == "all" or maSearchCategory == "playlists" then
            addSection("Playlists", maSearchResults.playlists, "playlist", "playlist")
        end
        if maSearchCategory == "all" or maSearchCategory == "artists" then
            addSection("Artists", maSearchResults.artists, "artist", "user")
        end

        if #resultsList == 0 then
            table.insert(resultsList, ui.column({ align = "center", justify = "center", padding = 24 }, {
                ui.glyph({ name = "music-search", size = 36, color = "on_surface_variant" }),
                ui.label({ text = tr("ma_no_results"), color = "on_surface_variant" }),
            }))
        end

        table.insert(children, ui.scroll({ flexGrow = 1, gap = 6, align = "stretch" }, resultsList))
        return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children)
    end

    -- Library mode (when not searching)
    -- Sub-tabs: Albums, Artists, Tracks, Radio, Playlists
    local subTabs = {
        { id = "albums", label = "Albums", glyph = "disc" },
        { id = "artists", label = "Artists", glyph = "user" },
        { id = "tracks", label = "Tracks", glyph = "music" },
        { id = "radio", label = "Radio", glyph = "broadcast" },
        { id = "playlists", label = "Playlists", glyph = "playlist" },
    }

    local subTabButtons = {}
    for _, tab in ipairs(subTabs) do
        table.insert(subTabButtons, ui.button({
            text = tab.label,
            glyph = tab.glyph,
            variant = maLibSubTab == tab.id and "primary" or "default",
            onClick = function()
                maLibSubTab = tab.id
                fetchMaLibrary(tab.id)
                render()
            end,
            flexGrow = 1,
        }))
    end
    table.insert(children, ui.row({ align = "center", gap = 6 }, subTabButtons))

    -- Trigger fetch if not loaded or loading
    if not maLibLoaded[maLibSubTab] and not maLibLoading[maLibSubTab] then
        fetchMaLibrary(maLibSubTab)
    end

    if maLibLoading[maLibSubTab] then
        table.insert(children, ui.column({ align = "center", justify = "center", flexGrow = 1, gap = 8, padding = 32 }, {
            ui.glyph({ name = "loader", size = 32, color = "primary" }),
            ui.label({ text = "Loading library...", color = "on_surface_variant" }),
        }))
        return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children)
    end

    local libItems = maLibItems[maLibSubTab] or {}
    local libList = {}

    local fallbackGlyphs = {
        albums = "disc",
        artists = "user",
        tracks = "music",
        radio = "broadcast",
        playlists = "playlist",
    }
    local defaultGlyph = fallbackGlyphs[maLibSubTab] or "music"

    local function getLibSubtitle(item, category)
        local parts = {}
        if category == "albums" or category == "tracks" then
            if type(item.artists) == "table" and #item.artists > 0 then
                local aNames = {}
                for _, a in ipairs(item.artists) do
                    if type(a) == "table" and a.name and a.name ~= "" then
                        table.insert(aNames, a.name)
                    elseif type(a) == "string" and a ~= "" then
                        table.insert(aNames, a)
                    end
                end
                if #aNames > 0 then table.insert(parts, table.concat(aNames, ", ")) end
            end
            if category == "tracks" and type(item.album) == "table" and item.album.name then
                table.insert(parts, item.album.name)
            end
        elseif category == "artists" then
            if type(item.musicbrainz_id) == "string" then
                -- artist info if available
            end
        elseif category == "radio" then
            if type(item.provider) == "string" then
                table.insert(parts, item.provider)
            end
        end

        if #parts > 0 then
            return table.concat(parts, " • ")
        end
        return nil
    end

    for i, item in ipairs(libItems) do
        local itemName = item.name or "Unknown"
        local itemSub = getLibSubtitle(item, maLibSubTab)
        local itemUri = item.uri
        local itemImg = item.image or item.fanart_image or item.discart_image

        local infoChildren = {
            ui.label({ text = itemName, fontWeight = "medium", maxLines = 1 }),
        }
        if itemSub and itemSub ~= "" then
            table.insert(infoChildren, ui.label({ text = itemSub, color = "on_surface_variant", fontSize = 12, maxLines = 1 }))
        end

        table.insert(libList, ui.row({
            key = "ma-lib-" .. maLibSubTab .. "-" .. (itemUri or tostring(i)),
            align = "center",
            gap = 12,
            padding = 8,
            radius = 8,
            fill = "surface_variant/0.3",
        }, {
            renderCover(itemImg, 44, defaultGlyph, 6),
            ui.column({ flexGrow = 1, gap = 2, align = "stretch" }, infoChildren),
            ui.button({
                glyph = "player-play",
                variant = "primary",
                onClick = function() playMaItem(itemUri, item.media_type) end,
            }),
        }))
    end

    if #libList == 0 then
        table.insert(libList, ui.column({ align = "center", justify = "center", padding = 24 }, {
            ui.glyph({ name = defaultGlyph, size = 36, color = "on_surface_variant" }),
            ui.label({ text = "No library items found", color = "on_surface_variant" }),
        }))
    end

    table.insert(children, ui.scroll({ flexGrow = 1, gap = 6, align = "stretch" }, libList))
    return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children)
end

-- Tab 3: Speaker Grouping & Linking
local function buildSpeakersView()
    local master = entityStates[maSelectedSpeaker]
    local masterName = (master and master.friendly_name) or maSelectedSpeaker
    local masterMembers = (master and master.group_members) or {}

    local isMember = function(targetEid)
        for _, m in ipairs(masterMembers) do
            if m == targetEid then return true end
        end
        return false
    end

    local children = {
        ui.column({ gap = 4 }, {
            ui.label({ text = tr("speakers_title"), fontSize = 15, fontWeight = "bold", color = "primary" }),
            ui.label({ text = tr("speakers_desc"), fontSize = 12, color = "on_surface_variant" }),
        }),
    }

    local speakerCards = {}
    for eid, entity in pairs(entityStates) do
        if entity.domain == "media_player" then
            local isCurrentMaster = (eid == maSelectedSpeaker)
            local linked = isMember(eid)

            local statusBadge = isCurrentMaster and "Master" or (linked and tr("speaker_linked") or tr("speaker_unlinked"))
            local badgeColor = isCurrentMaster and "primary" or (linked and "secondary" or "on_surface_variant")

            local linkButton
            if not isCurrentMaster then
                linkButton = ui.button({
                    glyph = linked and "link-off" or "link",
                    text = linked and "Unlink" or "Link",
                    variant = linked and "default" or "primary",
                    onClick = function()
                        onToggleJoinSpeaker(maSelectedSpeaker, eid, linked)
                    end,
                })
            end

            local selectMasterBtn = ui.button({
                glyph = isCurrentMaster and "check" or "circle",
                variant = isCurrentMaster and "primary" or "default",
                onClick = function()
                    maSelectedSpeaker = eid
                    render()
                end,
            })

            table.insert(speakerCards, ui.row({
                key = "spk-" .. eid,
                align = "center",
                gap = 8,
                padding = 8,
                radius = 8,
                fill = isCurrentMaster and "primary/0.1" or "surface_variant/0.3",
            }, {
                selectMasterBtn,
                ui.column({ flexGrow = 1, gap = 2 }, {
                    ui.label({ text = entity.friendly_name or eid, fontWeight = "medium" }),
                    ui.label({ text = statusBadge, fontSize = 11, color = badgeColor }),
                }),
                linkButton or ui.box({ width = 1 }),
            }))
        end
    end

    table.insert(children, ui.scroll({ flexGrow = 1, gap = 6, align = "stretch" }, speakerCards))
    return ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children)
end

-- Tab 4: Entity Browser / Pinning
local function buildBrowserView()
    if browserLoading then
        return ui.label({ text = tr("loading_entities"), color = "on_surface_variant" })
    end
    if browserFailed then
        return ui.label({ text = tr("load_entities_failed"), color = "error" })
    end

    local q = searchText:lower()
    local rows = {}

    -- Section 1: Pinned Entities (always shown at top with reordering)
    if #monitoredEntities > 0 and q == "" then
        table.insert(rows, ui.label({ text = "Pinned Entities (" .. #monitoredEntities .. ")", fontWeight = "bold", color = "primary", fontSize = 13 }))
        for i, eid in ipairs(monitoredEntities) do
            local entity = entityStates[eid]
            local fname = (entity and entity.friendly_name) or eid
            local canMoveUp = (i > 1)
            local canMoveDown = (i < #monitoredEntities)

            table.insert(rows, ui.row({
                align = "center",
                gap = 8,
                padding = 6,
                radius = 6,
                fill = "primary/0.06",
            }, {
                ui.button({
                    glyph = "chevron-up",
                    enabled = canMoveUp,
                    onClick = function() movePinned(eid, -1) end,
                }),
                ui.button({
                    glyph = "chevron-down",
                    enabled = canMoveDown,
                    onClick = function() movePinned(eid, 1) end,
                }),
                ui.column({ flexGrow = 1, gap = 2 }, {
                    ui.label({ text = fname, fontWeight = "medium" }),
                    ui.label({ text = eid, color = "on_surface_variant", fontSize = 11 }),
                }),
                ui.button({
                    glyph = "pin-filled",
                    variant = "primary",
                    onClick = function() toggleBrowserPin(eid) end,
                }),
            }))
        end
        table.insert(rows, ui.separator({ thickness = 1, color = "outline/0.2" }))
    end

    -- Section 2: All other Entities matching query
    local filtered = {}
    local truncated = false
    for _, e in ipairs(allEntities) do
        if q == "" or e.entity_id:lower():find(q, 1, true) or e.friendly_name:lower():find(q, 1, true) then
            if #filtered >= MAX_BROWSER_ROWS then
                truncated = true
                break
            end
            table.insert(filtered, e)
        end
    end

    if #filtered > 0 then
        table.insert(rows, ui.label({ text = q == "" and "All Available Entities" or "Search Results (" .. #filtered .. ")", fontWeight = "bold", color = "on_surface_variant", fontSize = 12 }))
        for _, e in ipairs(filtered) do
            local entityId = e.entity_id
            local pinned = isPinned(entityId)
            table.insert(rows, ui.row({ align = "center", gap = 8, padding = 4 }, {
                ui.column({ flexGrow = 1, gap = 2 }, {
                    ui.label({ text = e.friendly_name, fontWeight = "medium" }),
                    ui.label({ text = e.entity_id, color = "on_surface_variant", fontSize = 12 }),
                }),
                ui.button({
                    glyph = pinned and "pin-filled" or "pin",
                    variant = pinned and "primary" or "default",
                    onClick = function() toggleBrowserPin(entityId) end,
                }),
            }))
        end
    elseif q ~= "" then
        table.insert(rows, ui.label({ text = tr("no_entities_match"), color = "on_surface_variant" }))
    end

    if truncated then
        table.insert(rows, ui.label({
            text = tr("browser_truncated", { count = MAX_BROWSER_ROWS }),
            color = "on_surface_variant",
            fontSize = 12,
        }))
    end

    return ui.scroll({ flexGrow = 1, gap = 6, align = "stretch" }, rows)
end

function render()
    reconcilePending(os.clock())

    if activeTab == "browser" then
        panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
            ui.row({ align = "center", gap = 8 }, {
                ui.button({ glyph = "arrow-left", onClick = function() activeTab = "devices"; render() end }),
                ui.label({ text = tr("manage_entities_title"), fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
                ui.button({ glyph = "close", onClick = function() panel.close() end }),
            }),
            ui.input({ key = "entity_search", placeholder = tr("search_placeholder"), onChange = function(v) searchText = v or ""; render() end }),
            buildBrowserView(),
        }))
        return
    end

    -- Header with Title, Status & Actions
    local header = ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = "smart-home", size = 20, color = "primary" }),
        ui.label({ text = "Home Assistant", fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
        ui.label({ text = getStatusText(), color = status == "connected" and "primary" or "on_surface_variant" }),
        ui.button({ glyph = "list-search", onClick = function() activeTab = "browser"; fetchAllEntities() end }),
        ui.button({ glyph = "close", onClick = function() panel.close() end }),
    })

    local body = buildDevicesView()

    panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
        header,
        body,
    }))
end

function onOpen(_context)
    status = noctalia.state.get("connection_status") or "unconfigured"
    entityStates = noctalia.state.get("entities") or {}
    sliderDraft = {}
    loadMonitoredEntities()
    ensureMaConfigEntry()
    panelOpenCount = panelOpenCount + 1
    panel.setWantsSecondTicks(true)
    noctalia.state.set("command", "refresh")
    noctalia.state.set("panel_open_signal", panelOpenCount)
    render()
end

function onClose()
    panel.setWantsSecondTicks(false)
end

function update()
    local now = os.clock()

    if pendingParseBody ~= nil then
        stepParse()
        return
    end

    if browserLoading and browserLoadingSince and (now - browserLoadingSince) > BROWSER_TIMEOUT_SECONDS then
        browserLoading = false
        browserLoadingSince = nil
        browserFailed = true
        reconcilePending(now)
        render()
        return
    end

    if reconcilePending(now) then
        render()
    elseif renderScheduled then
        renderScheduled = false
        render()
    end
end

noctalia.state.watch("entities", function(value)
    entityStates = value or {}
    for eid in pairs(sliderDraft) do
        if not sliderDirty[eid] then
            sliderDraft[eid] = nil
        end
    end
    reconcilePending(os.clock())
    render()
end)

noctalia.state.watch("connection_status", function(value)
    status = value or "unconfigured"
    render()
end)
