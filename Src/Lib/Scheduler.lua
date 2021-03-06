-- Library for managing concurrent coroutines that are updated from a single
-- update loop.

Scheduler = {}
Scheduler.__index = Scheduler

-- From the main coroutine, create a new Scheduler context.
function Scheduler.new()
  local self = setmetatable({}, Scheduler)
  self._clock = 0
  self._coroutines = {}
  self._infomessages = {}
  self._alertmessages = {}
  return self
end

-- From the main coroutine, create and start a new coroutine.
function Scheduler.run(self, fn, ...)
  local co = coroutine.create(fn)
  local resume = {coroutine.resume(co, unpack(arg))}
  if table.remove(resume, 1) then
    self._coroutines[co] = resume
  else
    self:info("ERROR:\n" .. resume[1])
  end
  return co
end

-- From the main coroutine, update all active coroutines.
function Scheduler.update(self, dt)
  self._clock = RailWorks.GetSimulationTime()
  for co, conds in pairs(self._coroutines) do
    if coroutine.status(co) == "dead" then
      self._coroutines[co] = nil
    else
      self._coroutines[co] = self:_resume(co, unpack(conds))
    end
  end
end

function Scheduler._resume(self, co, ...)
  for i, cond in ipairs(arg) do
    if cond() then
      local resume = {coroutine.resume(co, i)}
      if table.remove(resume, 1) then
        return resume
      else
        self:info("ERROR:\n" .. resume[1])
        return nil
      end
    end
  end
  return arg
end

-- Get a table of all info messages pushed by coroutines since the last update.
function Scheduler.getinfomessages(self)
  return self._infomessages
end

-- From the main coroutine, clear the info message queue.
function Scheduler.clearinfomessages(self)
  self._infomessages = {}
end

-- Get a table of all info messages pushed by coroutines since the last update.
function Scheduler.getalertmessages(self)
  return self._alertmessages
end

-- From the main coroutine, clear the info message queue.
function Scheduler.clearalertmessages(self)
  self._alertmessages = {}
end

-- Delete a coroutine from the scheduler.
function Scheduler.kill(self, co)
  self._coroutines[co] = nil
end

-- Determine whether the simulator was just initialized a few seconds ago, so as
-- not to nag the player with annoying alerts.
function Scheduler.isstartup(self)
  return self:clock() < 3
end

-- Get the clock time of the current update.
function Scheduler.clock(self)
  return self._clock
end

-- Yield control until the next frame.
function Scheduler.yield(self)
  self:select(0)
end

-- Freeze execution for the given time.
function Scheduler.sleep(self, time)
  self:select(time)
end

-- Yield control until one of the provided functions returns true, or if the
-- timeout is reached. A nil timeout is infinite. Returns the index of the
-- condition that became true, or nil if the timeout was reached.
function Scheduler.select(self, timeout, ...)
  if timeout == nil then
    return coroutine.yield(unpack(arg))
  else
    if timeout == 0 then
      table.insert(arg, function () return true end)
    else
      local start = self:clock()
      table.insert(arg, function () return self:clock() >= start + timeout end)
    end
    local which = coroutine.yield(unpack(arg))
    if which == table.getn(arg) then
      return nil
    else
      return which
    end
  end
end

-- Push a message to the info message queue.
function Scheduler.info(self, msg)
  table.insert(self._infomessages, msg)
end

-- Push a message to the alert message queue.
function Scheduler.alert(self, msg)
  table.insert(self._alertmessages, msg)
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