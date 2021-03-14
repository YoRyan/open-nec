-- An on-off flash state machine.
local P = {}
Flash = P

local function cycle (self)
  self._ison = true
  local event = self._sched:select(
    self._on_s, function () return not self._flash end)
  self._ison = false
  if event == nil then
    self._sched:select(
      self._off_s, function () return not self._flash end)
  end
end

local function run (self)
  while true do
    self._sched:select(nil, function () return self._flash end)
    cycle(self)
  end
end

-- From the main coroutine, create a new Flash context. This will add a coroutine
-- to the provided scheduler.
function P:new (conf)
  local sched = conf.scheduler
  local o = {
    _sched = sched,
    _off_s = conf.off_s or 1,
    _on_s = conf.on_s or 1,
    _flash = false,
    _ison = false
  }
  setmetatable(o, self)
  self.__index = self
  o._sched:run(run, o)
  return o
end

-- From the main coroutine, start or stop the flash sequence based on the
-- provided condition.
function P:setflashstate (cond)
  self._flash = cond
end

-- Returns true if the flasher in the "on" phase.
function P:ison ()
  return self._ison
end

return P