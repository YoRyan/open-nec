-- An event-based warning tone that plays a sound for a predefined amount of time.
local P = {}
Tone = P

local function run (self)
  while true do
    self._event:waitfor()
    self._play = true
    self._sched:sleep(self._time_s)
    self._play = false
  end
end

-- From the main coroutine, create a new Tone context. This will add a coroutine
-- to the provided scheduler.
function P:new (conf)
  local sched = conf.scheduler
  local o = {
    _sched = sched,
    _time_s = conf.time_s or 1,
    _event = Event:new{scheduler=sched},
    _play = false
  }
  setmetatable(o, self)
  self.__index = self
  o._sched:run(run, o)
  return o
end

-- Trigger the tone.
function P:trigger ()
  self._event:trigger()
end

-- Determine whether the underlying sound should play.
function P:isplaying ()
  return self._play
end

return P