-- Code for locomotive power-changing functions.
local P = {}
Power = P

P.types = {thirdrail=0, overhead=1}
P.changepoint = {thirdrailstart=0,
                 thirdrailend=1,
                 overheadstart=2,
                 overheadend=3,
                 ai_to_thirdrail=10,
                 ai_to_overhead=11,
                 ai_to_diesel=12}

local function connect (self, type)
  self._available[type] = true
end

local function disconnect (self, type)
  self._available[type] = nil
end

-- From the main coroutine, create a new Power context.
function P:new (conf)
  local o = {
    _available = {},
    _collectors = {}
  }
  -- There's no way to detect the currently available power supplies, so we have
  -- to trust the player or scenario designer to select the right one(s) for the
  -- spawn point.
  for _, type in ipairs(conf.available or {}) do
    connect(o, type)
  end
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Set the current power supply collectors turned on on this locomotive.
function P:setcollectors (...)
  self._collectors = arg
end

-- Determine whether or not a particular power supply is available (regardless of
-- which collectors are currently enabled).
function P:isavailable (type)
  return self._available[type]
end

-- Determine whether the locomotive is powered given the current set of power
-- supply collectors.
function P:haspower ()
  return Iterator.hasone(
    function (_, type) return self._available[type] end, ipairs(self._collectors))
end

-- Receive a custom signal message that may or may not indicate a change point.
function P:receivemessage (message)
  local cp = P.getchangepoint(message)
  if cp == P.changepoint.thirdrailstart then
    connect(self, P.types.thirdrail)
  elseif cp == P.changepoint.thirdrailend then
    disconnect(self, P.types.thirdrail)
  elseif cp == P.changepoint.overheadstart then
    connect(self, P.types.overhead)
  elseif cp == P.changepoint.overheadend then
    disconnect(self, P.types.overhead)
  end
end

-- Get the change point type that corresponds to a signal message. If nil, then
-- the message is of an unknown format.
function P.getchangepoint (message)
  if string.sub(message, 1, 1) == "P" then
    local point = string.sub(message, 3)
    if point == "OverheadStart" then
      return P.changepoint.overheadstart
    elseif point == "OverheadEnd" then
      return P.changepoint.overheadend
    elseif point == "ThirdRailStart" then
      return P.changepoint.thirdrailstart
    elseif point == "ThirdRailEnd" then
      return P.changepoint.thirdrailend
    -- New York to New Haven AI change points
    elseif point == "AIOverheadToThirdNow" then
      return P.changepoint.ai_to_thirdrail
    elseif point == "AIThirdToOverheadNow" then
      return P.changepoint.ai_to_overhead
    -- North Jersey Coast Line AI change points
    elseif point == "AIOverheadToDieselNow" then
      return P.changepoint.ai_to_diesel
    elseif point == "AIDieselToOverheadNow" then
      return P.changepoint.ai_to_overhead
    -- Hudson Line end of third rail
    elseif point == "DieselRailStart" then
      return P.changepoint.thirdrailend
    else
      return nil
    end
  else
    return nil
  end
end

return P