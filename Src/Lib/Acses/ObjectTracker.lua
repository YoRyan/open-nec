-- Assigns persistent unique identifiers to trackside objects that are sensed by
-- their relative distances from the player.
local P = {}
AcsesTracker = P

local passing_m = 16
local trackmargin_m = 2

local function run (self)
  local ctr = 1
  local lasttime = self._sched:clock()
  while true do
    self._sched:yield()
    local time = self._sched:clock()
    local travel_m = self._getspeed_mps()*(time - lasttime)
    lasttime = time

    local newobjects = {}
    local newdistances_m = {}

    -- Match sensed objects to tracked objects, taking into consideration the
    -- anticipated travel distance.
    for rawdistance_m, obj in self._iterbydistance() do
      local sensedistance_m
      if rawdistance_m >= 0 then
        sensedistance_m = rawdistance_m + passing_m/2
      else
        sensedistance_m = rawdistance_m - passing_m/2
      end
      local match = Iterator.findfirst(
        function (_, trackdistance_m)
          return math.abs(trackdistance_m - travel_m - sensedistance_m)
            < trackmargin_m/2
        end,
        pairs(self._distances_m))
      if match == nil then
        -- Add unmatched objects.
        newobjects[ctr] = obj
        newdistances_m[ctr] = sensedistance_m
        ctr = ctr + 1
      else
        -- Update matched objects.
        newobjects[match] = obj
        newdistances_m[match] = sensedistance_m
      end
    end

    --[[
      Track objects will briefly disappear for about 16 m of travel before they
      reappear in the reverse direction. We call this area the "passing" zone.

      d < 0|invisible|d > 0
      ---->|__~16_m__|<----

      Here, we add back objects that are no longer detected, but are within the
      passing zone.
    ]]
    local ispassing = function (id, distance_m)
      -- Use a generous retention margin here so that users will be notified
      -- with a positive or negative distance if an object cannot be tracked
      -- in the reverse direction.
      return newdistances_m[id] == nil and math.abs(distance_m - travel_m)
        < passing_m/2 + trackmargin_m
    end
    for id, distance_m in Iterator.filter(ispassing, pairs(self._distances_m)) do
      newobjects[id] = self._objects[id]
      newdistances_m[id] = distance_m - travel_m
    end

    self._objects = newobjects
    self._distances_m = newdistances_m
  end
end

--[[
  From the main coroutine, create a new track object tracker context. This will
  add coroutines to the provided scheduler.

  iterbydistance should return an iterator of (distance (m), tracked object) pairs.
]]
function P:new (conf)
  local o = {
    _sched = conf.scheduler,
    _getspeed_mps = conf.getspeed_mps or function () return 0 end,
    _iterbydistance = conf.iterbydistance or function () return pairs({}) end,
    _objects = {},
    _distances_m = {}
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

-- Iterate through all tracked objects by their identifiers.
function P:iterobjects ()
  return pairs(self._objects)
end

-- Get a tracked object by identifier.
function P:getobject (id)
  return self._objects[id]
end

local function getcorrectdistance_m (self, id)
  local distance_m = self._distances_m[id]
  if distance_m == nil then
    return nil
  elseif distance_m < -passing_m/2 then
    return distance_m + passing_m/2
  elseif distance_m > passing_m/2 then
    return distance_m - passing_m/2
  else
    return 0
  end
end

-- Iterate through all relative distances by identifier.
function P:iterdistances_m ()
  return Iterator.map(
    function (id, _) return id, getcorrectdistance_m(self, id) end,
    pairs(self._distances_m))
end

-- Get a relative distance by identifier.
function P:getdistance_m (id)
  return getcorrectdistance_m(self, id)
end

return P