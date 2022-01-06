-- Head-end power simulator with a start/stop flicker effect.
--
-- @include Misc.lua
local P = {}
Hep = P

-- Create a new Hep context.
function P:new(conf)
  local o = {
    _getrun = conf.getrun or function() return false end,
    _startup_s = conf.startup_s or 10,
    _transit = 0
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Update this system once every frame.
function P:update(dt)
  local isrun = self._getrun()
  if Misc.isinitialized() then
    local delta = (isrun and dt or -dt) / self._startup_s
    self._transit = math.max(math.min(self._transit + delta, 1), 0)
  else
    -- Wait for controls to settle, then turn on HEP instantly if it's on by
    -- default.
    self._transit = Misc.intbool(isrun)
  end
end

-- Returns true if head-end power is available.
function P:haspower()
  return (self._transit >= 0.9 and self._transit <= 0.95) or self._transit >= 1
end

return P
