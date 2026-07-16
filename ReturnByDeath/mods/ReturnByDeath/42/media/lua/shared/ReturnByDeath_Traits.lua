--[[
    Return by Death - trait registration
    Registers "Return by Death" as a negative trait worth +1 point in the
    character creation screen.

    In TraitFactory.addTrait the cost is negative for negative traits: a cost
    of -1 lists the trait in the negative column and grants +1 point back.

    Runs on: client + server (shared), once per game boot.
]]

require "ReturnByDeath_Core"

local function addReturnByDeathTrait()
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

Events.OnGameBoot.Add(addReturnByDeathTrait)
