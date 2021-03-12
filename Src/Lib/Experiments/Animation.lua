-- Continuously cycle through an animation.
local P = {}
AnimationExperiment = P

-- From the main coroutine, create a new AnimationExperiment context.
function P:new (conf)
  local sched = conf.scheduler
  local now = sched:clock()
  local o = {
    _sched = sched,
    _anim = conf.animation,
    _cycle_s = conf.cycle_s or 1,
    _increase = true,
    _lasttime = now,
    _lastcycle = now
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- From the main coroutine, update this experiment.
function P:update ()
  local now = self._sched:clock()
  local dt = now - self._lasttime
  self._lasttime = now

  if self._increase then
    RailWorks.AddTime(self._anim, dt)
  else
    RailWorks.AddTime(self._anim, -dt)
  end

  if now - self._lastcycle >= self._cycle_s then
    if self._increase then
      RailWorks.showalert(self._anim .. " switching backwards")
    else
      RailWorks.showalert(self._anim .. " switching forwards")
    end
    self._increase = not self._increase
    self._lastcycle = now
  end
end