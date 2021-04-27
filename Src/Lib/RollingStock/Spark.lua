-- A probabilistic pantograph spark generator.
local P = {}
PantoSpark = P

local function run (self)
  while true do
    self._sched:select(nil, function () return self._spark end)
    self._isspark = math.random() < self._duration_s/self._meantimebetween_s
    self._sched:select(self._duration_s, function () return not self._spark end)
    self._isspark = false
  end
end

-- From the main coroutine, create a new PantoSpark context. This will add a
-- coroutine to the provided scheduler.
function P:new (conf)
  local o = {
    _sched = conf.scheduler,
    _duration_s = conf.duration_s or 0.2,
    _meantimebetween_s = conf.meantimebetween_s or 30,
    _spark = false,
    _isspark = false
  }
  setmetatable(o, self)
  self.__index = self
  o._sched:run(run, o)
  return o
end

-- From the main coroutine, start or stop generating sparks depending on the
-- provided condition.
function P:setsparkstate (cond)
  self._spark = cond
end

-- Returns true if the spark should render.
function P:isspark ()
  return self._isspark
end

return P