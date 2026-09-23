--!nonstrict

local haUrlRaw = noctalia.getConfig("ha_url")
local haToken = noctalia.getConfig("ha_token")

local status = "unconfigured"
local entityStates = {}
local maConfigEntryId = nil
local maSelectedSpeaker = nil

-- Navigation state
local activeTab = "music" -- "music" | "speakers"
local sliderDraft = {}
local sliderDraftUntil = {}
local volumePending = {}

-- Library state
local maLibSubTab = "albums" -- "albums" | "artists" | "tracks" | "radio" | "playlists"
local maLibItems = { albums = {}, artists = {}, tracks = {}, radio = {}, playlists = {} }
local maLibLoading = { albums = false, artists = false, tracks = false, radio = false, playlists = false }
local maLibLoaded = { albums = false, artists = false, tracks = false, radio = false, playlists = false }

-- Search state
local maSearchQuery = ""
local maSearching = false
local maSearchCategory = "all"
local maSearchResults = { artists = {}, albums = {}, playlists = {}, tracks = {} }


-- Image cache
local downloadedImages = {}
local downloadingImages = {}

local render
local renderScheduled = false

local function getCleanUrl()
    local u = noctalia.getConfig("ha_url")
    if type(u) ~= "string" or u == "" then u = haUrlRaw end
    if type(u) ~= "string" then return "" end
    return (u:gsub("/+$", ""))
end

local function getCleanToken()
    local t = noctalia.getConfig("ha_token")
    if type(t) ~= "string" or t == "" then t = haToken end
    if type(t) ~= "string" then return "" end
    return t:gsub("^%s+", ""):gsub("%s+$", "")
end

local function extractMediaPlayers(raw)
    if type(raw) ~= "string" or raw == "" then return {} end
    local list = {}
    local pos = 1
    local len = #raw
    while pos <= len do
        local s1, e1 = raw:find('"entity_id":"media_player.', pos, true)
        local s2, e2 = raw:find('"entity_id": "media_player.', pos, true)
        local s, e
        if s1 and s2 then
            if s1 < s2 then s, e = s1, e1 else s, e = s2, e2 end
        elseif s1 then
            s, e = s1, e1
        elseif s2 then
            s, e = s2, e2
        else
            break
        end

        local objStart = s
        while objStart > 1 and raw:byte(objStart) ~= 123 do
            objStart = objStart - 1
        end

        local depth = 0
        local inStr = false
        local esc = false
        local objEnd = nil
        for i = objStart, len do
            local b = raw:byte(i)
            if esc then
                esc = false
            elseif b == 92 then
                esc = true
            elseif b == 34 then
                inStr = not inStr
            elseif not inStr then
                if b == 123 then
                    depth = depth + 1
                elseif b == 125 then
                    depth = depth - 1
                    if depth == 0 then
                        objEnd = i
                        break
                    end
                end
            end
        end

        if objEnd then
            local chunk = raw:sub(objStart, objEnd)
            local ok, parsed = pcall(function()
                return noctalia.json.decode(chunk)
            end)
            if ok and type(parsed) == "table" and parsed.entity_id then
                table.insert(list, parsed)
            end
            pos = objEnd + 1
        else
            pos = e + 1
        end
    end
    return list
end

local function tr(key, subst)
    return noctalia.tr("panel." .. key, subst)
end

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
        fill = "surface_variant/0.5",
        align = "center",
        justify = "center",
    }, {
        ui.glyph({ name = fallbackGlyph or "music", size = math.floor(size * 0.5), color = "on_surface_variant" }),
    })
end

local function haPost(path, body, callback, onFailure)
    local url = getCleanUrl()
    local cleanToken = getCleanToken()
    if not url or url == "" or cleanToken == "" then
        noctalia.log("[panel_music] haPost aborted (missing url or token) for: " .. tostring(path))
        if onFailure then onFailure() end
        return
    end
    local encodedBody = noctalia.json.encode(body)
    noctalia.log("[panel_music] haPost " .. path .. " -> " .. encodedBody)

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
            noctalia.log("[panel_music] haPost " .. path .. " success (" .. tostring(httpStatus) .. ")")
            if callback then callback(response) end
            return
        end
        noctalia.log("[panel_music] HA rejected " .. path .. ": status " .. tostring(httpStatus))
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
        if onFailure then onFailure() end
    end)
