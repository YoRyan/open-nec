-- A probabilistic pantograph spark generator.
local P = {}
PantoSpark = P

-- From the main coroutine, create a new PantoSpark context.
function P:new(conf)
  local o = {
    _sched = conf.scheduler,
    _tick_s = conf.tick_s or 0.2,
    _getmeantimebetween_s = conf.getmeantimebetween_s or function(aspeed_mps)
      -- Calibrated for 22 mph = 30 s, with a rapid falloff thereafter.
      if aspeed_mps == 0 then
        return 90
      else
        return math.min(300 / aspeed_mps, 90)
      end
    end,
    _lasttick_s = nil,
    _showspark = false
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- From the main coroutine, query the current spark state.
function P:isspark()
  local now = self._sched:clock()
  if self._lasttick_s == nil or now - self._lasttick_s > self._tick_s then
    local aspeed_mps = math.abs(RailWorks.GetSpeed())
    local meantime = self._getmeantimebetween_s(aspeed_mps)
    self._showspark = math.random() < self._tick_s / meantime
    self._lasttick_s = now
  end
  return self._showspark
end

return P
