-- Library for managing concurrent coroutines that are updated from a single
-- update loop.

Scheduler = {}
Scheduler.__index = Scheduler

-- From the main coroutine, create a new Scheduler context.
function Scheduler.new()
  local self = setmetatable({}, Scheduler)
  self._clock = 0
  self._coroutines = {}
  self._messages = {}
  return self
end

-- From the main coroutine, create and start a new coroutine.
function Scheduler.run(self, fn, ...)
  local co = coroutine.create(fn)
  table.insert(self._coroutines, co)
  coroutine.resume(co, unpack(arg))
end

-- From the main coroutine, update all active coroutines.
function Scheduler.update(self, dt)
  self._clock = self._clock + dt
  local next_cos = {}
  for co in Tables.values(self._coroutines) do
    if coroutine.status(co) ~= "dead" then
      self:_resume(co)
      table.insert(next_cos, co)
    end
  end
  self._coroutines = next_cos
end

function Scheduler._resume(self, co)
  local success, err = coroutine.resume(co)
  if not success then
    self:print("ERROR:\n" .. err)
  end
end

-- From the main coroutine, iterate through all debug messages pushed by
-- coroutines since the last update.
function Scheduler.getmessages(self)
  return Tables.values(self._messages)
end

-- From the main coroutine, clear the debug message queue.
function Scheduler.clearmessages(self)
  self._messages = {}
end

-- Get the clock time of the current update.
function Scheduler.clock(self)
  return self._clock
end

-- Yield control until the next frame.
function Scheduler.yield(self, sleep)
  coroutine.yield()
end

-- Yield control until one of the provided functions returns true, or if the
-- timeout is reached. A nil timeout is infinite. Returns the index of the
-- condition that became true, or nil if the timeout was reached.
function Scheduler.select(self, timeout, ...)
  local start = self:clock()
  while true do
    for i, cond in ipairs(arg) do
      if cond() then
        return i
      end
    end
    if timeout ~= nil and self:clock() >= start + timeout then
      return nil
    else
      self:yield()
    end
  end
end

-- Freeze execution for the given time.
function Scheduler.sleep(self, time)
  self:select(time)
end

-- Push a message to the debug message queue.
function Scheduler.print(self, msg)
  table.insert(self._messages, msg)
end


-- Events are discrete triggers that can be waited on or polled. Doing so
-- automatically consumes and resets the event.
Event = {}
Event.__index = Event

-- Create a new Event context.
function Event.new(scheduler)
  local self = setmetatable({}, Event)
  self._sched = scheduler
  self._trigger = false
  return self
end

-- Allow one coroutine that is blocking on this event to proceed.
function Event.trigger(self)
  self._trigger = true
end

-- Block until this event is triggered, with an optional timeout.
function Event.waitfor(self, timeout)
  local res = self._sched:select(
    timeout,
    function () return self._trigger end)
  self._trigger = false
  return res == 1
end

-- Check the status of this event without blocking. Returns true if the event
-- was triggered (and resets it), or false otherwise.
function Event.poll(self)
  local res = self._trigger
  self._trigger = false
  return res
end