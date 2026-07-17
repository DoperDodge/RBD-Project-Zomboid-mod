--[[
    Return by Death - context menu entries
      * "Tell them about Return by Death..." on nearby players: breaks the
        taboo and kills the listener. In multiplayer the kill is requested
        from the server (sendClientCommand) and applied by the target's own
        client after server validation - never client-to-client.
      * "Set Safe Point": manually anchor the loop here (cooldown-gated).
      * "Reflect on your loops": flavor - loop counter + last remembered death.

    Runs on: client.
]]

require "ReturnByDeath_Core"

local RBD = ReturnByDeath

------------------------------------------------------------------------------
-- Target discovery: players standing on/next to the clicked squares
------------------------------------------------------------------------------

local function findNearbyPlayers(worldobjects, actor)
    local found, seen, squares = {}, {}, {}
    for _, obj in ipairs(worldobjects) do
        local sq = obj:getSquare()
        if sq then squares[sq] = true end
    end
    local cell = getCell()
    for sq, _ in pairs(squares) do
        for dx = -1, 1 do
            for dy = -1, 1 do
                local s2 = cell:getGridSquare(sq:getX() + dx, sq:getY() + dy, sq:getZ())
                if s2 then
                    local movers = s2:getMovingObjects()
                    if movers then
                        for i = 0, movers:size() - 1 do
                            local m = movers:get(i)
                            if m and instanceof(m, "IsoPlayer") and m ~= actor
                                    and not m:isDead() and not seen[m] then
                                seen[m] = true
                                table.insert(found, m)
                            end
                        end
                    end
                end
            end
        end
    end
    return found
end

------------------------------------------------------------------------------
-- Actions
------------------------------------------------------------------------------

local function onTellSelected(worldobjects, actor, target)
    if isClient() then
        -- multiplayer: server validates and orders the kill; the audio plays
        -- on this client when the server confirms (TellConfirmed)
        pcall(function()
            sendClientCommand(actor, RBD.NET_MODULE, "TellAndKill",
                { target = target:getOnlineID() })
        end)
    else
        -- single-player / split-screen: apply locally
        RBD.playReturnAudio(true)
        RBD.markWitchKill(target)
        pcall(function()
            target:setHaloNote(getText("UI_RBD_WitchKilled"), 130, 0, 160, 300)
        end)
        RBD.killLocalPlayer(target)
    end
end

--- Attach a tooltip if this build exposes the vanilla helper.
local function addTooltip(option, text)
    local ok = pcall(function()
        local tooltip = ISWorldObjectContextMenu.addToolTip()
        tooltip.description = text
        option.toolTip = tooltip
    end)
    return ok
end

local function onAcceptContract(worldobjects, player)
    local data = RBD.getData(player)
    if data.bearer then return end
    data.bearer = true
    RBD.log("Contract accepted: " .. tostring(player:getUsername()))
    pcall(function()
        player:setHaloNote(getText("UI_RBD_Accepted"), 170, 60, 255, 400)
    end)
    RBD.captureCheckpoint(player, true)
end

local function onSetSafePoint(worldobjects, player)
    local data = RBD.getData(player)
    local cooldown = RBD.getOption("ManualCheckpointCooldown")
    local sinceManual = (RBD.worldHours() - (data.lastManual or -1000)) * 60
    if cooldown > 0 and sinceManual < cooldown then return end
    if RBD.captureCheckpoint(player, true) then
        data.lastManual = RBD.worldHours()
    end
end

local function onReflect(worldobjects, player)
    local data = RBD.getData(player)
    local line
    if (data.loops or 0) <= 0 then
        line = getText("UI_RBD_ReflectNone")
    else
        line = getText("UI_RBD_ReflectLine", data.loops)
        local last = data.deathLog and data.deathLog[#data.deathLog]
        if last and last.cause then
            line = line .. " " .. getText("UI_RBD_DiedTo", last.cause)
        end
    end
    pcall(function() player:Say(line) end)
end

------------------------------------------------------------------------------
-- Menu wiring
------------------------------------------------------------------------------

local function onFillWorldObjectContextMenu(playerIndex, context, worldobjects, test)
    local player = getSpecificPlayer(playerIndex)
    if not player or player:isDead() then return end

    if not RBD.hasTrait(player) then
        -- On builds without the creation-screen trait (B42.19+), the only
        -- way in is accepting the contract here. Sandbox-gated.
        if RBD.getOption("AllowSelfGrant") then
            local acceptOption = context:addOption(getText("UI_RBD_ContextAccept"),
                worldobjects, onAcceptContract, player)
            addTooltip(acceptOption, getText("UI_RBD_ContextAcceptTooltip"))
        end
        return
    end

    -- manual safe point
    local data = RBD.getData(player)
    local cooldown = RBD.getOption("ManualCheckpointCooldown")
    local sinceManual = (RBD.worldHours() - (data.lastManual or -1000)) * 60
    local option = context:addOption(getText("UI_RBD_ContextSetSafePoint"),
        worldobjects, onSetSafePoint, player)
    if cooldown > 0 and sinceManual < cooldown then
        option.notAvailable = true
        addTooltip(option, getText("UI_RBD_ContextSetSafePointCooldown",
            math.ceil(cooldown - sinceManual)))
    else
        addTooltip(option, getText("UI_RBD_ContextSetSafePointTooltip"))
    end

    -- loop journal flavor
    context:addOption(getText("UI_RBD_ContextReflect"), worldobjects, onReflect, player)

    -- the taboo
    if RBD.getOption("EnableTellKill") then
        for _, target in ipairs(findNearbyPlayers(worldobjects, player)) do
            local name = "?"
            pcall(function() name = target:getUsername() or "?" end)
            local opt = context:addOption(
                getText("UI_RBD_ContextTell") .. " (" .. name .. ")",
                worldobjects, onTellSelected, player, target)
            addTooltip(opt, getText("UI_RBD_ContextTellTooltip", name))
        end
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
