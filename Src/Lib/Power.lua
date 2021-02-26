-- Code for locomotive power-changing functions.

Power = {}
Power.__index = Power

Power.types = {thirdrail=0,
               overhead=1}
Power.changepoint = {thirdrailstart="ThirdRailStart",
                     thirdrailend="ThirdRailEnd",
                     overheadstart="OverheadStart",
                     overheadend="OverheadEnd",
                     ai_to_thirdrail="AIToThirdRail",
                     ai_to_overhead="AIToOverhead"}

-- From the main coroutine, create a new Power context. Arguments are the
-- currently available power supply types (third rail, overhead...).
function Power.new(...)
  local self = setmetatable({}, Power)
  -- There's no way to detect the currently available power supplies, so we have
  -- to trust the player or scenario designer to select the right one(s) for the
  -- spawn point.
  self._available = {}
  for _, type in ipairs(arg) do
    self._available[type] = true
  end
  return self
end

-- Determine whether the locomotive is powered given the supplied set of
-- activated power supply collectors.
function Power.haspower(self, ...)
  for _, type in ipairs(arg) do
    if self._available[type] then
      return true
    end
  end
  return false
end

-- Receive a custom signal message that may or may not indicate a change point.
function Power.receivemessage(self, message)
  local cp = Power.getchangepoint(message)
  if cp == Power.changepoint.thirdrailstart then
    self._available[Power.types.thirdrail] = true
  elseif cp == Power.changepoint.thirdrailend then
    self._available[Power.types.thirdrail] = nil
  elseif cp == Power.changepoint.overheadstart then
    self._available[Power.types.overhead] = true
  elseif cp == Power.changepoint.overheadend then
    self._available[Power.types.overhead] = nil
  end
end

-- Get the change point type that corresponds to a signal message. If nil, then
-- the message is of an unknown format.
function Power.getchangepoint(message)
  if string.sub(message, 1, 1) == "P" then
    local point = string.sub(message, 3)
    if point == "OverheadStart" then
      return Power.changepoint.overheadstart
    elseif point == "OverheadEnd" then
      return Power.changepoint.overheadend
    elseif point == "ThirdRailStart" then
      return Power.changepoint.thirdrailstart
    elseif point == "ThirdRailEnd" then
      return Power.changepoint.thirdrailend
    elseif point == "AIOverheadToThirdNow" then
      return Power.changepoint.ai_to_thirdrail
    elseif point == "AIThirdToOverheadNow" then
      return Power.changepoint.ai_to_overhead
    else
      return nil
    end
  else
    return nil
  end
end