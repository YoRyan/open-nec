-- A wrapper for a model animation with some useful methods and state-tracking.
local P = {}
Animation = P

-- Create a new Animation context.
function P:new(conf)
  local o = {
    _animation = conf.animation,
    _duration_s = conf.duration_s,
    _position = 0, -- scaled from 0 to 1
    _animate = false
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Update this animation every frame.
function P:update(dt)
  if self._animate and self._position ~= 1 then
    self._position = math.min(self._position + dt / self._duration_s, 1)
    RailWorks.AddTime(self._animation, dt)
  elseif not self._animate and self._position ~= 0 then
    self._position = math.max(self._position - dt / self._duration_s, 0)
    RailWorks.AddTime(self._animation, -dt)
  end
end

-- Get the current position of this animation, scaled from 0 (not started) to
-- 1 (complete).
function P:getposition() return self._position end

-- Set the current position of this animation, scaled from 0 (not started) to 1
-- (complete). If updated, the animation may still run, depending on the value
-- passed to setanimatedstate().
function P:setposition(pos)
  self._position = pos
  RailWorks.SetTime(self._animation, pos * self._duration_s)
end

-- Set the target state of this animation.
function P:setanimatedstate(state) self._animate = state end

return P
