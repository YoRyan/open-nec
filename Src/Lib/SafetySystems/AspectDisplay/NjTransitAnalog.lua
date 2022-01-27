-- An NJT-style ADU with signal lamps up to 100 mph on the speedometer. This
-- style is only used on the ALP-45DP.
--
-- @include SafetySystems/AspectDisplay/AmtrakTwoSpeed.lua
local P = {}
NjTransitAnalogAdu = P

P.aspect = AmtrakTwoSpeedAdu.aspect

local downgrade = {atc = 1, acses = 2}

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
  o._lastdowngrade = nil
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
    self._lastdowngrade = nil
  end
end

-- Store the speed change event for retrieval by getatcenforcing() and
-- getacsesenforcing().
function P:_enforceevent(event)
  -- Don't override an alarm that is still sounding.
  if self._lastdowngrade == nil then
    if event == AmtrakTwoSpeedAdu._event.acsesdowngrade then
      self._lastdowngrade = downgrade.acses
    elseif event == AmtrakTwoSpeedAdu._event.atcdowngrade then
      self._lastdowngrade = downgrade.atc
    end
  end
end

-- On the ALP-45DP, we can show all the aspects we need.
function P:_canshowpulsecode(pulsecode) return true end

-- Get the current state of the ATC indicator light.
function P:getatcenforcing()
  local atcinforce = self:getsquareindicator() ==
                       AmtrakTwoSpeedAdu.square.signal
  return self:isalarm() and (self._lastdowngrade == downgrade.atc or
           (self._lastdowngrade == nil and atcinforce))
end

-- Get the current state of the ACSES indicator light.
function P:getacsesenforcing()
  local acsesinforce = self:getsquareindicator() ==
                         AmtrakTwoSpeedAdu.square.track
  return self:isalarm() and (self._lastdowngrade == downgrade.acses or
           (self._lastdowngrade == nil and acsesinforce))
end

return P
