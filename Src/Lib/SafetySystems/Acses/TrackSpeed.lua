-- A speed post tracker that calculates the speed limit in force at the
-- player's location, irrespective of train length.
--
-- @include YoRyan/LibRailWorks/RailWorks.lua
local P = {}
AcsesTrackSpeed = P

-- Create a new speed post tracker context.
function P:new(conf)
  local o = {
    _limittracker = conf.speedlimittracker,
    _before_mps = {},
    _after_mps = {},
    _sensedspeed_mps = nil
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Update this system once every frame.
function P:update(dt)
  local newbefore_mps = {}
  local newafter_mps = {}
  for id, distance_m in self._limittracker:iterdistances_m() do
    local limit = self._limittracker:getobject(id)
    if distance_m >= 0 then
      newbefore_mps[id] = self._before_mps[id]
      newafter_mps[id] = limit.speed_mps
    elseif distance_m <= 0 then
      newbefore_mps[id] = limit.speed_mps
      newafter_mps[id] = self._after_mps[id]
    else
      newbefore_mps[id] = self._before_mps[id]
      newafter_mps[id] = self._after_mps[id]
    end
  end
  self._before_mps = newbefore_mps
  self._after_mps = newafter_mps

  local lastid = Iterator.max(Iterator.ltcomp,
                              Iterator.filter(
                                function(_, distance_m) return distance_m < 0 end,
                                self._limittracker:iterdistances_m()))
  local nextid = Iterator.min(Iterator.ltcomp,
                              Iterator.filter(
                                function(_, distance_m) return distance_m > 0 end,
                                self._limittracker:iterdistances_m()))
  -- Retain the deduced speed limit even if the original speed post is more
  -- than 10km away.
  local sensed_mps = self._after_mps[lastid] or self._before_mps[nextid] or
                       self._sensedspeed_mps
  local gamespeed_mps = RailWorks.GetCurrentSpeedLimit(1)
  if sensed_mps == nil then
    self._sensedspeed_mps = gamespeed_mps
    -- The game-calculated speed limit is strictly lower than the track
    -- speed limit we want, so if that is higher, then we should use it.
  elseif gamespeed_mps > sensed_mps then
    self._sensedspeed_mps = gamespeed_mps
    -- If the previous speed post is behind the end of our train, then we
    -- can use the game-calculated speed limit.
  elseif lastid ~= nil and -self._limittracker:getdistance_m(lastid) >
    RailWorks.GetConsistLength() then
    self._sensedspeed_mps = gamespeed_mps
  else
    self._sensedspeed_mps = sensed_mps
  end
end

-- Get the current sensed track speed.
function P:gettrackspeed_mps() return self._sensedspeed_mps end

return P
