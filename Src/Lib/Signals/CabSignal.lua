-- A cab signal message tracker that retains the last signal message received.
--
-- It is used by the ATC and ACSES systems, but unlike them, it cannot be reset
-- by the player.
--
-- @include Signals/NecSignals.lua
local P = {}
CabSignal = P

local debugsignals = false

local function initstate(self)
  self._lastsig = {
    pulsecode = Nec.pulsecode.restrict,
    interlock = Nec.interlock.none,
    territory = Nec.territory.other
  }
end

-- From the main coroutine, create a new CabSignal context.
function P:new(conf)
  local o = {_sched = conf.scheduler}
  setmetatable(o, self)
  self.__index = self
  initstate(o)
  return o
end

-- Receive a custom signal message and update the stored state.
function P:receivemessage(message)
  local sig = Nec.parsesigmessage(message)
  if sig ~= nil then self._lastsig = sig end
  if debugsignals then self._sched:alert(message) end
end

-- Get the current cab signal pulse code.
function P:getpulsecode() return self._lastsig.pulsecode end

-- Get the current ACSES interlocking code.
function P:getinterlock() return self._lastsig.interlock end

-- Get the current ACSES territory code.
function P:getterritory() return self._lastsig.territory end

return P
