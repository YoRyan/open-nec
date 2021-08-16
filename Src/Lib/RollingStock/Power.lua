-- Code for electric power supply and multiple-mode locomotive modeling.
-- @include RailWorks.lua
local P = {}
Power = P

P.supply = {thirdrail = 0, overhead = 1}
P.changepoint = {
  thirdrailstart = 0,
  thirdrailend = 1,
  overheadstart = 2,
  overheadend = 3,
  ai_to_thirdrail = 10,
  ai_to_overhead = 11,
  ai_to_diesel = 12
}

local function connect(self, supply) self._available[supply] = true end

local function disconnect(self, supply) self._available[supply] = nil end

local function run(self)
  while true do
    -- Wait for the player to start a transition.
    self._sched:select(nil, function()
      return self._getselectedmode() ~= self._current_mode and
               self._getcantransition()
    end)
    self._last_mode = self._current_mode
    self._current_mode = self._getselectedmode()
    self._transitionstart = self._sched:clock()
    -- "Execute" the transition.
    self._sched:sleep(self._transition_s)
    self._last_mode = nil
    self._transitionstart = nil
  end
end

-- From the main coroutine, create a new Power context. This will add a
-- coroutine to the provided scheduler.
function P:new(conf)
  -- an array of power supplies that are available at spawn
  local available = conf.available or {}
  -- a dictionary that represents all operating modes of the locomotive; the key
  -- is a unique identifier for the mode, and the value is a function that
  -- accepts a dictionary of currently available power supplies and returns true
  -- if this mode is available for use
  local modes = conf.modes or {}
  local firstmode = 0
  for id, _ in pairs(modes) do firstmode = id end
  -- the identifier of the mode to initialize in
  local init_mode = conf.init_mode or firstmode
  local o = {
    _sched = conf.scheduler,
    _transition_s = conf.transition_s or 10,
    _getcantransition = conf.getcantransition or function() return false end,
    _getselectedmode = conf.getselectedmode or function() return firstmode end,
    -- maps an AI change point to the next power mode to change to
    _selectaimode = conf.getaimode or function(cp) return nil end,
    _available = {},
    _modes = modes,
    _current_mode = init_mode,
    _last_mode = nil,
    _transitionstart = nil
  }
  -- There's no way to detect the currently available power supplies, so we have
  -- to trust the player or scenario designer to select the right one(s) for the
  -- spawn point.
  for _, supply in ipairs(available) do connect(o, supply) end
  setmetatable(o, self)
  self.__index = self
  o._sched:run(run, o)
  return o
end

-- Determine whether or not a particular power supply is available.
function P:isavailable(supply) return self._available[supply] end

-- Set the currently available power supplies without using signal messages.
function P:setavailable(...)
  for _, supply in ipairs(arg) do connect(self, supply) end
end

-- Get the current selected power mode. In a transition phase, this will return
-- the next mode.
function P:getmode() return self._current_mode end

-- Set the current power mode without going through a transition.
function P:setmode(newmode) self._current_mode = newmode end

-- Get information about the current mode transition, if any. Returns last
-- mode, next mode, and remaining transition time, or nil if there is no
-- transition.
function P:gettransition()
  if self._transitionstart ~= nil then
    local remaining_s = self._transition_s -
                          (self._sched:clock() - self._transitionstart)
    return self._last_mode, self._current_mode, remaining_s
  else
    return nil, nil, nil
  end
end

-- Determine whether or not the locomotive has power available. This is true
-- when the locomotive is not in a transition phase and the selected power
-- mode is available for use.
function P:haspower()
  local isavailable = self._modes[self._current_mode]
  return self._transitionstart == nil and isavailable(self._available)
end

-- Get the change point type that corresponds to a signal message. If nil, then
-- the message is of an unknown format.
local function getchangepoint(message)
  if string.sub(message, 1, 1) == "P" then
    local point = string.sub(message, 3)
    if point == "OverheadStart" then
      return P.changepoint.overheadstart
    elseif point == "OverheadEnd" then
      return P.changepoint.overheadend
    elseif point == "ThirdRailStart" then
      return P.changepoint.thirdrailstart
    elseif point == "ThirdRailEnd" then
      return P.changepoint.thirdrailend
      -- New York to New Haven AI change points
    elseif point == "AIOverheadToThirdNow" then
      return P.changepoint.ai_to_thirdrail
    elseif point == "AIThirdToOverheadNow" then
      return P.changepoint.ai_to_overhead
      -- North Jersey Coast Line AI change points
    elseif point == "AIOverheadToDieselNow" then
      return P.changepoint.ai_to_diesel
    elseif point == "AIDieselToOverheadNow" then
      return P.changepoint.ai_to_overhead
      -- Hudson Line end of third rail
    elseif point == "DieselRailStart" then
      return P.changepoint.thirdrailend
    else
      return nil
    end
  else
    return nil
  end
end

local function receivechangepoint(self, cp)
  if cp == P.changepoint.thirdrailstart then
    connect(self, P.supply.thirdrail)
  elseif cp == P.changepoint.thirdrailend then
    disconnect(self, P.supply.thirdrail)
  elseif cp == P.changepoint.overheadstart then
    connect(self, P.supply.overhead)
  elseif cp == P.changepoint.overheadend then
    disconnect(self, P.supply.overhead)
  end
end

-- Receive a custom signal message. Change points will connect or disconnect
-- power supplies or, for AI trains, immediately switch to a new mode.
function P:receivemessage(message)
  if RailWorks.GetIsPlayer() then
    self:receiveplayermessage(message)
  else
    self:receiveaimessage(message)
  end
end

-- Receive a custom signal message as a player. Change points will connect or
-- disconnect power supplies.
function P:receiveplayermessage(message)
  local cp = getchangepoint(message)
  receivechangepoint(self, cp)
end

-- Receive a custom signal message as an AI. Change points will switch power
-- modes without a transition phase. If there is a power mode change, switch
-- to the new mode, then return it; else, return nil.
function P:receiveaimessage(message)
  local cp = getchangepoint(message)
  receivechangepoint(self, cp)

  if cp ~= nil and cp >= P.changepoint.ai_to_thirdrail then
    local newmode = self._getaimode(cp)
    if newmode ~= nil then self:setmode(newmode) end
  end
end

return P
