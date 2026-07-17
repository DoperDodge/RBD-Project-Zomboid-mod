--[[
    Return by Death - trait registration
    Registers "Return by Death" as a negative trait worth +1 point in the
    character creation screen ON BUILDS THAT SUPPORT IT (Build 41 and early
    Build 42, which expose TraitFactory to Lua).

    Build 42.19+ removed TraitFactory: traits became engine-side
    CharacterTrait objects served by CharacterTraitDefinition, with no
    documented Lua registration hook. On those builds this file simply does
    nothing (no console errors), and players become bearers via the
    right-click "Accept the Witch's contract" option instead
    (ReturnByDeath_ContextMenu.lua) - same mechanics, stored in ModData.

    In TraitFactory.addTrait the cost is negative for negative traits: a
    cost of -1 lists the trait in the negative column and grants +1 point
    (same convention as vanilla Sunday Driver).

    Runs on: client + server (shared).
]]

require "ReturnByDeath_Core"

local function registerTrait()
    if not ReturnByDeath.traitSystemAvailable() then
        return -- B42.19+: no Lua trait registry; contract fallback handles it
    end
    local existing = nil
    pcall(function() existing = TraitFactory.getTrait(ReturnByDeath.TRAIT) end)
    if existing ~= nil then return end

    TraitFactory.addTrait(
        ReturnByDeath.TRAIT,
        getText("UI_trait_ReturnByDeath"),
        -1,
        getText("UI_trait_ReturnByDeathDesc"),
        false
    )
    TraitFactory.sortList()
    ReturnByDeath.log("Trait registered")
end

Events.OnGameBoot.Add(registerTrait)
if Events.OnMainMenuEnter then
    Events.OnMainMenuEnter.Add(registerTrait)
end
