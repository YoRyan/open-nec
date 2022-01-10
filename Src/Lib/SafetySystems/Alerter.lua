-- Alerter implementation with a penalty state.
--
-- @include Misc.lua
-- @include RailWorks.lua
-- @include Units.lua
local P = {}
Alerter = P

-- Create a new Alerter context.
function P:new(conf)
  local o = {
    _getacknowledge = conf.getacknowledge or function() return false end,
    _ackevent = false,
    _countdown_s = conf.countdown_s or 60,
    _alarm_s = conf.alarm_s or 6,
    _lastack_s = RailWorks.GetSimulationTime()
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Start or stop the subsystem based on the provided condition.
function P:setrunstate(cond)
  if cond and not self._running then
    self:start()
  elseif not cond and self._running then
    self:stop()
  end
end

-- Update this system once every frame.
function P:update(_)
  local acknowledge = self._getacknowledge() or self._ackevent
  self._ackevent = false

  local speed_mps = RailWorks.GetControlValue("SpeedometerMPH", 0) *
                      Units.mph.tomps
  local stopped = speed_mps < Misc.stopped_mps
  local clock_s = RailWorks.GetSimulationTime()
  if self:ispenalty() then
    -- Release the penalty when the train is stopped and the alerter is
    -- acknowledged.
    if acknowledge and stopped then self._lastack_s = clock_s end
  elseif self:isalarm() then
    -- Silence the alarm when acknowledged.
    if acknowledge then self._lastack_s = clock_s end
  elseif acknowledge or stopped then
    -- Reset the alerter when acknowledged (or not moving).
    self._lastack_s = clock_s
  end
end

-- Initialize this subsystem.
function P:start()
  if not self._running then
    self._running = true
    self._ackevent = false
    self._lastack_s = RailWorks.GetSimulationTime()
    if Misc.isinitialized() then Misc.showalert("Alerter", "Cut In") end
  end
end

-- Halt and reset this subsystem.
function P:stop()
  if self._running then
    self._running = false
    if Misc.isinitialized() then Misc.showalert("Alerter", "Cut Out") end
  end
end

-- Returns true when a penalty brake is applied.
function P:ispenalty()
  local clock_s = RailWorks.GetSimulationTime()
  return clock_s - self._lastack_s > self._countdown_s + self._alarm_s
end

-- Returns true when the alarm is applied.
function P:isalarm()
  local clock_s = RailWorks.GetSimulationTime()
  return clock_s - self._lastack_s > self._countdown_s
end

-- Call to reset the alerter as a one-time event. (This sets an internal flag
-- that will be cleared on the next update.)
function P:acknowledge() self._ackevent = true end

return P
