--[[
    Return by Death - anchor (safe point) system

    Anime-accurate anchoring:
      * Every AnchorIntervalReal REAL-WORLD minutes (default 5), if the
        player is calm - no zombie is aggroed on them and none is standing
        on top of them - the loop silently records an anchor: position +
        full loadout. If they're not calm, it retries every 15 seconds
        until they are.
      * Anchors accumulate in a history (default 10). On death the return
        goes to the NEWEST anchor whose surroundings are currently safe
        (at most MaxZombiesAtAnchor zombies within AnchorSafetyRadius
        tiles); unsafe anchors are stepped back oldest-ward, and if none
        pass, the least-infested one is used - so the loop never sends you
        further back than it must.
      * A first anchor is taken a few seconds after a bearer appears, so
        no bearer is ever without one.

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

    -- unique save-wide id: lets the return erase this exact item from the
    -- world if it was dropped after the anchor (anti-dupe)
    pcall(function() data.id = item:getID() end)

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

--- Create an item by full type, trying every known API generation so a
--- rename in one build can't break the whole restore.
local function createItemIn(container, fullType)
    local item = nil
    pcall(function() item = container:AddItem(fullType) end)
    if item then return item end
    pcall(function()
        local made = InventoryItemFactory.CreateItem(fullType)
        if made then
            pcall(function() container:AddItem(made) end)
            item = made
        end
    end)
    if item then return item end
    pcall(function()
        local made = instanceItem(fullType)
        if made then
            pcall(function() container:AddItem(made) end)
            item = made
        end
    end)
    return item
end

local function deserializeItem(container, data)
    if not data or not data.type then return nil end
    local item = createItemIn(container, data.type)
    if not item then
        RBD.reportError("restore.create", "could not recreate " .. tostring(data.type))
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
--- Every step is isolated and failure-logged: one broken item or one
--- renamed API must never abort the rest of the loadout (a half-restore
--- is exactly the "wrong clothes, missing items" bug).
function RBD.restoreInventory(player, snapshot)
    if not snapshot or not snapshot.items then return end

    RBD.try("restore.unequipHands", function()
        player:setPrimaryHandItem(nil)
        player:setSecondaryHandItem(nil)
    end)

    -- strip worn clothing first so removal from the container is clean
    local wornMap = buildWornMap(player)
    for item, _ in pairs(wornMap) do
        RBD.try("restore.stripWorn", function() player:removeWornItem(item) end)
    end

    RBD.try("restore.clear", function()
        local inv = player:getInventory()
        local list = inv:getItems()
        for i = list:size() - 1, 0, -1 do
            inv:Remove(list:get(i))
        end
    end)

    local inv = player:getInventory()
    local restored, failed = 0, 0
    for _, data in ipairs(snapshot.items) do
        local ok = RBD.try("restore.item", function()
            local item = deserializeItem(inv, data)
            if item then
                if data.worn then
                    RBD.try("restore.wear", function() player:setWornItem(data.worn, item) end)
                end
                if data.primary then pcall(function() player:setPrimaryHandItem(item) end) end
                if data.secondary then pcall(function() player:setSecondaryHandItem(item) end) end
                restored = restored + 1
            else
                failed = failed + 1
            end
        end)
        if not ok then failed = failed + 1 end
    end
    RBD.log("Loadout restored: " .. restored .. " item(s)"
        .. (failed > 0 and (", " .. failed .. " FAILED (see errors above)") or ""))
end

------------------------------------------------------------------------------
-- Anti-dupe: erase snapshot items left lying in the old timeline
------------------------------------------------------------------------------

local function collectItemIds(items, into)
    for _, data in ipairs(items or {}) do
        if data.id ~= nil then into[data.id] = true end
        if data.items then collectItemIds(data.items, into) end
    end
end

--- Remove ground items matching the snapshot's item ids near the given
--- spots (death position + anchor position). If you anchored holding a cup
--- and dropped it before dying, the dropped cup vanishes when the loop
--- gives you the anchored one back. Only loaded squares can be swept -
--- items dropped far away in unloaded areas are out of reach.
function RBD.sweepSnapshotItems(snapshot, spots)
    if not snapshot or not snapshot.items then return end
    local ids = {}
    collectItemIds(snapshot.items, ids)
    if next(ids) == nil then return end

    local removed = 0
    RBD.try("worldSweep", function()
        local cell = getCell()
        if not cell then return end
        local seen = {}
        for _, spot in ipairs(spots) do
            local px = math.floor(spot.x or 0)
            local py = math.floor(spot.y or 0)
            local pz = math.floor(spot.z or 0)
            for dx = -25, 25 do
                for dy = -25, 25 do
                    local sq = cell:getGridSquare(px + dx, py + dy, pz)
                    if sq and not seen[sq] then
                        seen[sq] = true
                        local objs = sq:getWorldObjects()
                        if objs then
                            for i = objs:size() - 1, 0, -1 do
                                local wobj = objs:get(i)
                                local id = nil
                                pcall(function() id = wobj:getItem():getID() end)
                                if id ~= nil and ids[id] then
                                    local okRemove = pcall(function()
                                        sq:transmitRemoveItemFromSquare(wobj)
                                    end)
                                    if not okRemove then
                                        pcall(function() wobj:removeFromSquare() end)
                                    end
                                    removed = removed + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
    if removed > 0 then
        RBD.log("The loop reclaimed " .. removed .. " item(s) left in the old timeline")
    end
end

------------------------------------------------------------------------------
-- Zombie proximity / aggro checks
------------------------------------------------------------------------------

--- Count zombies within `radius` tiles of (x, y). When `player` is given,
--- also count how many of them are actively targeting that player.
--- Only loaded zombies are visible; an unloaded area counts as clear.
local function zombiesNear(x, y, radius, player)
    local near, aggro = 0, 0
    pcall(function()
        local cell = getCell()
        if not cell then return end
        local zombies = cell:getZombieList()
        local r2 = radius * radius
        for i = 0, zombies:size() - 1 do
            local z = zombies:get(i)
            if z and not z:isDead() then
                local dx, dy = z:getX() - x, z:getY() - y
                if dx * dx + dy * dy <= r2 then
                    near = near + 1
                end
                if player ~= nil then
                    local ok, target = pcall(function() return z:getTarget() end)
                    if ok and target == player then
                        aggro = aggro + 1
                    end
                end
            end
        end
    end)
    return near, aggro
end

--- "Calm" = the anime rule for when the loop may re-anchor: nothing is
--- hunting the player and nothing is right on top of them.
function RBD.isCalm(player)
    local near, aggro = zombiesNear(player:getX(), player:getY(), 8, player)
    return aggro == 0 and near == 0
end

------------------------------------------------------------------------------
-- Anchor capture & selection
------------------------------------------------------------------------------

--- Record the player's current position + loadout as the newest anchor.
function RBD.captureCheckpoint(player, announce)
    if not RBD.hasTrait(player) then return false end
    local ok, err = pcall(function()
        local data = RBD.getData(player)
        local snapshot = {
            x = player:getX(),
            y = player:getY(),
            z = player:getZ(),
            hours = RBD.worldHours(),
            items = serializeLoadout(player),
        }
        data.anchors = data.anchors or {}
        table.insert(data.anchors, snapshot)
        local cap = RBD.getOption("AnchorHistory")
        while #data.anchors > cap do table.remove(data.anchors, 1) end
        data.checkpoint = snapshot -- newest anchor (and pre-anchor-history compat)
    end)
    if not ok then
        RBD.reportError("captureCheckpoint", err)
        return false
    end
    if announce then
        pcall(function()
            player:setHaloNote(getText("UI_RBD_SafePointSet"), 170, 60, 255, 300)
        end)
    end
    return true
end

--- Choose where the loop returns: the newest currently-safe anchor, walking
--- back through history; if every anchor is overrun, the least-infested one.
function RBD.pickAnchor(player)
    local data = RBD.getData(player)
    local anchors = data.anchors
    if anchors == nil or #anchors == 0 then
        return data.checkpoint -- saves from before anchor history existed
    end
    local maxZombies = RBD.getOption("MaxZombiesAtAnchor")
    local radius = RBD.getOption("AnchorSafetyRadius")
    local best, bestCount = nil, nil
    for i = #anchors, 1, -1 do
        local anchor = anchors[i]
        local near = zombiesNear(anchor.x, anchor.y, radius, nil)
        if near <= maxZombies then
            return anchor
        end
        if bestCount == nil or near < bestCount then
            best, bestCount = anchor, near
        end
    end
    return best or anchors[#anchors]
end

------------------------------------------------------------------------------
-- Real-time anchor ticker
------------------------------------------------------------------------------

local anchorState = {}   -- player index -> { nextMs }
local tickSkip = 0
local RETRY_MS = 15000   -- not calm: look again in 15 seconds
local FIRST_MS = 5000    -- anchorless bearer: first anchor ~5s in

local function onTickAnchors()
    -- evaluate roughly twice a second, not every frame
    tickSkip = tickSkip + 1
    if tickSkip < 30 then return end
    tickSkip = 0

    local now = RBD.nowMs()
    for i = 0, 3 do
        local player = getSpecificPlayer(i)
        if player and not player:isDead() and RBD.isLocal(player)
                and RBD.hasTrait(player) then
            local state = anchorState[i]
            if state == nil then
                local data = RBD.getData(player)
                local anchorless = (data.anchors == nil or #data.anchors == 0)
                state = { nextMs = now + (anchorless and FIRST_MS
                    or RBD.getOption("AnchorIntervalReal") * 60000) }
                anchorState[i] = state
            end
            if now >= state.nextMs then
                local data = RBD.getData(player)
                local anchorless = (data.anchors == nil or #data.anchors == 0)
                local calm = not RBD.getOption("SafeCheckpointsOnly") or RBD.isCalm(player)
                if (calm or anchorless) and RBD.captureCheckpoint(player, false) then
                    state.nextMs = now + RBD.getOption("AnchorIntervalReal") * 60000
                else
                    state.nextMs = now + RETRY_MS
                end
            end
        else
            anchorState[i] = nil
        end
    end
end

Events.OnTick.Add(RBD.wrap("anchorTicker", onTickAnchors))