end

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
            maConfigEntryId = "01K97GZFW2EECSC2YGRDQP81DN"
        end
        if callback then callback(maConfigEntryId) end
    end, function()
        maConfigEntryId = "01K97GZFW2EECSC2YGRDQP81DN"
        if callback then callback(maConfigEntryId) end
    end)
end

local function fetchFreshSpeakers(onDone)
    haGet("/api/states", function(resp)
        if not resp or not resp.body or resp.body == "" then
            if onDone then onDone() end
            return
        end
        local mediaPlayers = extractMediaPlayers(resp.body)
        local seenMediaPlayers = {}
        for _, s in ipairs(mediaPlayers) do
            local eid = type(s) == "table" and s.entity_id or nil
            if type(eid) == "string" and eid:match("^media_player%.") then
                local attrs = s.attributes or {}
                entityStates[eid] = {
                    entity_id = eid,
                    state = s.state,
                    friendly_name = attrs.friendly_name or eid,
                    domain = "media_player",
                    volume_level = attrs.volume_level,
                    is_volume_muted = attrs.is_volume_muted,
                    media_title = attrs.media_title,
                    media_artist = attrs.media_artist,
                    media_album_name = attrs.media_album_name,
                    entity_picture = attrs.entity_picture,
                    group_members = attrs.group_members or {},
                    app_id = attrs.app_id,
                    mass_player_type = attrs.mass_player_type,
                    supported_features = attrs.supported_features or 0,
                }
                seenMediaPlayers[eid] = true
            end
        end
        for eid in pairs(entityStates) do
            if eid:match("^media_player%.") and not seenMediaPlayers[eid] then
                entityStates[eid] = nil
            end
        end
        noctalia.state.set("entities", entityStates)
        render()
        if onDone then onDone() end
    end, function()
        if onDone then onDone() end
    end)
end

local function getSpeakerName(entity, eid)
    return (entity and entity.friendly_name) or eid
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

