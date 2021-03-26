-- A speed post tracker that calculates the speed limit in force at the
-- player's location, irrespective of train length.
local P = {}
AcsesTrackSpeed = P

local function run (self)
  local before_mps = {}
  local after_mps = {}
  local sensed_mps = nil
  while true do
    self._sched:yield()
    do
      local newbefore_mps = {}
      local newafter_mps = {}
      for id, distance_m in self._limittracker:iterdistances_m() do
        local limit = self._limittracker:getobject(id)
        if distance_m >= 0 then
          newbefore_mps[id] = before_mps[id]
          newafter_mps[id] = limit.speed_mps
        elseif distance_m <= 0 then
          newbefore_mps[id] = limit.speed_mps
          newafter_mps[id] = after_mps[id]
        else
          newbefore_mps[id] = before_mps[id]
          newafter_mps[id] = after_mps[id]
        end
      end
      before_mps = newbefore_mps
      after_mps = newafter_mps
    end
    do
      local lastid = Iterator.max(Iterator.ltcomp, Iterator.filter(
        function (_, distance_m) return distance_m < 0 end,
        self._limittracker:iterdistances_m()))
      local nextid = Iterator.min(Iterator.ltcomp, Iterator.filter(
        function (_, distance_m) return distance_m > 0 end,
        self._limittracker:iterdistances_m()))
      -- Retain the deduced speed limit even if the original speed post is more
      -- than 10km away.
      sensed_mps = after_mps[lastid] or before_mps[nextid] or sensed_mps
      local gamespeed_mps = self._gettrackspeed_mps()
      if sensed_mps == nil then
        self._sensedspeed_mps = gamespeed_mps
      -- The game-calculated speed limit is strictly lower than the track
      -- speed limit we want, so if that is higher, then we should use it.
      elseif gamespeed_mps > sensed_mps then
        self._sensedspeed_mps = gamespeed_mps
      -- If the previous speed post is behind the end of our train, then we
      -- can use the game-calculated speed limit.
      elseif lastid ~= nil and -self._limittracker:getdistance_m(lastid)
          > self._getconsistlength_m() then
        self._sensedspeed_mps = gamespeed_mps
      else
        self._sensedspeed_mps = sensed_mps
      end
    end
  end
end

-- From the main coroutine, create a new speed post tracker context. This will
-- add coroutines to the provided scheduler.
function P:new (conf)
  local o = {
    _sched = conf.scheduler,
    _limittracker = conf.speedlimittracker,
    _gettrackspeed_mps = conf.gettrackspeed_mps or function () return 0 end,
    _getconsistlength_m = conf.getconsistlength_m or function () return 0 end,
    _sensedspeed_mps = 0
  }
  setmetatable(o, self)
  self.__index = self
  o._coroutines = {o._sched:run(run, o)}
  return o
end

-- From the main coroutine, kill this subsystem's coroutines.
function P:kill ()
  for _, co in ipairs(self._coroutines) do
    self._sched:kill(co)
  end
end

-- Get the current sensed track speed.
function P:gettrackspeed_mps ()
  return self._sensedspeed_mps
end

return P