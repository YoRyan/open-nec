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
function Scheduler.run(self, fn)
  local co = coroutine.create(fn)
  table.insert(self._coroutines, co)
  self:_resume(co)
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
function Scheduler.yield(sleep)
  coroutine.yield()
end

-- Freeze execution for the given time.
function Scheduler.sleep(self, time)
  local start = self:clock()
  while self:clock() < start + time do
    self:yield()
  end
end

-- Push a message to the debug message queue.
function Scheduler.print(self, msg)
  table.insert(self._messages, msg)
end