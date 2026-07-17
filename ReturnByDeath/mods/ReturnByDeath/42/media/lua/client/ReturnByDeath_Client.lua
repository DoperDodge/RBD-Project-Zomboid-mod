--[[
    Return by Death - client-side network handler
    Receives server instructions:
      * WitchKill      - this client's character broke the taboo chain (they
                         were told about Return by Death): play the audio,
                         flag the death as absolute, and die.
      * TellConfirmed  - the server accepted this client's TellAndKill
                         request: play the audio on the teller's side.

    Runs on: client (multiplayer only; OnServerCommand never fires in SP).
]]

require "ReturnByDeath_Core"

local RBD = ReturnByDeath

local function onServerCommand(module, command, args)
    if module ~= RBD.NET_MODULE then return end
    local player = getPlayer()
    if not player then return end

    if command == "WitchKill" then
        RBD.playReturnAudio(true)
        RBD.markWitchKill(player)
        pcall(function()
            player:setHaloNote(getText("UI_RBD_WitchKilled"), 130, 0, 160, 300)
        end)
        RBD.killLocalPlayer(player)
    elseif command == "TellConfirmed" then
        RBD.playReturnAudio(true)
        pcall(function()
            local name = (args and args.target) or "?"
            player:setHaloNote(getText("UI_RBD_TellConfirmed", name), 130, 0, 160, 300)
        end)
    end
end

Events.OnServerCommand.Add(RBD.wrap("serverCommand", onServerCommand))
