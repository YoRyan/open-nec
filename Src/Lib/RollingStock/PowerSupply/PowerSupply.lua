-- Base class for modeling a locomotive power supply with one or more switchable
-- modes and a fixed transition period.
--
-- This implementation creates a single mode that is always available regardless
-- of electrification status--i.e., a diesel or steam engine.
--
-- @include RollingStock/PowerSupply/Electrification.lua
-- @include Iterator.lua
-- @include RailWorks.lua
local P = {}
PowerSupply = P

local function onaichangepoint(self, cp)
  if not RailWorks.GetIsPlayer() then
    local nextmode = self._getaimode(cp)
    if nextmode ~= nil then self:setmode(nextmode) end
  end
end

-- From the main coroutine, create a new PowerSupply context.
function P:new(conf)
  local o = {
    _sched = conf.scheduler,
    -- name of the control that stores the currently selected power mode; if
    -- not supplied, the player will not be able to switch between modes
    _control = conf.modecontrol,
    -- control read transformation function; can be used to compensate for cab
    -- car scripting bugs
    _readfn = conf.modereadfn or function(v) return v end,
    _transition_s = conf.transition_s or 10,
    _getcantransition = conf.getcantransition or function() return false end,
    -- maps AI automatic change point to the mode to automagically switch to
    _getaimode = conf.getaimode or function(cp) return nil end,
    --[[
      a dictionary that represents all operating modes of the locomotive; the
      key is the unique control value for the mode, and the value is a function
      that accepts an Electrification instance and returns true if this mode is
      serviceable and available for use
      ]]
    _modes = conf.modes or {[0] = function(elec) return true end},
    -- executes when the controls have settled and the power supply has
    -- initialized
    _oninit = conf.oninit or function(p) end,
    _currentmode = nil,
    _transitionstart = nil
  }
  o._elec = Electrification:new{
    controlmap = conf.eleccontrolmap,
    onaichangepoint = function(cp) onaichangepoint(o, cp) end
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

local function getcv(self)
  if self._control ~= nil then
    local v = RailWorks.GetControlValue(self._control, 0)
    return self._readfn(v)
  else
    return self._currentmode
  end
end

local function setcv(self, value)
  if self._control ~= nil then
    RailWorks.SetControlValue(self._control, 0, value)
  end
end

-- Get the currently selected power mode. In a transition phase, this will
-- return the *previous* mode.
function P:getmode() return self._currentmode end

-- From the main coroutine, set the current power mode without going through a
-- transition.
function P:setmode(newmode)
  self._currentmode = newmode
  setcv(self, newmode)
end

-- From the main coroutine, set the presence of a type of electrification.
function P:setavailable(type, present) self._elec:setavailable(type, present) end

-- From the main coroutine, get information about the current mode transition,
-- if any. Returns last mode, next mode, and remaining transition time, or nil
-- if there is no transition.
function P:gettransition()
  if self._transitionstart ~= nil then
    local remaining_s = self._transition_s -
                          (self._sched:clock() - self._transitionstart)
    return self._currentmode, getcv(self), remaining_s
  else
    return nil, nil, nil
  end
end

-- Determine whether or not the locomotive has power available. This is true
-- when the locomotive is not in a transition phase and the selected power
-- mode is available for use.
function P:haspower()
  if self._currentmode == nil then
    return true
  else
    local isavailable = self._modes[self._currentmode]
    return self._transitionstart == nil and isavailable(self._elec)
  end
end

-- From the main coroutine, update this module every frame.
function P:update()
  if self._sched:isstartup() then return end

  local selmode = getcv(self)
  local now = self._sched:clock()
  if self._currentmode == nil then
    -- Read the initialized mode after startup.
    local initmode = selmode ~= nil and selmode or
                       Iterator.findfirst(function(k, v) return true end,
                                          pairs(self._modes))
    self._currentmode = initmode
    self:_oninit()
  elseif self._transitionstart == nil and selmode ~= self._currentmode and
    self._getcantransition() then
    -- Initialize power transition.
    self._transitionstart = now
  elseif self._transitionstart ~= nil and now - self._transitionstart >
    self._transition_s then
    -- End the transition.
    self._currentmode = selmode
    self._transitionstart = nil
  end
end

-- From the main coroutine, receive a custom signal message and, if it is a
-- power change point, process it.
function P:receivemessage(message) self._elec:receivemessage(message) end

return P