-- Cab signal and track speed displays for GE Genesis units.
--
-- We will use the track speed display to display signal speeds above 45 mph.
--
-- @include SafetySystems/AspectDisplay/AspectDisplay.lua
-- @include Signals/NecSignals.lua
-- @include Units.lua
local P = {}
GenesisAdu = P

P.aspect = {restrict = 1, medium = 2, limited = 3, clear = 4}

local overspeedmode = {signal = 1, track = 2, nodata = 3}

-- Ensure we have inherited the properties of the base class, PiL-style.
-- We can't run code on initialization in TS, so we do this in :new().
local function inherit(base)
  if getmetatable(base) == nil then
    base.__index = base
    setmetatable(P, base)
  end
end

-- Returns the speed for the overspeed display and the kind (overspeedmode) of speed.
local function getoverspeed(self)
  local sigspeed_mph = self:getsignalspeed_mph()
  local civspeed_mph = self._acses:getrevealedspeed_mph()
  if sigspeed_mph == nil then
    local truesigspeed_mph = Adu.getsignalspeed_mph(self)
    if truesigspeed_mph ~= nil and
      (civspeed_mph == nil or truesigspeed_mph < civspeed_mph) then
      return truesigspeed_mph, overspeedmode.signal
    end
  end
  if civspeed_mph ~= nil then
    return civspeed_mph, overspeedmode.track
  else
    return nil, overspeedmode.nodata
  end
end

local function readspeeds(self)
  while true do
    local aspect, overspeed_mph
    self._sched:select(nil, function()
      aspect = self:getaspect()
      overspeed_mph = getoverspeed(self)
      return self._aspect ~= aspect or self._overspeed_mph ~= overspeed_mph
    end)
    self._sched:yield()
    if not self._atc:isalarm() and not self._acses:isalarm() then
      self:triggeralert()
    end
    self._aspect, self._overspeed_mph = aspect, overspeed_mph
  end
end

-- Create a new GenesisAdu context.
function P:new(conf)
  inherit(Adu)
  local o = Adu:new(conf)
  o._overspeedflasher = Flash:new{
    scheduler = conf.scheduler,
    off_s = 0.2,
    on_s = 0.3
  }
  o._aspect = nil
  o._overspeed_mph = nil
  setmetatable(o, self)
  self.__index = self
  o._sched:run(readspeeds, o)
  return o
end

-- Get the currently displayed cab signal aspect.
function P:getaspect()
  local atccode = self._atc:getpulsecode()
  if atccode == Nec.pulsecode.restrict then
    return P.aspect.restrict
  elseif atccode == Nec.pulsecode.approach then
    return P.aspect.medium
  elseif atccode == Nec.pulsecode.approachmed then
    return P.aspect.limited
  else
    return P.aspect.clear
  end
end

-- Get the current signal speed limit. Returns nil if it cannot be displayed by the
-- ADU model.
function P:getsignalspeed_mph()
  local speed_mph = Adu.getsignalspeed_mph(self)
  if speed_mph == 60 or speed_mph == 80 or speed_mph == 100 or speed_mph == 125 or
    speed_mph == 150 then
    return nil
  else
    return speed_mph
  end
end

--[[
  Get the current speed limit for the overspeed display, which combines civil
  and signal speed limits if the signal limit cannot be displayed by the ADU
  model.

  In addition, this indicator will flash during the alarm state because it's
  extremely small and difficult to read on the Genesis model.
]]
function P:getoverspeed_mph()
  local speed_mph, mode = getoverspeed(self)
  local isalarm
  if mode == overspeedmode.signal then
    isalarm = self._atc:isalarm()
  elseif mode == overspeedmode.track then
    isalarm = self._acses:isalarm()
  else
    isalarm = false
  end

  self._overspeedflasher:setflashstate(isalarm)
  if isalarm then
    return self._overspeedflasher:ison() and speed_mph or nil
  else
    return speed_mph
  end
end

return P
