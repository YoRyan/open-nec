-- A contemporary Amtrak ADU with a combined speed limit display.
local P = {}
AmtrakCombinedAdu = P

P.aspect = {stop=0,
            restrict=1,
            approach=2,
            approachmed30=3,
            approachmed45=4,
            cabspeed60=5,
            cabspeed60off=6,
            cabspeed80=7,
            cabspeed80off=8,
            clear100=9,
            clear125=10,
            clear150=11}

-- Ensure we have inherited the properties of the base class, PiL-style.
-- We can't run code on initialization in TS, so we do this in :new().
local function inherit (base)
  if getmetatable(base) == nil then
    base.__index = base
    setmetatable(P, base)
  end
end

-- Create a new AmtrakCombinedAdu context.
function P:new (conf)
  inherit(Adu)
  local o = Adu:new(conf)
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
  elseif acsesmode == Acses.mode.approachmed30 then
    aspect = P.aspect.approachmed30
    flash = false
  elseif atccode == Nec.pulsecode.restrict then
    aspect = P.aspect.restrict
    flash = false
  elseif atccode == Nec.pulsecode.approach then
    aspect = P.aspect.approach
    flash = false
  elseif atccode == Nec.pulsecode.approachmed then
    aspect = P.aspect.approachmed45
    flash = false
  elseif atccode == Nec.pulsecode.cabspeed60 then
    if self._csflasher:ison() then
      aspect = P.aspect.cabspeed60
    else
      aspect = P.aspect.cabspeed60off
    end
    flash = true
  elseif atccode == Nec.pulsecode.cabspeed80 then
    if self._csflasher:ison() then
      aspect = P.aspect.cabspeed80
    else
      aspect = P.aspect.cabspeed80off
    end
    flash = true
  elseif atccode == Nec.pulsecode.clear100 then
    aspect = P.aspect.clear100
    flash = false
  elseif atccode == Nec.pulsecode.clear125 then
    aspect = P.aspect.clear125
    flash = false
  elseif atccode == Nec.pulsecode.clear150 then
    aspect = P.aspect.clear150
    flash = false
  end
  self._csflasher:setflashstate(flash)
  return aspect
end

-- Get the current speed limit in force.
function P:getspeedlimit_mph ()
  local signalspeed_mph = Adu.getsignalspeed_mph(self)
  local civilspeed_mph = Adu.getcivilspeed_mph(self)
  local atccutin = self:atccutin()
  local acsescutin = self:acsescutin()
  if atccutin and acsescutin then
    return math.min(signalspeed_mph, civilspeed_mph)
  elseif atccutin then
    return signalspeed_mph
  elseif acsescutin then
    return civilspeed_mph
  else
    return nil
  end
end

-- Get the current time to penalty counter, if any.
function P:gettimetopenalty_s ()
  if self._acses:getmode() == Acses.mode.positivestop then
    local ttp_s = self._acses:gettimetopenalty_s()
    if ttp_s ~= nil then
      return math.floor(ttp_s)
    else
      return nil
    end
  else
    return nil
  end
end

-- Get the current state of the ATC system.
function P:atccutin ()
  return self._atc:isrunning()
end

-- Get the current state of the ACSES system.
function P:acsescutin ()
  return self._acses:isrunning()
end

return P