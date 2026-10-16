--!nonstrict

local haUrl = noctalia.getConfig("ha_url")
local haToken = noctalia.getConfig("ha_token")
local SLOT_LABEL = noctalia.tr("shortcut.label_4")

local entityStates = {}
local pendingToggle = {}
local pendingSince = {}
local pendingTimerToken = {}
local pendingTimerSeq = 0
local patchSeq = 0

local PENDING_TIMEOUT_SECONDS = 8
local PENDING_TIMEOUT_MS = 8000
local render

local function nowMs()
    if type(noctalia.nowMs) == "function" then
        local ms = noctalia.nowMs()
        if type(ms) == "number" and ms > 0 then
            return ms
        end
    end
    return os.time() * 1000
end

local function sendEntityPatch(eid, fields, states)
    patchSeq = patchSeq + 1
    noctalia.state.set("entity_patch", {
        seq = nowMs() * 1000 + patchSeq,
        eid = eid,
        fields = fields,
        states = states,
    })
end

local function getConfiguredEntityId()
    local eid = noctalia.getConfig("shortcut_entity_4")
    if type(eid) ~= "string" then return "" end
    return (eid:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function getCleanUrl()
    local u = noctalia.getConfig("ha_url")
    if type(u) ~= "string" or u == "" then u = haUrl end
    if type(u) ~= "string" then return "" end
    return (u:gsub("/+$", ""))
end

local function getCleanToken()
    local t = noctalia.getConfig("ha_token")
    if type(t) ~= "string" or t == "" then t = haToken end
    if type(t) ~= "string" then return "" end
    return t:gsub("^%s+", ""):gsub("%s+$", "")
end

local function stateGlyph(domain, isOn)
    if domain == "light" then return isOn and "bulb" or "bulb-off"
    elseif domain == "switch" or domain == "input_boolean" then return isOn and "toggle-right" or "toggle-left"
    elseif domain == "fan" then return isOn and "wind" or "wind-off"
    elseif domain == "lock" then return isOn and "lock" or "lock-open"
    elseif domain == "cover" then return isOn and "door-open" or "door"
    end
    return "smart-home"
end

local function getEntity()
    local configuredEntityId = getConfiguredEntityId()
    if configuredEntityId == "" then return nil end
    return entityStates[configuredEntityId]
end

local function clearPending(entityId)
    pendingToggle[entityId] = nil
    pendingSince[entityId] = nil
    pendingTimerToken[entityId] = nil
end

local function isPendingTimedOut(entityId, now)
    local startedAt = pendingSince[entityId]
    if not startedAt then return false end
    return (now or nowMs()) - startedAt >= PENDING_TIMEOUT_MS
end

local function reconcilePending(now)
    for entityId, expected in pairs(pendingToggle) do
        local real = entityStates[entityId]
        if not real or real.state == expected or isPendingTimedOut(entityId, now) then
            clearPending(entityId)
        end
    end
end

local function schedulePendingTimeout(entityId)
    pendingTimerSeq = pendingTimerSeq + 1
    local token = pendingTimerSeq
    pendingSince[entityId] = nowMs()
    pendingTimerToken[entityId] = token

    noctalia.runAsync("sleep " .. tostring(PENDING_TIMEOUT_SECONDS), function(_result)
        if pendingTimerToken[entityId] ~= token then return end
        if pendingToggle[entityId] and isPendingTimedOut(entityId) then
            clearPending(entityId)
            render()
        end
    end)
end

render = function()
    reconcilePending(nowMs())

    local configuredEntityId = getConfiguredEntityId()
    local entity = getEntity()

    if not entity then
        shortcut.setLabel(configuredEntityId ~= "" and configuredEntityId or SLOT_LABEL)
        shortcut.setIcon("smart-home")
        shortcut.setActive(false)
        shortcut.setEnabled(false)
        return
    end

    local eid = entity.entity_id
    local pending = pendingToggle[eid]

    if pending then
        shortcut.setLabel(entity.friendly_name or eid)
        shortcut.setIcon("loader")
        shortcut.setActive(pending == "on")
        shortcut.setEnabled(false)
        return
    end

    local isOn = entity.state == "on"
    shortcut.setLabel(entity.friendly_name or eid)
    shortcut.setIcon(stateGlyph(entity.domain, true), stateGlyph(entity.domain, false))
    shortcut.setActive(isOn)
    shortcut.setEnabled(true)
end

noctalia.state.watch("entities", function(value)
    entityStates = value or {}
    reconcilePending(nowMs())
    render()
end)

noctalia.state.watch("connection_status", function(_value)
    render()
end)

function onClick()
    reconcilePending(nowMs())

    local entity = getEntity()
    local cleanToken = getCleanToken()
    if not entity or getCleanUrl() == "" or cleanToken == "" then return end

    local eid = entity.entity_id
    if pendingToggle[eid] then return end

    local newState = entity.state == "on" and "off" or "on"
    pendingToggle[eid] = newState
    schedulePendingTimeout(eid)

    local encoded = noctalia.json.encode({ entity_id = eid })

    noctalia.http({
        url = getCleanUrl() .. "/api/services/" .. entity.domain .. "/toggle",
        method = "POST",
        headers = {
            "Authorization: Bearer " .. cleanToken,
            "Content-Type: application/json",
        },
        body = encoded,
        allow_insecure_tls = true,
    }, function(response)
        local httpStatus = response and response.status or 0
        if httpStatus >= 200 and httpStatus < 300 then
            clearPending(eid)
            if entityStates[eid] then
                entityStates[eid].state = newState
            end
            if response and response.body and #response.body > 2 then
                local ok, decoded = pcall(function() return noctalia.json.decode(response.body) end)
                if ok and type(decoded) == "table" and #decoded > 0 then
                    sendEntityPatch(eid, { state = newState }, decoded)
                    render()
                    return
                end
            end
            sendEntityPatch(eid, { state = newState })
            render()
            return
        end
        noctalia.log("Home Assistant rejected toggle for " .. eid .. ": status " .. tostring(httpStatus))
        clearPending(eid)
        render()
    end)

    render()
end

entityStates = noctalia.state.get("entities") or {}
render()
