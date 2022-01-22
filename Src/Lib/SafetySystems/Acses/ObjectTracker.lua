-- Assigns persistent unique identifiers to trackside objects that are sensed by
-- their relative distances from the player.
--
-- @include Iterator.lua
-- @include RailWorks.lua
-- @include Units.lua
local P = {}
AcsesTracker = P

local maxpassing_m = 28.5 -- 1.1*85 ft
local trackmargin_m = 4

-- Create a new track object tracker context. iterbydistance should return an
-- iterator of (distance (m), tracked object) pairs.
function P:new(conf)
  local o = {
    _iterbydistance = conf.iterbydistance or
      function() return Iterator.empty() end,
    _ctr = 1,
    _objects = {},
    _distances_m = {},
    --[[
      Track objects will briefly disappear before they reappear in the reverse
      direction - the exact distance is possibly the locomotive length? We call
      this area the "passing" zone.

      d < 0|invisible|d > 0
      ---->|_________|<----
    ]]
    _passing_m = {}
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Update this system once every frame.
function P:update(dt)
  local speed_mps = RailWorks.GetSpeed() -- speed needs to be very accurate
  local travel_m = speed_mps * dt
  local newobjects = {}
  local newdistances_m = {}
  local newpassing_m = {}

  local function itertravel(id, distance_m) return id, distance_m - travel_m end
  local inferdistances_m = Iterator.totable(
                             Iterator.map(itertravel, pairs(self._distances_m)))
  local inferpassing_m = Iterator.totable(
                           Iterator.map(itertravel, pairs(self._passing_m)))

  -- Match sensed objects to tracked objects, taking into consideration the
  -- anticipated travel distance.
  for sensedistance_m, obj in self._iterbydistance() do
    local closest = Iterator.min(function(dista_m, distb_m)
      return math.abs(dista_m - sensedistance_m) <
               math.abs(distb_m - sensedistance_m)
    end, pairs(inferdistances_m))
    local newid
    if closest == nil or math.abs(inferdistances_m[closest] - sensedistance_m) >=
      trackmargin_m then
      -- If the distance is close, then attempt to match to a passing object.
      local passed
      if sensedistance_m < trackmargin_m then
        passed = Iterator.max(Iterator.ltcomp, self._passing_m)
      elseif sensedistance_m > -trackmargin_m then
        passed = Iterator.min(Iterator.ltcomp, self._passing_m)
      else
        passed = nil
      end
      if passed == nil then
        -- Add unmatched object.
        newid = self._ctr
        self._ctr = self._ctr + 1
      else
        -- Re-add passed object.
        newid = passed
      end
    else
      -- Update matched object.
      newid = closest
    end
    newobjects[newid] = obj
    newdistances_m[newid] = sensedistance_m
  end

  -- Cull passing objects that have exceeded the maximum passing distance.
  for id, distance_m in pairs(inferpassing_m) do
    if newdistances_m[id] == nil and math.abs(distance_m) < maxpassing_m then
      newobjects[id] = self._objects[id]
      newpassing_m[id] = distance_m
    end
  end

  -- Add back objects that are no longer sensed, but have entered the passing
  -- zone.
  for id, distance_m in pairs(inferdistances_m) do
    if newdistances_m[id] == nil and math.abs(distance_m) < maxpassing_m then
      newobjects[id] = self._objects[id]
      newpassing_m[id] = 0
    end
  end

  self._objects = newobjects
  self._distances_m = newdistances_m
  self._passing_m = newpassing_m
end

-- Iterate through all tracked objects by their identifiers.
function P:iterobjects() return pairs(self._objects) end

-- Get a tracked object by identifier.
function P:getobject(id) return self._objects[id] end

-- Iterate through all relative distances by identifier.
function P:iterdistances_m()
  return Iterator.concat({pairs(self._distances_m)}, {
    Iterator.map(function(id, _) return id, 0 end, pairs(self._passing_m))
  })
end

-- Get a relative distance by identifier.
function P:getdistance_m(id)
  if self._passing_m[id] ~= nil then
    return 0
  else
    return self._distances_m[id]
  end
end

return P
