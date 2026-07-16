--[[
    Return by Death - trait registration
    Registers "Return by Death" as a negative trait worth +1 point in the
    character creation screen.

    In TraitFactory.addTrait the cost is negative for negative traits: a cost
    of -1 lists the trait in the negative column and grants +1 point back
    (same convention as vanilla Sunday Driver).

    Registration is idempotent and hooked to both OnGameBoot and
    OnMainMenuEnter: Build 42 does not always re-fire boot events after the
    mod list changes, so the main-menu retry catches sessions where the mod
    was enabled without a full game restart.

    Runs on: client + server (shared).
]]

require "ReturnByDeath_Core"

local function registerTrait()
    local exists = false
    pcall(function()
        exists = TraitFactory.getTrait(ReturnByDeath.TRAIT) ~= nil
    end)
    if exists then return end

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
