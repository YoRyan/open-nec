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
    _available = {}
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

-- Determine whether the locomotive is powered given the supplied set of
-- activated power supply collectors.
function P:haspower (...)
  return Iterator.hasone(
    function (_, type) return self._available[type] end, ipairs(arg))
end

-- Receive a custom signal message that may or may not indicate a change point.
function P:receivemessage (message)
  local cp = P.getchangepoint(message)
  if cp == P.changepoint.thirdrailstart then
    connect(P.types.thirdrail)
  elseif cp == P.changepoint.thirdrailend then
    disconnect(P.types.thirdrail)
  elseif cp == P.changepoint.overheadstart then
    connect(P.types.overhead)
  elseif cp == P.changepoint.overheadend then
    disconnect(P.types.overhead)
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
    elseif point == "AIOverheadToThirdNow" then
      return P.changepoint.ai_to_thirdrail
    elseif point == "AIThirdToOverheadNow" then
      return P.changepoint.ai_to_overhead
    elseif point == "AIOverheadToDieselNow" then
      return P.changepoint.ai_to_diesel
    elseif point == "AIDieselToOverheadNow" then
      return P.changepoint.ai_to_overhead
    else
      return nil
    end
  else
    return nil
  end
end

return P