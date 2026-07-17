--[[
    Return by Death - shared core
    Constants, sandbox-option accessors and small helpers used by both the
    client and server sides of the mod.

    Runs on: client + server (shared)
]]

ReturnByDeath = ReturnByDeath or {}

ReturnByDeath.MOD_ID = "ReturnByDeath"
ReturnByDeath.TRAIT = "ReturnByDeath"
ReturnByDeath.SOUND = "ReturnByDeathTrigger"
-- module name used for sendClientCommand / sendServerCommand round-trips
ReturnByDeath.NET_MODULE = "ReturnByDeath"

-- Defaults mirror media/sandbox-options.txt; used when SandboxVars are missing
-- (e.g. a save created before the mod was added).
ReturnByDeath.Defaults = {
    CheckpointInterval       = 10,   -- in-game minutes between automatic safe-point updates
    SafeCheckpointsOnly      = true, -- skip auto checkpoints with zombies nearby / while dying
    ManualCheckpointCooldown = 60,   -- in-game minutes between manual "Set Safe Point" uses
    RestoreHealth            = true, -- full body reset on return (lore-accurate clean slate)
    DeathGuardThreshold      = 15,   -- % overall health at which the return triggers
    DepressionPerLoop        = 25,   -- unhappiness added per loop (0-100 scale)
    StressPerLoop            = 30,   -- stress added per loop, in % of the 0-1 stress scale
    PanicPerLoop             = 60,   -- panic added per loop (0-100 scale)
    PenaltyEscalation        = 25,   -- extra % of the base penalty added per completed loop
    MaxReturnsPerDay         = 0,    -- 0 = unlimited
    PlayReturnAudio          = true,
    ShowDeathCause           = true,
    EnableTellKill           = true, -- allow the "Tell them about Return by Death" kill
    TellKillRange            = 10,   -- max tiles between teller and listener
    WitchScent               = false,-- attract zombies after a return (brutal, off by default)
    WitchScentRadius         = 40,
    AllowSelfGrant           = true, -- allow right-click "Accept the Witch's contract"
                                     -- (the only way to become a bearer on B42.19+,
                                     -- where custom creation-screen traits can't register)
}

--- Read a Return by Death sandbox option with a safe fallback.
function ReturnByDeath.getOption(name)
    local sv = SandboxVars and SandboxVars.ReturnByDeath
    if sv ~= nil and sv[name] ~= nil then
        return sv[name]
    end
    return ReturnByDeath.Defaults[name]
end

--- Is the trait system this mod registers into available in this build?
--- (Build 42.19+ removed the Lua TraitFactory; traits became engine-side
--- CharacterTrait objects with no visible Lua registration hook yet.)
function ReturnByDeath.traitSystemAvailable()
    return TraitFactory ~= nil and TraitFactory.addTrait ~= nil
end

--- Does this character carry Return by Death?
--- True when they picked the trait in character creation (Build 41), or
--- accepted the Witch's contract via the right-click menu (the Build 42.19+
--- fallback, stored as a bearer flag in their ModData).
function ReturnByDeath.hasTrait(character)
    if character == nil then return false end
    local ok, res = pcall(function() return character:HasTrait(ReturnByDeath.TRAIT) end)
    if ok and res == true then return true end
    ok, res = pcall(function() return character:hasTrait(ReturnByDeath.TRAIT) end)
    if ok and res == true then return true end
    local okMd, data = pcall(function() return character:getModData().ReturnByDeath end)
    return okMd and data ~= nil and data.bearer == true
end

--- Per-character mod-data table for this mod (persists in the save).
function ReturnByDeath.getData(character)
    local md = character:getModData()
    if md.ReturnByDeath == nil then
        md.ReturnByDeath = {
            bearer = false,     -- accepted the contract (B42 trait fallback)
            loops = 0,          -- how many times this character has returned
            returnsToday = 0,   -- returns used against MaxReturnsPerDay
            lastReturnDay = -1, -- world-age day of the last counted return
            lastManual = -1000, -- world-age hours of the last manual safe point
            deathLog = {},      -- "memory of death" journal entries
            checkpoint = nil,   -- the current safe point snapshot
        }
    end
    return md.ReturnByDeath
end

--- Current world age in in-game hours (fractional).
function ReturnByDeath.worldHours()
    local gt = getGameTime()
    if gt then return gt:getWorldAgeHours() end
    return 0
end

function ReturnByDeath.log(msg)
    print("[ReturnByDeath] " .. tostring(msg))
end

--- Wall-clock milliseconds, tolerant of API differences between builds.
function ReturnByDeath.nowMs()
    local ok, ms = pcall(function() return getTimestampMs() end)
    if ok and ms then return ms end
    ok, ms = pcall(function() return getTimeInMillis() end)
    if ok and ms then return ms end
    return 0
end

------------------------------------------------------------------------------
-- Return audio (client-side playback; no-op on a dedicated server)
------------------------------------------------------------------------------

local lastAudioMs = 0
local AUDIO_LENGTH_MS = 12000 -- the clip is ~12s; never stack overlapping plays

--- Play the Return by Death sting locally. `force` skips the sandbox toggle
--- (used for the taboo kill, which should always be heard).
function ReturnByDeath.playReturnAudio(force)
    if isServer() then return end
    if not force and not ReturnByDeath.getOption("PlayReturnAudio") then return end
    local now = ReturnByDeath.nowMs()
    if now - lastAudioMs < AUDIO_LENGTH_MS then return end
    lastAudioMs = now
    pcall(function()
        getSoundManager():PlaySound(ReturnByDeath.SOUND, false, 0)
    end)
end
