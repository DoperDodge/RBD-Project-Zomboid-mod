--[[
    Return by Death - safe point (checkpoint) capture & restore
    Silently snapshots the player's position and full inventory (main
    inventory, equipped hands, worn clothing, nested container contents)
    into their ModData on an interval, plus an initial anchor on spawn.

    Runs on: client (each player anchors their own loop).
]]

require "ReturnByDeath_Core"

local RBD = ReturnByDeath

------------------------------------------------------------------------------
-- Inventory serialization
------------------------------------------------------------------------------

-- ModData only persists plain Lua values, so items are stored as
-- { type, condition, usedDelta, ammo, items = {...} } tables.
local function serializeItem(item)
    local data = { type = item:getFullType() }

    pcall(function() data.condition = item:getCondition() end)

    if item.IsDrainable and item:IsDrainable() then
        pcall(function() data.usedDelta = item:getUsedDelta() end)
    end

    -- keep loaded firearms loaded across the loop where the API allows
    pcall(function()
        if item.getCurrentAmmoCount and item:getCurrentAmmoCount() > 0 then
            data.ammo = item:getCurrentAmmoCount()
        end
    end)

    if instanceof(item, "InventoryContainer") then
        data.items = {}
        local inner = item:getInventory()
        if inner then
            local list = inner:getItems()
            for i = 0, list:size() - 1 do
                table.insert(data.items, serializeItem(list:get(i)))
            end
        end
    end

    return data
end

-- Map of currently worn item -> body location. WornItems iteration has had
-- two shapes across builds, so try both.
local function buildWornMap(player)
    local map = {}
    local ok = pcall(function()
        local wi = player:getWornItems()
        for i = 0, wi:size() - 1 do
            local w = wi:get(i)
            map[w:getItem()] = w:getLocation()
        end
    end)
    if not ok then
        pcall(function()
            local wi = player:getWornItems()
            for i = 0, wi:size() - 1 do
                local it = wi:getItemByIndex(i)
                if it and it.getBodyLocation then
                    map[it] = it:getBodyLocation()
                end
            end
        end)
    end
    return map
end

local function serializeLoadout(player)
    local out = {}
    local worn = buildWornMap(player)
    local primary = player:getPrimaryHandItem()
    local secondary = player:getSecondaryHandItem()

    local list = player:getInventory():getItems()
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        local data = serializeItem(item)
        if worn[item] then data.worn = worn[item] end
        if item == primary then data.primary = true end
        if item == secondary then data.secondary = true end
        table.insert(out, data)
    end
    return out
end

local function deserializeItem(container, data)
    if not data or not data.type then return nil end
    local item = container:AddItem(data.type)
    if not item then
        RBD.log("Unknown item type in checkpoint: " .. tostring(data.type))
        return nil
    end
    if data.condition ~= nil then pcall(function() item:setCondition(data.condition) end) end
    if data.usedDelta ~= nil then pcall(function() item:setUsedDelta(data.usedDelta) end) end
    if data.ammo ~= nil then pcall(function() item:setCurrentAmmoCount(data.ammo) end) end
    if data.items and instanceof(item, "InventoryContainer") then
        local inner = item:getInventory()
        if inner then
            for _, sub in ipairs(data.items) do
                deserializeItem(inner, sub)
            end
        end
    end
    return item
end

--- Wipe the player's current loadout and rebuild it from the snapshot.
function RBD.restoreInventory(player, snapshot)
    if not snapshot or not snapshot.items then return end

    pcall(function() player:setPrimaryHandItem(nil) end)
    pcall(function() player:setSecondaryHandItem(nil) end)

    -- strip worn clothing first so removal from the container is clean
    local wornMap = buildWornMap(player)
    for item, _ in pairs(wornMap) do
        pcall(function() player:removeWornItem(item) end)
    end

    local inv = player:getInventory()
    local list = inv:getItems()
    for i = list:size() - 1, 0, -1 do
        inv:Remove(list:get(i))
    end

    for _, data in ipairs(snapshot.items) do
        local item = deserializeItem(inv, data)
        if item then
            if data.worn then pcall(function() player:setWornItem(data.worn, item) end) end
            if data.primary then pcall(function() player:setPrimaryHandItem(item) end) end
            if data.secondary then pcall(function() player:setSecondaryHandItem(item) end) end
        end
    end
