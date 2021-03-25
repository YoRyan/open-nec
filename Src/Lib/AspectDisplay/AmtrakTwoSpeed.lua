-- A 2000's-era Amtrak ADU with a separate signal and track speed limit displays.
-- We assume it is not possible to display 100, 125, or 150 mph signal speeds,
-- so we will use the track speed limit display to present them.
local P = {}
AmtrakTwoSpeedAdu = P

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
  o._sigspeedflasher = Flash:new{
    scheduler = conf.scheduler,
    off_s = 0.5,
    on_s = 1.5
  }
  setmetatable(o, self)
  self.__index = self
  return o
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

return P