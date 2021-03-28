-- An NJT-style integrated digital speedometer and ADU display. Maximum speed is
-- 120 mph.
local P = {}
NjTransitDigitalAdu = P

-- Ensure we have inherited the properties of the base class, PiL-style.
-- We can't run code on initialization in TS, so we do this in :new().
local function inherit (base)
  if getmetatable(base) == nil then
    base.__index = base
    setmetatable(P, base)
  end
end

-- Create a new NjTransitDigitalAdu context.
function P:new (conf)
  inherit(Adu)
  local o = Adu:new(conf)
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Determine whether there is a speed restriction in effect.
function P:isspeedrestriction ()
  local atccode = self._atc:getpulsecode()
  local atcrestrict = atccode ~= Nec.pulsecode.clear125
    and atccode ~= Nec.pulsecode.clear150
    and self._atc:isrunning()
  local acsesrestrict = self._acses:isalarm()
    or self._acses:getmode() ~= Acses.mode.normal
  return atcrestrict or acsesrestrict
end

local function getspeedlimit_mph (self)
  local signalspeed_mph = Adu.getsignalspeed_mph(self)
  local civilspeed_mph = Adu.getcivilspeed_mph(self)
  local atccutin = self._atc:isrunning()
  local acsescutin = self._acses:isrunning()
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

-- Get the current position of the green speed zone.
function P:getgreenzone_mph (speed_mps)
  local aspeed_mph = math.abs(speed_mps)*Units.mps.tomph
  local limit_mph = getspeedlimit_mph(self)
  if self:isspeedrestriction() and limit_mph ~= nil then
    return math.min(limit_mph, aspeed_mph)
  else
    return 0
  end
end

-- Get the current position of the red speed zone.
function P:getredzone_mph (speed_mps)
  local aspeed_mph = math.abs(speed_mps)*Units.mps.tomph
  local limit_mph = getspeedlimit_mph(self)
  if self:isspeedrestriction() and limit_mph ~= nil and aspeed_mph > limit_mph then
    return aspeed_mph
  else
    return 0
  end
end

return P