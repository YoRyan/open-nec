-- Code for locomotive power-changing functions.

Power = {}
Power.__index = Power

Power.changepoint = {thirdrailstart="ThirdRailStart",
                     thirdrailend="ThirdRailEnd",
                     overheadstart="OverheadStart",
                     overheadend="OverheadEnd",
                     ai_to_thirdrail="AIToThirdRail",
                     ai_to_overhead="AIToOverhead"}

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