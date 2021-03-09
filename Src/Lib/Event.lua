-- Events are discrete triggers that can be waited on or polled. Doing so
-- automatically consumes and resets the event.
local P = {}
Event = P

-- Create a new Event context.
function P:new (conf)
  local o = {
    _sched = conf.scheduler,
    _trigger = false
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Allow one coroutine that is blocking on this event to proceed.
function P:trigger ()
  self._trigger = true
end

-- Block until this event is triggered, with an optional timeout.
function P:waitfor (timeout)
  local res = self._sched:select(
    timeout,
    function () return self._trigger end)
  self._trigger = false
  return res == 1
end

-- Check the status of this event without blocking. Returns true if the event
-- was triggered (and resets it), or false otherwise.
function P:poll ()
  local res = self._trigger
  self._trigger = false
  return res
end

return P