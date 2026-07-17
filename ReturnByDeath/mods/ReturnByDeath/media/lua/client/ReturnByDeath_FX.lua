--[[
    Return by Death - "Witch's Miasma" screen effect
    A full-screen black slam with a red heartbeat pulse that fades out over a
    couple of seconds, so the loop reset reads as a moment of darkness rather
    than a jarring teleport.

    Runs on: client.
]]

require "ISUI/ISUIElement"
require "ReturnByDeath_Core"

RBD_ScreenFX = ISUIElement:derive("RBD_ScreenFX")
RBD_ScreenFX.active = nil

function RBD_ScreenFX:new()
    local w = getCore():getScreenWidth()
    local h = getCore():getScreenHeight()
    local o = ISUIElement:new(0, 0, w, h)
    setmetatable(o, self)
    self.__index = self
    o.startMs = ReturnByDeath.nowMs()
    o.duration = 2600
    return o
end

function RBD_ScreenFX:render()
    local ok, err = pcall(function()
        local elapsed = ReturnByDeath.nowMs() - self.startMs
        local t = elapsed / self.duration
        if t >= 1 then
            RBD_ScreenFX.active = nil
            self:removeFromUIManager()
            return
        end
        local w = getCore():getScreenWidth()
        local h = getCore():getScreenHeight()
        self:setWidth(w)
        self:setHeight(h)

        local fade = 1 - t
        self:drawRect(0, 0, w, h, fade * 0.92, 0, 0, 0)
        -- heartbeat: three red pulses across the fade
        local pulse = math.abs(math.sin(t * math.pi * 3))
        self:drawRect(0, 0, w, h, fade * 0.35 * pulse, 0.45, 0.0, 0.06)
    end)
    if not ok then
        -- a broken effect must never spam per-frame errors; kill it
        if ReturnByDeath then ReturnByDeath.reportError("screenFX", err) end
        RBD_ScreenFX.active = nil
        pcall(function() self:removeFromUIManager() end)
    end
end

--- Trigger the effect (no-op if one is already playing).
function RBD_ScreenFX.play()
    if RBD_ScreenFX.active then return end
    local fx = RBD_ScreenFX:new()
    fx:initialise()
    fx:addToUIManager()
    RBD_ScreenFX.active = fx
end
