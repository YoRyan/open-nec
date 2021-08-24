-- Library for managing concurrent coroutines that are updated from a single
-- update loop.
--
-- @include Misc.lua
local P = {}
Scheduler = P

-- From the main coroutine, create a new Scheduler context.
function P:new(_)
  local o = {
    _clock = 0,
    _infomessages = {},
    _alertmessages = {},
    _coroutines = {}
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- From the main coroutine, create and start a new coroutine.
function P:run(fn, ...)
  local co = coroutine.create(fn)
  local resume = {coroutine.resume(co, unpack(arg))}
  if table.remove(resume, 1) then
    self._coroutines[co] = resume
  else
    self:info("Lua Error", resume[1])
  end
  return co
end

local function restart(self, co, ...)
  for i, cond in ipairs(arg) do
    if cond() then
      local resume = {coroutine.resume(co, i)}
      if table.remove(resume, 1) then
        return resume
      else
        self:info("Lua Error", resume[1])
        return nil
      end
    end
  end
  return arg
end

-- From the main coroutine, update all active coroutines.
function P:update()
  self._clock = RailWorks.GetSimulationTime()
  for co, conds in pairs(self._coroutines) do
    if coroutine.status(co) == "dead" then
      self._coroutines[co] = nil
    else
      self._coroutines[co] = restart(self, co, unpack(conds))
    end
  end
  -- Process message queues.
  for _, arg in ipairs(self._infomessages) do Misc.showinfo(unpack(arg)) end
  self._infomessages = {}
  for _, arg in ipairs(self._alertmessages) do Misc.showalert(unpack(arg)) end
  self._alertmessages = {}
end

-- Delete a coroutine from the scheduler.
function P:kill(co) self._coroutines[co] = nil end

-- Determine whether the simulator was just initialized a few seconds ago, so as
-- not to nag the player with annoying alerts.
function P:isstartup() return self:clock() < 3 end

-- Get the clock time of the current update.
function P:clock() return self._clock end

-- Yield control until the next frame.
function P:yield() self:select(0) end

-- Freeze execution for the given time.
function P:sleep(time) self:select(time) end

local function resumenext() return true end

-- Yield control until one of the provided functions returns true, or if the
-- timeout is reached. A nil timeout is infinite. Returns the index of the
-- condition that became true, or nil if the timeout was reached.
function P:select(timeout, ...)
  if timeout == nil then
    return coroutine.yield(unpack(arg))
  else
    if timeout == 0 then
      table.insert(arg, resumenext)
    else
      local start = self:clock()
      table.insert(arg, function() return self:clock() >= start + timeout end)
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
function P:info(...) table.insert(self._infomessages, arg) end

-- Push a message to the alert message queue.
function P:alert(...) table.insert(self._alertmessages, arg) end

return P