-- Currently Playing Banner
local function buildNowPlayingBanner()
    local targetEntity = entityStates[maSelectedSpeaker]
    if not targetEntity or not targetEntity.state or targetEntity.state == "off" or targetEntity.state == "unavailable" then
        return nil
    end

    local isPlaying = targetEntity.state == "playing"
    local isPaused = targetEntity.state == "paused"
    local hasMedia = (targetEntity.media_title and targetEntity.media_title ~= "")

    if not isPlaying and not isPaused and not hasMedia then
        return nil
    end

    local title = targetEntity.media_title or "Playback"
    local artist = targetEntity.media_artist or (targetEntity.friendly_name or maSelectedSpeaker)

    return ui.row({
        align = "center",
        gap = 10,
        padding = 8,
        radius = 8,
        fill = "primary/0.15",
    }, {
        renderCover(targetEntity.entity_picture, 40, "device-speaker", 6),
        ui.column({ flexGrow = 1, gap = 2 }, {
            ui.label({ text = title, fontWeight = "bold", maxLines = 1, color = "primary" }),
            ui.label({ text = artist, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
        }),
        ui.button({
            glyph = isPlaying and "player-pause" or "player-play",
            variant = "primary",
            onClick = function()
                haPost("/api/services/media_player/media_play_pause", { entity_id = maSelectedSpeaker })
            end,
        }),
        ui.button({
            glyph = "player-track-next",
            variant = "default",
            onClick = function()
                haPost("/api/services/media_player/media_next_track", { entity_id = maSelectedSpeaker })
            end,
        }),
    })
end

-- Speaker grouping
local function onToggleJoinSpeaker(masterEid, targetEid, isJoined)
    if isJoined then
        haPost("/api/services/media_player/unjoin", { entity_id = targetEid })
    else
        haPost("/api/services/media_player/join", { entity_id = masterEid, group_members = { targetEid } })
    end
end

-- Speaker Grouping & Linking Tab
local function buildSpeakersView()
    -- Collect all non-off/unavailable media_player entities
    local rawSpeakers = {}
    local hasMaSpeakers = false
    for eid, entity in pairs(entityStates) do
        if entity.domain == "media_player" then
            local st = entity.state
            if st and st ~= "off" and st ~= "unavailable" and st ~= "unknown" then
                table.insert(rawSpeakers, entity)
                if entity.mass_player_type and entity.mass_player_type ~= "" then
                    hasMaSpeakers = true
                end
            end
        end
    end

    -- Filter to only MA-managed speakers (mass_player_type set) to avoid duplicates.
    -- If no MA speakers found, fall back to showing all.
    local activeSpeakers = {}
    if hasMaSpeakers then
        for _, entity in ipairs(rawSpeakers) do
            if entity.mass_player_type and entity.mass_player_type ~= "" then
                table.insert(activeSpeakers, entity)
            end
        end
    else
        activeSpeakers = rawSpeakers
    end

    if #activeSpeakers == 0 then
        return ui.column({ align = "center", justify = "center", flexGrow = 1, gap = 12, padding = 32 }, {
            ui.glyph({ name = "device-speaker", size = 40, color = "on_surface_variant" }),
            ui.label({ text = "No active speakers found (all off or unavailable)", color = "on_surface_variant" }),
        })
    end

    -- Build a set of active entity_ids for quick lookup
    local activeEidSet = {}
    for _, entity in ipairs(activeSpeakers) do
        activeEidSet[entity.entity_id] = true
    end

    -- Group clustering
    local groupMap = {} -- leaderEid -> list of entity_ids
    local assigned = {}

    for _, entity in ipairs(activeSpeakers) do
        local members = entity.group_members or {}
        if #members > 1 and not assigned[entity.entity_id] then
            local validMembers = {}
            for _, mEid in ipairs(members) do
                local mEnt = entityStates[mEid]
                if mEnt and mEnt.state ~= "off" and mEnt.state ~= "unavailable" and activeEidSet[mEid] then
                    table.insert(validMembers, mEid)
                end
            end
            if #validMembers > 1 then
                groupMap[entity.entity_id] = validMembers
                for _, mEid in ipairs(validMembers) do
                    assigned[mEid] = entity.entity_id
                end
            end
        end
    end

    local standalone = {}
    for _, entity in ipairs(activeSpeakers) do
        if not assigned[entity.entity_id] then
            table.insert(standalone, entity.entity_id)
        end
    end



    -- Check if there's an active output selected (for conditional Link button)
    local hasActiveOutput = maSelectedSpeaker and maSelectedSpeaker ~= ""
        and entityStates[maSelectedSpeaker]
        and entityStates[maSelectedSpeaker].state ~= "off"
        and entityStates[maSelectedSpeaker].state ~= "unavailable"

    local function isPlaybackActive(entity)
        if not entity then return false end
        local st = entity.state
        if st == "playing" or st == "paused" then return true end
        if (st == "idle" or st == "on") and entity.media_title and entity.media_title ~= "" then
            return true
        end
        return false
    end

    local function findGroupMediaEntity(members)
        for _, mEid in ipairs(members) do
            local ent = entityStates[mEid]
            if ent and ent.state == "playing" and ent.media_title and ent.media_title ~= "" then
                return ent
            end
        end
        for _, mEid in ipairs(members) do
            local ent = entityStates[mEid]
            if ent and ent.state == "paused" and ent.media_title and ent.media_title ~= "" then
                return ent
            end
        end
        for _, mEid in ipairs(members) do
            local ent = entityStates[mEid]
            if ent and (ent.state == "playing" or ent.state == "paused") then
                return ent
            end
        end
        for _, mEid in ipairs(members) do
            local ent = entityStates[mEid]
            if ent and ent.media_title and ent.media_title ~= "" and ent.state ~= "off" and ent.state ~= "unavailable" then
                return ent
            end
        end
        return nil
    end

    -- Renders a compact speaker row: name + mute + volume slider + link/unlink
    -- Enforces fixed widths on text and action columns so sliders align consistently
    local function renderSpeakerVolumeRow(entity, isGrouped, groupLeaderEid)
        local eid = entity.entity_id
        local isCurrentMaster = (eid == maSelectedSpeaker)
        local isMuted = entity.is_volume_muted or false
        local rawVol = entity.volume_level
        local curVol = sliderDraft[eid] or (rawVol and math.floor(rawVol * 100 + 0.5) or 50)
        local displayName = getSpeakerName(entity, eid)

        local volSlider = ui.slider({
            key = "vol-slider-" .. eid,
            min = 0,
            max = 100,
            step = 1,
            value = curVol,
            onChange = function(v)
                local pct = math.floor((tonumber(v) or 50) + 0.5)
                sliderDraft[eid] = pct
                sliderDraftUntil[eid] = os.clock() + 3.0
                if entityStates[eid] then
                    entityStates[eid].volume_level = pct / 100.0
                end
                volumePending[eid] = { pct = pct, time = os.clock() }
                render()
            end,
            onDragEnd = function(v)
                local num = tonumber(v)
                local pct = (num and math.floor(num + 0.5)) or sliderDraft[eid] or 50
                sliderDraft[eid] = pct
                sliderDraftUntil[eid] = os.clock() + 3.0
                if entityStates[eid] then
                    entityStates[eid].volume_level = pct / 100.0
                end
                volumePending[eid] = nil
                haPost("/api/services/media_player/volume_set", { entity_id = eid, volume_level = pct / 100.0 })
                render()
            end,
            flexGrow = 1,
        })

        -- Link/Unlink button
        local actionBtn = nil
        if isGrouped then
            actionBtn = ui.button({
                glyph = "link-off",
                variant = "default",
                onClick = function()
                    onToggleJoinSpeaker(groupLeaderEid or maSelectedSpeaker, eid, true)
                end,
            })
        elseif eid ~= maSelectedSpeaker and hasActiveOutput then
            actionBtn = ui.button({
                glyph = "link",
                variant = "primary",
                onClick = function()
                    onToggleJoinSpeaker(maSelectedSpeaker, eid, false)
                end,
            })
        end

        return ui.row({
            key = "spk-" .. eid,
            align = "center",
            gap = 8,
            padding = { 4, 8, 4, 8 },
            radius = 6,
            fill = isCurrentMaster and "primary/0.10" or "surface_variant/0.15",
        }, {
            ui.column({ width = 115, justify = "center" }, {
                ui.label({ text = displayName, fontWeight = isCurrentMaster and "bold" or "medium", maxLines = 1 }),
            }),
            ui.button({
                glyph = isMuted and "volume-off" or "volume",
                variant = isMuted and "error" or "default",
                onClick = function()
                    haPost("/api/services/media_player/volume_mute", { entity_id = eid, is_volume_muted = not isMuted })
                end,
            }),
            volSlider,
            ui.column({ width = 36, align = "end", justify = "center" }, {
                ui.label({ text = curVol .. "%", fontSize = 11, color = "on_surface_variant" }),
            }),
            ui.column({ width = 34, align = "center", justify = "center" }, {
                actionBtn or ui.box({ width = 34 }),
            }),
        })
    end

    -- Renders a "now playing / paused" card with album art, title/artist on the left,
    -- controls on the top-right, and speaker volume rows underneath
    local function renderPlayingCard(mediaEntity, speakerEntities, isGrouped, leaderEid)
        local eid = mediaEntity.entity_id
        local isPlaying = mediaEntity.state == "playing"
        local isCurrentMaster = isGrouped and (maSelectedSpeaker == leaderEid or assigned[maSelectedSpeaker] == leaderEid) or (eid == maSelectedSpeaker)

        local cardItems = {}

        local title = mediaEntity.media_title or ""
        local artist = mediaEntity.media_artist or ""
        local coverUrl = mediaEntity.entity_picture

        local displayTitle = (title ~= "" and title) or getSpeakerName(mediaEntity, eid)
        local subText = artist
        if subText == "" and mediaEntity.media_album_name and mediaEntity.media_album_name ~= "" then
            subText = mediaEntity.media_album_name
        elseif subText ~= "" and mediaEntity.media_album_name and mediaEntity.media_album_name ~= "" then
            subText = subText .. " • " .. mediaEntity.media_album_name
        end
        if subText == "" then
            subText = isPlaying and "Playing" or "Paused"
        end

        local prevBtn = ui.button({
            glyph = "player-skip-back",
            variant = "default",
            onClick = function()
                haPost("/api/services/media_player/media_previous_track", { entity_id = eid })
            end,
        })
        local playBtn = ui.button({
            glyph = isPlaying and "player-pause" or "player-play",
            variant = isPlaying and "primary" or "default",
            onClick = function()
                haPost("/api/services/media_player/media_play_pause", { entity_id = eid })
            end,
        })
        local stopBtn = ui.button({
            glyph = "player-stop",
            variant = "default",
            onClick = function()
                haPost("/api/services/media_player/media_stop", { entity_id = eid })
            end,
        })
        local nextBtn = ui.button({
            glyph = "player-skip-forward",
            variant = "default",
            onClick = function()
                haPost("/api/services/media_player/media_next_track", { entity_id = eid })
            end,
        })
        local selectBtn = ui.button({
            glyph = isCurrentMaster and "check" or "circle",
            variant = isCurrentMaster and "primary" or "default",
            onClick = function()
                maSelectedSpeaker = isGrouped and (leaderEid or eid) or eid
                render()
            end,
        })

        local controlsRow = ui.row({ align = "center", gap = 4 }, {
            prevBtn, playBtn, nextBtn, selectBtn,
        })

        -- Top row: Cover | Title + Artist | Controls in top-right
        table.insert(cardItems, ui.row({ align = "center", gap = 10 }, {
            renderCover(coverUrl, 48, "music", 6),
            ui.column({ flexGrow = 1, gap = 2 }, {
                ui.label({ text = displayTitle, fontWeight = "bold", fontSize = 13, maxLines = 1, color = "on_surface" }),
                ui.label({ text = subText, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
            }),
            controlsRow,
        }))

        -- Speaker volume rows
        for _, spkEntity in ipairs(speakerEntities) do
            table.insert(cardItems, renderSpeakerVolumeRow(spkEntity, isGrouped, isGrouped and eid or nil))
        end

        return ui.column({
            key = "playing-" .. eid,
            gap = 8,
            padding = 10,
            radius = 10,
            fill = isCurrentMaster and "primary/0.10" or "primary/0.05",
            border = isCurrentMaster and "primary/0.4" or "primary/0.2",
            align = "stretch",
        }, cardItems)
    end

    -- Renders an idle (non-playing) speaker as a selectable row with select button on the right
    local function renderIdleSpeakerRow(entity)
        local eid = entity.entity_id
        local isCurrentMaster = (eid == maSelectedSpeaker)
        local displayName = getSpeakerName(entity, eid)

        local subtitle = ""
        if isCurrentMaster then
            subtitle = "Active Output"
        elseif entity.state and entity.state ~= "idle" and entity.state ~= "off" and entity.state ~= "unavailable" then
            subtitle = entity.state
        end

        local linkBtn = nil
        if eid ~= maSelectedSpeaker and hasActiveOutput then
            linkBtn = ui.button({
                glyph = "link",
                variant = "primary",
                onClick = function()
                    onToggleJoinSpeaker(maSelectedSpeaker, eid, false)
                end,
            })
        end

        local selectBtn = ui.button({
            glyph = isCurrentMaster and "check" or "circle",
            variant = isCurrentMaster and "primary" or "default",
            onClick = function()
                maSelectedSpeaker = eid
                render()
            end,
        })

        local rightItems = {}
        if linkBtn then
            table.insert(rightItems, linkBtn)
        end
        table.insert(rightItems, selectBtn)

        local infoChildren = {
            ui.label({ text = displayName, fontWeight = isCurrentMaster and "bold" or "medium", maxLines = 1 }),
        }
        if subtitle ~= "" then
            table.insert(infoChildren, ui.label({ text = subtitle, fontSize = 11, color = isCurrentMaster and "primary" or "on_surface_variant" }))
        end

        return ui.row({
            key = "spk-" .. eid,
            align = "center",
            gap = 8,
            padding = 10,
            radius = 8,
            fill = isCurrentMaster and "primary/0.12" or "surface_variant/0.25",
        }, {
            ui.column({ flexGrow = 1, gap = 2 }, infoChildren),
            ui.row({ align = "center", gap = 6 }, rightItems),
        })
    end

    local playingItems = {}
    local idleItems = {}

    -- Group clustering and sorting
    for leaderEid, members in pairs(groupMap) do
        local leaderEnt = entityStates[leaderEid]
        if leaderEnt then
            -- Collect ordered speaker entities
            local orderedMembers = { leaderEid }
            for _, mEid in ipairs(members) do
                if mEid ~= leaderEid then
                    table.insert(orderedMembers, mEid)
                end
            end

            local speakerEntities = {}
            for _, mEid in ipairs(orderedMembers) do
                local mEnt = entityStates[mEid]
                if mEnt then table.insert(speakerEntities, mEnt) end
            end

            local mediaEnt = findGroupMediaEntity(orderedMembers) or (isPlaybackActive(leaderEnt) and leaderEnt)

            if mediaEnt then
                table.insert(playingItems, renderPlayingCard(mediaEnt, speakerEntities, true, leaderEid))
            else
                local isGroupSelected = (maSelectedSpeaker == leaderEid or assigned[maSelectedSpeaker] == leaderEid)
                local selectBtn = ui.button({
                    glyph = isGroupSelected and "check" or "circle",
                    variant = isGroupSelected and "primary" or "default",
                    onClick = function()
                        maSelectedSpeaker = leaderEid
                        render()
                    end,
                })

                local groupRows = {}
                for _, spkEnt in ipairs(speakerEntities) do
                    table.insert(groupRows, renderSpeakerVolumeRow(spkEnt, true, leaderEid))
                end
                local leaderTitle = getSpeakerName(leaderEnt, leaderEid)
                table.insert(idleItems, ui.column({
                    key = "grp-" .. leaderEid,
                    gap = 6,
                    padding = 10,
                    radius = 10,
                    fill = isGroupSelected and "primary/0.08" or "surface_variant/0.15",
                    border = isGroupSelected and "primary/0.35" or "surface_variant/0.3",
                    align = "stretch",
                }, {
                    ui.row({ align = "center", gap = 6 }, {
                        ui.glyph({ name = "link", size = 16, color = "primary" }),
                        ui.label({ text = "Group: " .. leaderTitle, fontWeight = "bold", color = "primary", fontSize = 13, flexGrow = 1 }),
                        ui.label({ text = #members .. " speakers", fontSize = 11, color = "on_surface_variant" }),
                        selectBtn,
                    }),
                    ui.column({ gap = 4, align = "stretch" }, groupRows),
                }))
            end
        end
    end

    -- Standalone speakers
    for _, sEid in ipairs(standalone) do
        local sEnt = entityStates[sEid]
        if sEnt then
            if isPlaybackActive(sEnt) then
                table.insert(playingItems, renderPlayingCard(sEnt, { sEnt }, false, sEid))
            else
                table.insert(idleItems, renderIdleSpeakerRow(sEnt))
            end
        end
    end

    -- Playing speakers/groups appear first, followed by idle ones
    local listItems = {}
    for _, item in ipairs(playingItems) do
        table.insert(listItems, item)
    end
    for _, item in ipairs(idleItems) do
        table.insert(listItems, item)
    end

    return ui.scroll({ flexGrow = 1, gap = 8, align = "stretch" }, listItems)
end

render = function()
    local children = {}

    -- Header
    local header = ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = "music", size = 20, color = "primary" }),
        ui.label({ text = "Music Assistant", fontSize = 16, fontWeight = "bold", color = "primary", flexGrow = 1 }),
        ui.button({ glyph = "refresh", onClick = function()
            maLibLoaded = { albums = false, artists = false, tracks = false, radio = false, playlists = false }
            fetchMaLibrary(maLibSubTab, true)
            fetchFreshSpeakers()
            noctalia.state.set("command", "refresh")
            noctalia.state.set("panel_open_signal", os.clock())
            noctalia.notify(noctalia.tr("panel.music_assistant_title"), "Refreshing...")
        end }),
        ui.button({ glyph = "close", onClick = function() panel.close() end }),
    })
    table.insert(children, header)

    -- Top-level Navigation Tabs (Speakers on left, Library on right)
    local navBar = ui.row({ align = "center", gap = 6 }, {
        ui.button({
            glyph = "device-speaker",
            text = tr("tab_speakers"),
            variant = activeTab == "speakers" and "primary" or "default",
            onClick = function() activeTab = "speakers"; render() end,
            flexGrow = 1,
        }),
        ui.button({
            glyph = "music",
            text = tr("tab_library"),
            variant = activeTab == "music" and "primary" or "default",
            onClick = function() activeTab = "music"; render() end,
            flexGrow = 1,
        }),
    })
    table.insert(children, navBar)

    -- Speakers tab
    if activeTab == "speakers" then
        table.insert(children, buildSpeakersView())
        panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, children))
        return
    end

    -- Now playing card
    local nowPlaying = buildNowPlayingBanner()
    if nowPlaying then
        table.insert(children, nowPlaying)
    end

    local isSearching = noctalia.string.trim(maSearchQuery) ~= ""

    -- Search bar with clear button
    local searchRowChildren = {
        ui.input({
            key = "ma_search_input",
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

    -- SEARCH MODE
    if isSearching then
        if maSearching then
            table.insert(children, ui.column({ align = "center", justify = "center", flexGrow = 1, gap = 8 }, {
                ui.glyph({ name = "loader", size = 32, color = "primary" }),
                ui.label({ text = tr("ma_searching"), color = "on_surface_variant" }),
            }))
            panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children))
            return
        end

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
        panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children))
        return
    end

    -- LIBRARY MODE (Sub-tabs)
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

    if not maLibLoaded[maLibSubTab] and not maLibLoading[maLibSubTab] then
        fetchMaLibrary(maLibSubTab)
    end

    if maLibLoading[maLibSubTab] then
        table.insert(children, ui.column({ align = "center", justify = "center", flexGrow = 1, gap = 8, padding = 32 }, {
            ui.glyph({ name = "loader", size = 32, color = "primary" }),
            ui.label({ text = "Loading library...", color = "on_surface_variant" }),
        }))
        panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children))
        return
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
    panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children))
