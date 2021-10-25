-- An MTA-style ADU with separate signal and track speed limit displays and
-- "N", "L", "M", "R", and "S" lamps.
--
-- We assume it is not possible to display 60, 80, 100, 125, or 150 mph signal
-- speeds, so we will use the track speed limit display to present them.
--
-- @include SafetySystems/AspectDisplay/AspectDisplay.lua
-- @include Signals/NecSignals.lua
-- @include Units.lua
local P = {}
MetroNorthAdu = P

P.aspect = {stop = 0, restrict = 1, medium = 2, limited = 3, normal = 4}

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

-- Create a new MetroNorthAdu context.
function P:new(conf)
  inherit(Adu)
  local o = Adu:new(conf)
  o._sigspeedflasher = Flash:new{scheduler = o._sched, off_s = 0.5, on_s = 1.5}
  o._showsignalspeed = Tone:new{scheduler = o._sched, time_s = 2}
  o._truesignalspeed_mph = nil
  o._civilspeed_mph = nil
  setmetatable(o, self)
  self.__index = self
  o._sched:run(readspeeds, o)
  return o
end

-- Get the currently displayed cab signal aspect, MTA-style.
function P:getaspect()
  local acsesmode = self._acses:getmode()
  local atccode = self._atc:getpulsecode()
  if acsesmode == Acses.mode.positivestop then
    return P.aspect.stop
  elseif acsesmode == Acses.mode.approachmed30 or atccode ==
    Nec.pulsecode.approach then
    return P.aspect.medium
  elseif atccode == Nec.pulsecode.restrict then
    return P.aspect.restrict
  elseif atccode == Nec.pulsecode.approachmed then
    return P.aspect.limited
  elseif atccode == Nec.pulsecode.cabspeed60 or atccode ==
    Nec.pulsecode.cabspeed80 or atccode == Nec.pulsecode.clear100 or atccode ==
    Nec.pulsecode.clear125 or atccode == Nec.pulsecode.clear150 then
    return P.aspect.normal
  end
end

-- Get the current signal speed limit.
function P:getsignalspeed_mph()
  local speed_mph = Adu.getsignalspeed_mph(self)
  if speed_mph == 60 or speed_mph == 80 or speed_mph == 100 or speed_mph == 125 or
    speed_mph == 150 then
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

return P
