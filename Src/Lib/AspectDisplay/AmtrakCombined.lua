-- A contemporary Amtrak ADU with a combined speed limit display.
local P = {}
AmtrakCombinedAdu = P

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

-- Get the current state of the ATC system.
function P:atccutin ()
  return self._atc:isrunning()
end

-- Get the current state of the ACSES system.
function P:acsescutin ()
  return self._acses:isrunning()
end

return P