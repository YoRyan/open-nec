-- A 2000's-era Amtrak ADU with a separate signal and track speed limit displays.
-- We assume it is not possible to display 100, 125, or 150 mph signal speeds,
-- so we will use the track speed limit display to present them.
local P = {}
AmtrakTwoSpeedAdu = P

P.aspect = {stop=0,
            restrict=1,
            approach=2,
            approachmed=3,
            cabspeed=4,
            cabspeedoff=5,
            clear=6}
P.square = {none=-1, signal=0, track=1}

-- Ensure we have inherited the properties of the base class, PiL-style.
-- We can't run code on initialization in TS, so we do this in :new().
local function inherit (base)
  if getmetatable(base) == nil then
    base.__index = base
    setmetatable(P, base)
  end
end

-- Create a new AmtrakTwoSpeedAdu context.
function P:new (conf)
  inherit(Adu)
  local o = Adu:new(conf)
  o._csflasher = Flash:new{
    scheduler = conf.scheduler,
    off_os = Nec.cabspeedflash_s,
    on_os = Nec.cabspeedflash_s
  }
  o._sigspeedflasher = Flash:new{
    scheduler = conf.scheduler,
    off_s = 0.5,
    on_s = 1.5
  }
  o._squareflasher = Flash:new{
    scheduler = conf.scheduler,
    off_s = 0.5,
    on_s = 0.5
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Get the currently displayed cab signal aspect.
function P:getaspect ()
  local aspect, flash
  local acsesmode = self._acses:getmode()
  local atccode = self._atc:getpulsecode()
  if acsesmode == Acses.mode.positivestop then
    aspect = P.aspect.stop
    flash = false
  elseif acsesmode == Acses.mode.approachmed30
      or atccode == Nec.pulsecode.approachmed then
    aspect = P.aspect.approachmed
    flash = false
  elseif atccode == Nec.pulsecode.restrict then
    aspect = P.aspect.restrict
    flash = false
  elseif atccode == Nec.pulsecode.approach then
    aspect = P.aspect.approach
    flash = false
  elseif atccode == Nec.pulsecode.cabspeed60
      or atccode == Nec.pulsecode.cabspeed80 then
    if self._csflasher:ison() then
      aspect = P.aspect.cabspeed
    else
      aspect = P.aspect.cabspeedoff
    end
    flash = true
  elseif atccode == Nec.pulsecode.clear100
      or atccode == Nec.pulsecode.clear125
      or atccode == Nec.pulsecode.clear150 then
    aspect = P.aspect.clear
    flash = false
  end
  self._csflasher:setflashstate(flash)
  return aspect
end

-- Get the current signal speed limit.
function P:getsignalspeed_mph ()
  local speed_mph = Adu.getsignalspeed_mph(self)
  if speed_mph == 100 or speed_mph == 125 or speed_mph == 150 then
    return nil
  else
    return speed_mph
  end
end

-- Get the current civil (track) speed limit, which is combined with the signal
-- speed limit if that limit cannot be displayed by the ADU model.
function P:getcivilspeed_mph ()
  local sigspeed_mph = self:getsignalspeed_mph()
  local civspeed_mph = Adu.getcivilspeed_mph(self)
  local speed_mph, flash
  if sigspeed_mph == nil and not self:getacsesindicator() then
    local truesigspeed_mph = Adu.getsignalspeed_mph(self)
    if self:getatcindicator() then
      speed_mph = truesigspeed_mph
      flash = false
    elseif truesigspeed_mph < civspeed_mph then
      if self._sigspeedflasher:ison() then
        speed_mph = truesigspeed_mph
      else
        speed_mph = nil
      end
      flash = true
    else
      speed_mph = civspeed_mph
      flash = false
    end
  else
    speed_mph = civspeed_mph
    flash = false
  end
  self._sigspeedflasher:setflashstate(flash)
  return speed_mph
end

-- Get the current indicator light that is illuminated, if any.
function P:getsquareindicator ()
  local atcind = self:getatcindicator()
  local acsesind = self:getacsesindicator()
  self._squareflasher:setflashstate(atcind or acsesind)
  local lit = self._squareflasher:ison()
  if lit and atcind then
    return P.square.signal
  elseif lit and acsesind then
    return P.square.track
  else
    return P.square.none
  end
end

return P