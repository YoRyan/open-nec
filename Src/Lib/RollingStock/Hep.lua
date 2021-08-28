-- Head-end power simulator with a start/stop flicker effect.
local P = {}
Hep = P

local function run(self)
  local last_s, transit
  while true do
    local now = self._sched:clock()
    local delta = last_s == nil and 0 or (now - last_s) / self._startup_s
    last_s = now

    if transit == nil then
      -- Wait for controls to settle, then turn on HEP instantly if it's on by
      -- default.
      if not self._sched:isstartup() then
        transit = Misc.intbool(self._getrun())
      end
    else
      if self._getrun() then
        transit = math.min(transit + delta, 1)
      else
        transit = math.max(transit - delta, 0)
      end
      self._ispowered = (transit >= 0.9 and transit <= 0.95) or transit >= 1
    end

    self._sched:yield()
  end
end

-- From the main coroutine, create a new Hep context. This will add a coroutine
-- to the scheduler.
function P:new(conf)
  local o = {
    _sched = conf.scheduler,
    _getrun = conf.getrun or function() return false end,
    _startup_s = conf.startup_s or 10,
    _ispowered = false
  }
  setmetatable(o, self)
  self.__index = self
  o._sched:run(run, o)
  return o
end

-- Returns true if head-end power is available.
function P:haspower() return self._ispowered end

return P
