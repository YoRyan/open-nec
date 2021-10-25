-- A 2000's-era Amtrak ADU with a separate signal and track speed limit displays.
--
-- We assume it is not possible to display 100, 125, or 150 mph signal speeds,
-- so we will use the track speed limit display to present them.
--
-- @include RollingStock/Tone.lua
-- @include SafetySystems/AspectDisplay/AspectDisplay.lua
-- @include Signals/NecSignals.lua
-- @include Units.lua
local P = {}
AmtrakTwoSpeedAdu = P

P.aspect = {
  stop = 0,
  restrict = 1,
  approach = 2,
  approachmed = 3,
  cabspeed = 4,
  cabspeedoff = 5,
  clear = 6
}
P.square = {none = -1, signal = 0, track = 1}

local civilspeedmode = {signal = 1, track = 2, nodata = 3}

-- Ensure we have inherited the properties of the base class, PiL-style.
-- We can't run code on initialization in TS, so we do this in :new().
local function inherit(base)
  if getmetatable(base) == nil then
    base.__index = base
    setmetatable(P, base)
  end
end

-- Returns the speed for the civil speed indicator and the kind (civilspeedmode) of
-- speed.
local function getcivilspeed(self)
  local sigspeed_mph = self:getsignalspeed_mph()
  local civspeed_mph = self._acses:getrevealedspeed_mph()
  -- If the model can't show the signal speed, and it *is* the limiting speed,
  -- flash it continuously on the civil speed display.
  if sigspeed_mph == nil then
    local truesigspeed_mph = Adu.getsignalspeed_mph(self)
    if truesigspeed_mph ~= nil and
      (civspeed_mph == nil or truesigspeed_mph < civspeed_mph) then
      return truesigspeed_mph, civilspeedmode.signal
    end
  end
  if civspeed_mph ~= nil then
    return civspeed_mph, civilspeedmode.track
  else
    return nil, civilspeedmode.nodata
  end
end

local function readspeeds(self)
  while true do
    local truesignalspeed_mph, civilspeed_mph
    self._sched:select(nil, function()
      truesignalspeed_mph = Adu.getsignalspeed_mph(self)
      civilspeed_mph = getcivilspeed(self)
      return self._truesignalspeed_mph ~= truesignalspeed_mph or
               self._civilspeed_mph ~= civilspeed_mph
    end)
    self._sched:yield()
    if not self._atc:isalarm() and not self._acses:isalarm() then
      self:triggeralert()
      -- If the model can't show the signal speed, and it's *not* the limiting
      -- speed, show it briefly on the civil speed display.
      if self._truesignalspeed_mph ~= truesignalspeed_mph and
        truesignalspeed_mph ~= nil and self:getsignalspeed_mph() == nil then
        self._showsignalspeed:trigger()
      end
    end
    self._truesignalspeed_mph = truesignalspeed_mph
    self._civilspeed_mph = civilspeed_mph
  end
end

-- Create a new AmtrakTwoSpeedAdu context.
function P:new(conf)
  inherit(Adu)
  local o = Adu:new(conf)
  o._csflasher = Flash:new{
    scheduler = o._sched,
    off_os = Nec.cabspeedflash_s,
    on_os = Nec.cabspeedflash_s
  }
  o._sigspeedflasher = Flash:new{scheduler = o._sched, off_s = 0.5, on_s = 1.5}
  o._showsignalspeed = Tone:new{scheduler = o._sched, time_s = 2}
  o._truesignalspeed_mph = nil
  o._civilspeed_mph = nil
  setmetatable(o, self)
  self.__index = self
  o._sched:run(readspeeds, o)
  return o
end

-- Get the currently displayed cab signal aspect.
function P:getaspect()
  local aspect, flash
  local acsesmode = self._acses:getmode()
  local atccode = self._atc:getpulsecode()
  if acsesmode == Acses.mode.positivestop then
    aspect = P.aspect.stop
    flash = false
  elseif acsesmode == Acses.mode.approachmed30 or atccode ==
    Nec.pulsecode.approachmed then
    aspect = P.aspect.approachmed
    flash = false
  elseif atccode == Nec.pulsecode.restrict then
    aspect = P.aspect.restrict
    flash = false
  elseif atccode == Nec.pulsecode.approach then
    aspect = P.aspect.approach
    flash = false
  elseif atccode == Nec.pulsecode.cabspeed60 or atccode ==
    Nec.pulsecode.cabspeed80 then
    if self._csflasher:ison() then
      aspect = P.aspect.cabspeed
    else
      aspect = P.aspect.cabspeedoff
    end
    flash = true
  elseif atccode == Nec.pulsecode.clear100 or atccode == Nec.pulsecode.clear125 or
    atccode == Nec.pulsecode.clear150 then
    aspect = P.aspect.clear
    flash = false
  end
  self._csflasher:setflashstate(flash)
  return aspect
end

-- Get the current signal speed limit.
function P:getsignalspeed_mph()
  local speed_mph = Adu.getsignalspeed_mph(self)
  if speed_mph == 100 or speed_mph == 125 or speed_mph == 150 then
    return nil
  else
    return speed_mph
  end
end

-- Get the current civil (track) speed limit, which is combined with the signal
-- speed limit if that limit cannot be displayed by the ADU model.
function P:getcivilspeed_mph()
  local speed_mph, mode = getcivilspeed(self)
  local flashsig = mode == civilspeedmode.signal
  self._sigspeedflasher:setflashstate(flashsig)
  if flashsig then
    return self._sigspeedflasher:ison() and Adu.getsignalspeed_mph(self) or nil
  elseif self._showsignalspeed:isplaying() then
    return Adu.getsignalspeed_mph(self)
  else
    return speed_mph
  end
end

local function getatcindicator(self)
  local atcspeed_mph = self._atc:getinforcespeed_mph()
  local acsesspeed_mph = self._acses:getrevealedspeed_mph()
  return atcspeed_mph ~= nil and Misc.round(atcspeed_mph) ~= 150 and
           (acsesspeed_mph == nil or atcspeed_mph <= acsesspeed_mph)
end

local function getacsesindicator(self)
  local atcspeed_mph = self._atc:getinforcespeed_mph()
  local acsesspeed_mph = self._acses:getrevealedspeed_mph()
  return acsesspeed_mph ~= nil and
           (atcspeed_mph == nil or Misc.round(atcspeed_mph) == 150 or
             acsesspeed_mph < atcspeed_mph)
end

-- Get the current indicator light that is illuminated, if any.
function P:getsquareindicator()
  if getatcindicator(self) then
    return P.square.signal
  elseif getacsesindicator(self) then
    return P.square.track
  else
    return P.square.none
  end
end

return P
