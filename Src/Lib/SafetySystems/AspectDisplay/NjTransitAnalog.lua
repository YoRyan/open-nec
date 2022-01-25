-- An NJT-style ADU with signal lamps up to 100 mph on the speedometer. This
-- style is only used on the ALP-45DP.
--
-- @include SafetySystems/AspectDisplay/AmtrakTwoSpeed.lua
local P = {}
NjTransitAnalogAdu = P

P.aspect = AmtrakTwoSpeedAdu.aspect
P.alarm = {atc = 1, acses = 2}

-- Ensure we have inherited the properties of the base class, PiL-style.
-- We can't run code on initialization in TS, so we do this in :new().
local function inherit(base)
  if getmetatable(base) == nil then
    base.__index = base
    setmetatable(P, base)
  end
end

-- Create a new NjTransitAnalogAdu context.
function P:new(conf)
  inherit(AmtrakTwoSpeedAdu)
  local o = AmtrakTwoSpeedAdu:new(conf)
  setmetatable(o, self)
  o._downgrade = nil
  self.__index = self
  return o
end

-- Update this system once every frame.
function P:update(dt)
  AmtrakTwoSpeedAdu.update(self, dt)

  -- At this point, if there was a downgrade-caused alarm, self._enforcingevent
  -- has been populated, and self:isalarm() is true.
  if not self:isalarm() then
    -- Clear the saved event. The cause of the next alarm will not necessarily be
    -- a downgrade.
    self._downgrade = nil
  end
end

-- Store the speed change event for retrieval by getalarmsource().
function P:_enforceevent(event)
  -- We're only interested in saving downgrade events.
  local isdowngrade =
    event == AmtrakTwoSpeedAdu._event.acsesdowngrade or event ==
      AmtrakTwoSpeedAdu._event.atcdowngrade
  if isdowngrade and self._downgrade == nil then
    -- Don't override an alarm that is still sounding.
    self._downgrade = event
  end
end

-- On the ALP-45DP, we can show all the aspects we need.
function P:_canshowpulsecode(pulsecode) return true end

-- If the alarm is sounding, return the source of the alarm. Otherwise, return nil.
function P:getalarmsource()
  if self:isalarm() then
    if self._downgrade == AmtrakTwoSpeedAdu._event.acsesdowngrade then
      return P.alarm.acses
    elseif self._downgrade == AmtrakTwoSpeedAdu._event.atcdowngrade then
      return P.alarm.atc
    else
      local isatc = self:getsquareindicator() == AmtrakTwoSpeedAdu.square.signal
      return isatc and P.alarm.atc or P.alarm.acses
    end
  end
  return nil
end

return P
