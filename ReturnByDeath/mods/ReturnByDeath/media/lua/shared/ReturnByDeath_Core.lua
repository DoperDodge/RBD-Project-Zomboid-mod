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
    AnchorIntervalReal       = 5,    -- REAL-WORLD minutes between automatic anchors
    SafeCheckpointsOnly      = true, -- only auto-anchor while calm (no zombies aggroed/close)
    AnchorHistory            = 10,   -- how many past anchors the loop remembers
    MaxZombiesAtAnchor       = 2,    -- an anchor is "safe" with at most this many zombies near it
    AnchorSafetyRadius       = 15,   -- tiles around an anchor checked for zombies on return
    AllowManualSafePoint     = false,-- right-click "Set Safe Point" (not anime-accurate; off)
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

------------------------------------------------------------------------------
-- Error containment
-- Every event handler is wrapped so a failing engine call can never spam the
-- on-screen error counter: each unique error is printed to console.txt ONCE
-- (grep for "[ReturnByDeath] ERROR") and then swallowed.
------------------------------------------------------------------------------

local reportedErrors = {}

function ReturnByDeath.reportError(where, err)
    local key = tostring(where) .. "|" .. tostring(err)
    if reportedErrors[key] then return end
    reportedErrors[key] = true
    print("[ReturnByDeath] ERROR in " .. tostring(where) .. ": " .. tostring(err))
end

--- Wrap an event handler; errors are logged once instead of thrown.
function ReturnByDeath.wrap(name, fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then ReturnByDeath.reportError(name, err) end
    end
end

--- Run fn now; on failure log once (named) and return false. Use this
--- instead of bare pcall wherever silent failure would hide a real bug.
function ReturnByDeath.try(where, fn)
    local ok, err = pcall(fn)
    if not ok then ReturnByDeath.reportError(where, err) end
    return ok
end

------------------------------------------------------------------------------
-- API-drift-tolerant player helpers
------------------------------------------------------------------------------

--- Is this one of the players simulated on this machine? Falls back to
--- comparing against the local player slots if isLocalPlayer() is missing.
function ReturnByDeath.isLocal(player)
    local ok, res = pcall(function() return player:isLocalPlayer() end)
    if ok and res ~= nil then return res == true end
    for i = 0, 3 do
        if getSpecificPlayer(i) == player then return true end
    end
    return false
end

--- Local player slot index (0-3), tolerant of getPlayerNum() drifting.
function ReturnByDeath.playerIndex(player)
    local ok, n = pcall(function() return player:getPlayerNum() end)
    if ok and type(n) == "number" then return n end
    for i = 0, 3 do
        if getSpecificPlayer(i) == player then return i end
    end
    return 0
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
