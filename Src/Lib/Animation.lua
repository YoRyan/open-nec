-- A wrapper for a model animation with some useful methods and state-tracking.
local P = {}
Animation = P

-- From the main coroutine, create a new Animation context.
function P:new (conf)
  local sched = conf.scheduler
  local o = {
    _sched = sched,
    _animation = conf.animation,
    _duration_s = conf.duration_s,
    _lastclock_s = sched:clock(),
    _position = 0, -- scaled from 0 to 1
    _animate = false
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- From the main coroutine, update this animation.
function P:update ()
  local now_s = self._sched:clock()
  local dt_s = now_s - self._lastclock_s
  self._lastclock_s = now_s

  if self._animate and self._position ~= 1 then
    self._position = math.min(self._position + dt_s/self._duration_s, 1)
    RailWorks.AddTime(self._animation, dt_s)
  elseif not self._animate and self._position ~= 0 then
    self._position = math.max(self._position - dt_s/self._duration_s, 0)
    RailWorks.AddTime(self._animation, -dt_s)
  end
end

-- Get the current position of this animation, scaled from 0 (not started) to
-- 1 (complete).
function P:getposition ()
  return self._position
end

-- From the main coroutine, set the current position of this animation, scaled
-- from 0 (not started) to 1 (complete). The animation may still run depending
-- on the value passed to setanimatedstate().
function P:setposition (pos)
  self._position = pos
  RailWorks.SetTime(self._animation, pos*self._duration_s)
end

-- Set the target state of this animation.
function P:setanimatedstate (state)
  self._animate = state
end

return P