end

------------------------------------------------------------------------------
-- Checkpoint capture
------------------------------------------------------------------------------

--- A spot is "safe" enough to auto-anchor when the player isn't badly hurt
--- and no zombie is within 15 tiles.
function RBD.isSafeToAnchor(player)
    local healthy = true
    pcall(function()
        healthy = player:getBodyDamage():getOverallBodyHealth() >= 50
    end)
    if not healthy then return false end

    local safe = true
    pcall(function()
        local zombies = player:getCell():getZombieList()
        local px, py = player:getX(), player:getY()
        for i = 0, zombies:size() - 1 do
            local z = zombies:get(i)
            if z and not z:isDead() then
                local dx, dy = z:getX() - px, z:getY() - py
                if dx * dx + dy * dy < 225 then -- 15 tiles
                    safe = false
                    break
                end
            end
        end
    end)
    return safe
end

--- Record the player's current position + loadout as the loop's safe point.
function RBD.captureCheckpoint(player, announce)
    if not RBD.hasTrait(player) then return false end
    local ok, err = pcall(function()
        local data = RBD.getData(player)
        data.checkpoint = {
            x = player:getX(),
            y = player:getY(),
            z = player:getZ(),
            hours = RBD.worldHours(),
            items = serializeLoadout(player),
        }
    end)
    if not ok then
        RBD.log("Checkpoint capture failed: " .. tostring(err))
        return false
    end
    if announce then
        pcall(function()
            player:setHaloNote(getText("UI_RBD_SafePointSet"), 170, 60, 255, 300)
        end)
    end
    return true
end

------------------------------------------------------------------------------
-- Automatic interval + initial anchor
------------------------------------------------------------------------------

local minuteCounters = {}
local pendingInitial = {}

local function onEveryOneMinute()
    for i = 0, 3 do
        local player = getSpecificPlayer(i)
        if player and player:isLocalPlayer() and not player:isDead()
                and RBD.hasTrait(player) then
            local data = RBD.getData(player)
            minuteCounters[i] = (minuteCounters[i] or 0) + 1
            if data.checkpoint == nil then
                -- never leave a trait bearer without an anchor
                if RBD.captureCheckpoint(player, false) then minuteCounters[i] = 0 end
            elseif minuteCounters[i] >= RBD.getOption("CheckpointInterval") then
                if not RBD.getOption("SafeCheckpointsOnly") or RBD.isSafeToAnchor(player) then
                    RBD.captureCheckpoint(player, false)
                    minuteCounters[i] = 0
                end
                -- if unsafe, retry every minute until the area clears
            end
        end
    end
end

local function onCreatePlayer(index, player)
    if not player then return end
    -- defer the first anchor a few seconds so the spawn loadout is settled
    pendingInitial[index] = 300
end

local function onTickInitial()
    for index, ticks in pairs(pendingInitial) do
        if ticks <= 1 then
            pendingInitial[index] = nil
            local player = getSpecificPlayer(index)
            if player and not player:isDead() and RBD.hasTrait(player) then
                local data = RBD.getData(player)
                if data.checkpoint == nil then
                    RBD.captureCheckpoint(player, false)
                    RBD.log("Initial safe point anchored for player " .. tostring(index))
                end
            end
        else
            pendingInitial[index] = ticks - 1
        end
    end
end

Events.EveryOneMinute.Add(onEveryOneMinute)
Events.OnCreatePlayer.Add(onCreatePlayer)
Events.OnTick.Add(onTickInitial)
