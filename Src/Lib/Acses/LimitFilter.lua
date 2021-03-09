-- A speed limits filter that selects posts with valid speeds and with the
-- appropriate speed limit type.
local P = {}
AcsesLimits = P

-- From the main coroutine, create a new speed limit filter context.
function P:new (conf)
  local o = {
    _iterforwardspeedlimits =
      conf.iterforwardspeedlimits or function () return ipairs({}) end,
    _iterbackwardspeedlimits =
      conf.iterbackwardspeedlimits or function () return ipairs({}) end,
    _hastype2limits =
      false
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

local function isvalid (speedlimit)
  return speedlimit.speed_mps < 1e9 and speedlimit.speed_mps > -1e9
end

local function filter (self, iterspeedlimits)
  if not self._hastype2limits then
    -- Default to type 1 limits *unless* we encounter a type 2 (Philadelphia-
    -- New York), at which point we'll search solely for type 2 limits.
    self._hastype2limits = Iterator.hasone(
      function (_, limit) return limit.type == 2 end,
      iterspeedlimits())
  end
  return Iterator.ifilter(
    function (_, limit)
      local righttype
      if self._hastype2limits then
        righttype = limit.type == 2
      else
        righttype = limit.type == 1
      end
      return isvalid(limit) and righttype
    end,
    iterspeedlimits())
end

-- Iterate through forward-facing speed limits.
function P:iterforwardspeedlimits ()
  return filter(self, self._iterforwardspeedlimits)
end

-- Iterate through backward-facing speed limits.
function P:iterbackwardspeedlimits ()
  return filter(self, self._iterbackwardspeedlimits)
end

return P