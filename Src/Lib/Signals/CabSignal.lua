-- A cab signal message tracker that retains the last signal message received.
--
-- It is used by the ATC and ACSES systems, but unlike them, it cannot be reset
-- by the player.
local P = {}
CabSignal = P

local debugsignals = false

local function initstate(self)
  self._pulsecode = Nec.pulsecode.restrict
  self._acsescode = Nec.acsescode.none
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
  local pulsecode, acsescode = Nec.parsesigmessage(message)
  if pulsecode ~= nil then
    self._pulsecode = pulsecode
    self._acsescode = acsescode
  end
  if debugsignals then self._sched:alert(message) end
end

-- Get the current cab signal pulse code.
function P:getpulsecode() return self._pulsecode end

-- Get the current ACSES status code.
function P:getacsescode() return self._acsescode end

return P
