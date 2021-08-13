-- A speed limits filter that selects posts with valid speeds and with the
-- appropriate speed limit type.
-- @include Iterator.lua
local P = {}
AcsesLimits = P

-- From the main coroutine, create a new speed limit filter context.
function P:new(conf)
  local o = {
    _iterspeedlimits = conf.iterspeedlimits or
      function() return Iterator.empty() end,
    _hastype2limits = false
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

local function isvalid(speedlimit)
  return speedlimit.speed_mps < 1e9 and speedlimit.speed_mps > -1e9
end

-- Iterate through filtered speed limits by distance.
function P:iterspeedlimits()
  if not self._hastype2limits then
    -- Default to type 1 limits *unless* we encounter a type 2 (Philadelphia-
    -- New York), at which point we'll search solely for type 2 limits.
    self._hastype2limits = Iterator.hasone(function(_, limit)
      return limit.type == 2
    end, self._iterspeedlimits())
  end
  return Iterator.filter(function(_, limit)
    local righttype
    if self._hastype2limits then
      righttype = limit.type == 2
    else
      righttype = limit.type == 1
    end
    return isvalid(limit) and righttype
  end, self._iterspeedlimits())
end

return P
