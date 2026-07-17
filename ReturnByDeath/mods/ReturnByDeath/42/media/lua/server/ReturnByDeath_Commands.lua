--[[
    Return by Death - server-authoritative command handlers

    TellAndKill: a trait bearer broke the taboo. The server validates
    everything (feature enabled, sender really has the trait, target exists,
    is alive, is not the sender, and is in range) before instructing the
    TARGET's client to apply the death and the TELLER's client to play the
    confirmation audio. A crafted client command that fails any check is
    silently dropped - clients are never trusted to kill other clients.

    WitchScent: a returning player asks the server to emit the miasma pulse
    that attracts nearby zombies (world sounds are server-side in MP).

    Runs on: server (OnClientCommand only fires on a running server).
]]

require "ReturnByDeath_Core"

local RBD = ReturnByDeath

--- Server-side bearer check. On Build 41 the trait is server-visible and
--- authoritative. On B42.19+ there is no Lua trait registry and the
--- contract flag lives in the sender's client ModData, so the trait check
--- is skipped there - the sandbox toggle and range checks still gate the kill.
local function senderIsBearer(player)
    if RBD.traitSystemAvailable() then
        return RBD.hasTrait(player)
    end
    return true
end

local function handleTellAndKill(player, args)
    if not RBD.getOption("EnableTellKill") then return end
    if not senderIsBearer(player) then return end
    if not args or args.target == nil then return end

    local target = getPlayerByOnlineID(args.target)
    if not target or target:isDead() then return end
    if target == player then return end

    local range = RBD.getOption("TellKillRange")
    local dx = target:getX() - player:getX()
    local dy = target:getY() - player:getY()
    if (dx * dx + dy * dy) > (range * range) then return end
    if math.abs(target:getZ() - player:getZ()) > 1 then return end

    sendServerCommand(target, RBD.NET_MODULE, "WitchKill",
        { teller = player:getUsername() })
    sendServerCommand(player, RBD.NET_MODULE, "TellConfirmed",
        { target = target:getUsername() })
    RBD.log("Taboo broken: " .. tostring(player:getUsername())
        .. " told " .. tostring(target:getUsername()))
end

local function handleWitchScent(player)
    if not RBD.getOption("WitchScent") then return end
    if not senderIsBearer(player) then return end
    local radius = RBD.getOption("WitchScentRadius")
    pcall(function()
        getWorldSoundManager():addSound(nil,
            math.floor(player:getX()), math.floor(player:getY()),
            math.floor(player:getZ()), radius, 100)
    end)
end

local function onClientCommand(module, command, player, args)
    if module ~= RBD.NET_MODULE then return end
    if not player then return end

    if command == "TellAndKill" then
        handleTellAndKill(player, args)
    elseif command == "WitchScent" then
        handleWitchScent(player)
    end
end

Events.OnClientCommand.Add(RBD.wrap("clientCommand", onClientCommand))