end

function onOpen(_context)
    status = noctalia.state.get("connection_status") or "unconfigured"
    entityStates = noctalia.state.get("entities") or {}
    sliderDraft = {}
    sliderDraftUntil = {}
    volumePending = {}

    ensureMaConfigEntry()

    -- Signal background service to reconnect and refresh
    noctalia.state.set("command", "refresh")
    noctalia.state.set("panel_open_signal", os.clock())

    -- Immediately fetch live states directly from Home Assistant
    fetchFreshSpeakers()

    -- Context-aware default tab: if any speaker is playing, paused, or has active media, open Speakers tab
    local anythingPlaying = false
    for eid, entity in pairs(entityStates) do
        if entity.domain == "media_player" then
            if entity.state == "playing" or entity.state == "paused" or (entity.media_title and entity.media_title ~= "" and entity.state ~= "off" and entity.state ~= "unavailable") then
                anythingPlaying = true
                break
            end
        end
    end
    activeTab = anythingPlaying and "speakers" or "music"

    panel.setWantsSecondTicks(true)
    render()
end

function onClose()
    panel.setWantsSecondTicks(false)
end

function update()
    if renderScheduled then
        renderScheduled = false
        render()
    end

    local now = os.clock()
    for eid, pending in pairs(volumePending) do
        if (now - pending.time) >= 0.35 then
            volumePending[eid] = nil
            haPost("/api/services/media_player/volume_set", { entity_id = eid, volume_level = pending.pct / 100.0 })
        end
    end

    local expired = false
    for eid, expiry in pairs(sliderDraftUntil) do
        if now >= expiry then
            sliderDraft[eid] = nil
            sliderDraftUntil[eid] = nil
            expired = true
        end
    end
    if expired then
        render()
    end
end

noctalia.state.watch("entities", function(value)
    entityStates = value or {}
    local now = os.clock()
    for eid, expiry in pairs(sliderDraftUntil) do
        if now >= expiry then
            sliderDraft[eid] = nil
            sliderDraftUntil[eid] = nil
        end
    end
    render()
end)

noctalia.state.watch("connection_status", function(value)
    status = value or "unconfigured"
    render()
end)

panel.setWantsSecondTicks(true)
