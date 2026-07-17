--[[
    Return by Death - death interception and the return itself

    Strategy (layered, because base-game death is hard to cancel cleanly):
      1. Primary guard: watch health every player update and on every damage
         event. When overall health falls to the DeathGuardThreshold, the
         return fires BEFORE the engine's death/corpse/death-screen pipeline
         ever starts - so there is no corpse and no game-over UI to suppress.
      2. Fallback: if an instant kill still slips through to OnPlayerDeath,
         attempt a post-mortem revive. If the engine accepts it, run the
         return, sweep any corpse that spawned at the death spot, and hide
         any death UI. If the engine refuses, the vanilla death proceeds
         untouched (never strand the player in a broken half-dead state).

    Runs on: client (each player resolves their own loop; nothing here
    touches other players' characters).
]]

require "ReturnByDeath_Core"

local RBD = ReturnByDeath

-- per-player-index state
local activeReturns = {}    -- index -> remaining protection ticks
local lastDamage = {}       -- index -> last damage-type string seen
local lastLimitNoteMs = 0

-- usernames whose next death is the Witch's taboo kill: absolute, no return
RBD.witchKillBypass = RBD.witchKillBypass or {}

-- deferred cleanup jobs handled in OnTick
local corpseSweeps = {}     -- { ticks, x, y, z }
local uiSuppressTicks = 0

------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------

function RBD.markWitchKill(player)
    local name = nil
    pcall(function() name = player:getUsername() end)
    RBD.witchKillBypass[name or "?"] = true
end

local function isWitchKilled(player)
    local name = nil
    pcall(function() name = player:getUsername() end)
    return RBD.witchKillBypass[name or "?"] == true
end

--- Kill the local player's own character (used for the taboo kill; player
--- health is client-authoritative in B41 multiplayer).
function RBD.killLocalPlayer(player)
    local ok = pcall(function() player:Kill(player) end)
    if not ok then
        pcall(function() player:getBodyDamage():setOverallBodyHealth(0) end)
        pcall(function() player:setHealth(0) end)
    end
end

--- Translate the last damage event / body state into a readable death cause.
local function causeText(player, damageType)
    local text = getText("UI_RBD_Cause_Unknown")
    pcall(function()
        local t = damageType and string.upper(tostring(damageType)) or ""
        local bd = player:getBodyDamage()
        if string.find(t, "WITCH") then
            text = getText("UI_RBD_Cause_Witch")
        elseif string.find(t, "BITE") or string.find(t, "SCRATCH") or string.find(t, "ZOMBIE") then
            text = getText("UI_RBD_Cause_Bite")
        elseif string.find(t, "FALL") then
            text = getText("UI_RBD_Cause_Fall")
        elseif string.find(t, "FIRE") or string.find(t, "BURN") then
            text = getText("UI_RBD_Cause_Fire")
        elseif string.find(t, "WEAPON") or string.find(t, "BULLET") or string.find(t, "STAB") then
            text = getText("UI_RBD_Cause_Weapon")
        elseif bd and bd:isInfected() then
            text = getText("UI_RBD_Cause_Infection")
        elseif bd and bd:getNumPartsBleeding() > 0 then
            text = getText("UI_RBD_Cause_Bleed")
        end
    end)
    return text
end

--- Heal the returning body. Full restore when the sandbox says so; otherwise
--- just pull the player back from the brink so the guard can't re-trigger
--- in an endless loop. The Knox infection is always cleared - leaving it
--- would chain-trigger returns until the daily limit burned out.
local function restoreBody(player)
    local bd = player:getBodyDamage()
    if RBD.getOption("RestoreHealth") then
        pcall(function() bd:RestoreToFullHealth() end)
    else
        local floor = math.min(100, RBD.getOption("DeathGuardThreshold") + 15)
        local ok = pcall(function()
            if bd:getOverallBodyHealth() < floor then
                bd:setOverallBodyHealth(floor)
            end
        end)
        if not ok then pcall(function() bd:RestoreToFullHealth() end) end
    end
    pcall(function() bd:setInfected(false) end)
    pcall(function() bd:setInfectionLevel(0) end)
    pcall(function() bd:setInfectionTime(-1) end)
    pcall(function() bd:setFakeInfectionLevel(0) end)
    pcall(function() player:setHealth(1.0) end)
    pcall(function() player:StopBurning() end)
    pcall(function() player:setOnFire(false) end)
end

local function applyPenalties(player, loops)
    local esc = 1 + math.max(0, loops - 1) * (RBD.getOption("PenaltyEscalation") / 100)
    pcall(function()
        local bd = player:getBodyDamage()
        local dep = RBD.getOption("DepressionPerLoop") * esc
        bd:setUnhappynessLevel(math.min(100, bd:getUnhappynessLevel() + dep))
    end)
    pcall(function()
        local stats = player:getStats()
        local stress = (RBD.getOption("StressPerLoop") / 100) * esc
        stats:setStress(math.min(1, stats:getStress() + stress))
    end)
    pcall(function()
        local stats = player:getStats()
        local panic = RBD.getOption("PanicPerLoop") * esc
        stats:setPanic(math.min(100, stats:getPanic() + panic))
    end)
end

--- Is a return currently possible (anchor exists, daily limit not spent)?
function RBD.canReturn(player)
    local data = RBD.getData(player)
    local hasAnchor = (data.anchors ~= nil and #data.anchors > 0)
        or data.checkpoint ~= nil
    if not hasAnchor then return false end
    local maxPerDay = RBD.getOption("MaxReturnsPerDay")
    if maxPerDay and maxPerDay > 0 then
        local day = math.floor(RBD.worldHours() / 24)
        if data.lastReturnDay == day and (data.returnsToday or 0) >= maxPerDay then
            return false
        end
    end
    return true
end

local function requestWitchScent(player, snapshot)
    if not RBD.getOption("WitchScent") then return end
    if isClient() then
        pcall(function()
            sendClientCommand(player, RBD.NET_MODULE, "WitchScent", {})
        end)
    else
        pcall(function()
            getWorldSoundManager():addSound(nil,
                math.floor(snapshot.x), math.floor(snapshot.y), math.floor(snapshot.z),
                RBD.getOption("WitchScentRadius"), 100)
        end)
    end
end

------------------------------------------------------------------------------
-- The return itself
------------------------------------------------------------------------------

function RBD.triggerReturn(player, damageType)
    local index = RBD.playerIndex(player)
    if activeReturns[index] then return true end
    if not RBD.canReturn(player) then return false end

    local data = RBD.getData(player)
    -- newest anchor whose surroundings are survivable; steps back through
    -- history if the latest one is overrun
    local snapshot = RBD.pickAnchor(player)
    if snapshot == nil then return false end

    -- daily-limit bookkeeping
    local day = math.floor(RBD.worldHours() / 24)
    if data.lastReturnDay ~= day then
        data.lastReturnDay = day
        data.returnsToday = 0
    end
    data.returnsToday = (data.returnsToday or 0) + 1
    data.loops = (data.loops or 0) + 1

    local cause = causeText(player, damageType)
    table.insert(data.deathLog, { loop = data.loops, hours = RBD.worldHours(), cause = cause })
    while #data.deathLog > 20 do table.remove(data.deathLog, 1) end

    RBD.log("Return by Death #" .. data.loops .. " (" .. cause .. ")")

    -- shield the player while the world snaps back
    pcall(function() player:setGodMod(true) end)
    activeReturns[index] = 240 -- ~4s of protection

    restoreBody(player)

    pcall(function()
        player:setX(snapshot.x); player:setY(snapshot.y); player:setZ(snapshot.z)
        player:setLx(snapshot.x); player:setLy(snapshot.y); player:setLz(snapshot.z)
    end)

    pcall(function() RBD.restoreInventory(player, snapshot) end)

    applyPenalties(player, data.loops)

    if RBD_ScreenFX then pcall(function() RBD_ScreenFX.play() end) end
    RBD.playReturnAudio(false)
    requestWitchScent(player, snapshot)

    pcall(function()
        player:setHaloNote(getText("UI_RBD_Returned", data.loops), 200, 40, 40, 400)
    end)
    if RBD.getOption("ShowDeathCause") then
        pcall(function() player:Say(getText("UI_RBD_DiedTo", cause)) end)
    end

    return true
end

------------------------------------------------------------------------------
-- Layer 1: pre-death guard
------------------------------------------------------------------------------

local function guardCheck(player, damageType)
    local index = RBD.playerIndex(player)
    if activeReturns[index] then return end
    if player:isDead() then return end
    if not RBD.hasTrait(player) then return end
    if isWitchKilled(player) then return end

    local health = 100
    pcall(function() health = player:getBodyDamage():getOverallBodyHealth() end)
    if health > RBD.getOption("DeathGuardThreshold") then return end

    if RBD.canReturn(player) then
        RBD.triggerReturn(player, damageType or lastDamage[index])
    else
        -- loop spent or no anchor: warn (throttled), then let death be death
        local now = RBD.nowMs()
        if now - lastLimitNoteMs > 10000 then
            lastLimitNoteMs = now
            local data = RBD.getData(player)
            local key = data.checkpoint and "UI_RBD_LimitReached" or "UI_RBD_NoCheckpoint"
            pcall(function() player:setHaloNote(getText(key), 200, 40, 40, 300) end)
        end
    end
end

local function onPlayerUpdate(player)
    if not RBD.isLocal(player) then return end
    local index = RBD.playerIndex(player)

    local ticks = activeReturns[index]
    if ticks then
        -- protection window: nothing gets to kill the player mid-return
        local health = 100
        pcall(function() health = player:getBodyDamage():getOverallBodyHealth() end)
        if health <= RBD.getOption("DeathGuardThreshold") then
            restoreBody(player)
        end
        if ticks <= 1 then
            activeReturns[index] = nil
            pcall(function() player:setGodMod(false) end)
        else
            activeReturns[index] = ticks - 1
        end
        return
    end

    guardCheck(player, nil)
end

local function onPlayerGetDamage(character, damageType, damage)
    if not instanceof(character, "IsoPlayer") then return end
    if not RBD.isLocal(character) then return end
    lastDamage[RBD.playerIndex(character)] = tostring(damageType)
    -- react immediately to big hits instead of waiting for the next update
    guardCheck(character, tostring(damageType))
end

------------------------------------------------------------------------------
-- Layer 2: post-mortem fallback
------------------------------------------------------------------------------

local function removeCorpsesAt(x, y, z)
    pcall(function()
        local cell = getCell()
        if not cell then return end
        for dx = -1, 1 do
            for dy = -1, 1 do
                local sq = cell:getGridSquare(x + dx, y + dy, z)
                if sq then
                    local bodies = sq:getDeadBodys()
                    if bodies then
                        for i = bodies:size() - 1, 0, -1 do
                            local body = bodies:get(i)
                            local removed = pcall(function() sq:removeCorpse(body, false) end)
                            if not removed then
                                pcall(function() body:removeFromWorld() end)
                                pcall(function() body:removeFromSquare() end)
                            end
                        end
                    end
                end
            end
        end
    end)
end

local function hideDeathUI()
    pcall(function()
        if ISPostDeathUI and ISPostDeathUI.instance then
            ISPostDeathUI.instance:setVisible(false)
            ISPostDeathUI.instance:removeFromUIManager()
            ISPostDeathUI.instance = nil
        end
    end)
end

local function onPlayerDeath(player)
    if not RBD.isLocal(player) then return end

    if isWitchKilled(player) then
        -- the taboo kill is absolute; consume the flag, vanilla death proceeds
        local name = nil
        pcall(function() name = player:getUsername() end)
        RBD.witchKillBypass[name or "?"] = nil
        return
    end

    if not RBD.hasTrait(player) then return end
    if not RBD.canReturn(player) then return end

    -- record where the body would fall before the return teleports us away
    local dx, dy, dz = 0, 0, 0
    pcall(function() dx, dy, dz = player:getX(), player:getY(), player:getZ() end)

    -- best effort revive; the engine has already flagged the character dead
    pcall(function()
        player:getBodyDamage():RestoreToFullHealth()
        player:setHealth(1.0)
    end)

    local alive = false
    pcall(function() alive = not player:isDead() end)
    if not alive then
        RBD.log("Post-mortem revive rejected by engine; vanilla death proceeds."
            .. " Consider a higher DeathGuardThreshold sandbox value.")
        return
    end

    RBD.log("Post-mortem revive accepted; running return")
    RBD.triggerReturn(player, lastDamage[RBD.playerIndex(player)])
    table.insert(corpseSweeps, { ticks = 30, x = math.floor(dx), y = math.floor(dy), z = math.floor(dz) })
    uiSuppressTicks = 300 -- keep swatting the death UI for ~5s
end

local function onTickCleanup()
    if uiSuppressTicks > 0 then
        uiSuppressTicks = uiSuppressTicks - 1
        hideDeathUI()
    end
    if #corpseSweeps > 0 then
        for i = #corpseSweeps, 1, -1 do
            local job = corpseSweeps[i]
            job.ticks = job.ticks - 1
            if job.ticks <= 0 then
                removeCorpsesAt(job.x, job.y, job.z)
                table.remove(corpseSweeps, i)
            end
        end
    end
end

Events.OnPlayerUpdate.Add(RBD.wrap("playerUpdateGuard", onPlayerUpdate))
-- OnPlayerGetDamage is the one event here without a decade of API stability;
-- the update-loop guard fully covers its job if a build lacks it
if Events.OnPlayerGetDamage then
    Events.OnPlayerGetDamage.Add(RBD.wrap("damageGuard", onPlayerGetDamage))
end
Events.OnPlayerDeath.Add(RBD.wrap("deathFallback", onPlayerDeath))
Events.OnTick.Add(RBD.wrap("cleanupTicker", onTickCleanup))
