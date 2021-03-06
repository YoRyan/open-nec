-- Library for interfacing with Train Simulator system calls in a Lua-friendly way.

RailWorks = {}
RailWorks.__index = RailWorks

-- Flash an info (middle of screen) message.
function RailWorks.showinfo(msg)
  SysCall("ScenarioManager:ShowMessage", "", tostring(msg), 0)
end

-- Flash an alert (top-right corner) message.
function RailWorks.showalert(msg)
  SysCall("ScenarioManager:ShowMessage", tostring(msg), "", 1)
end

-- Run the provided function and arguments with pcall and report any errors
-- to the player.
function RailWorks.catcherrors(...)
  local success, err = pcall(unpack(arg))
  if not success then
    RailWorks.showinfo("ERROR:\n" .. err)
  end
end

-- Wrap the provided function with a pcall wrapper that reports any errors
-- to the player.
function RailWorks.wraperrors(fn)
  return function (...)
    return RailWorks.catcherrors(fn, unpack(arg))
  end
end

-- Convert a boolean to an integer value that can be passed to SetControlValue().
function RailWorks.frombool(b)
  if b then
    return 1
  else
    return 0
  end
end

-- Iterate through up to n upcoming speed posts, with an optional maximum
-- lookahead distance.
-- Speed limits are in the form of {{type=..., speed_mps=..., distance_m=...}, ...}
function RailWorks.iterforwardspeedlimits(n, maxdistance_m)
  return RailWorks._iterspeedlimits(0, n, maxdistance_m)
end

-- Iterate through up to n backward-facing speed posts, with an optional maximum
-- lookbehind distance.
-- Speed limits are in the form of {{type=..., speed_mps=..., distance_m=...}, ...}
function RailWorks.iterbackwardspeedlimits(n, maxdistance_m)
  return RailWorks._iterspeedlimits(1, n, maxdistance_m)
end

function RailWorks._iterspeedlimits(direction, n, maxdistance_m)
  local i = 0
  local minsearch_m = 0
  return function ()
    i = i + 1
    if i > n then
      return nil, nil
    end
    local type, speed_mps, distance_m
    if maxdistance_m == nil then
      type, speed_mps, distance_m =
        RailWorks.GetNextSpeedLimit(direction, minsearch_m)
    else
      type, speed_mps, distance_m =
        RailWorks.GetNextSpeedLimit(direction, minsearch_m, maxdistance_m)
    end
    if type == 1 or type == 2 or type == 3 then
      minsearch_m = distance_m + 0.01
      return i, {type=type, speed_mps=speed_mps, distance_m=distance_m}
    else
      return nil, nil
    end
  end, nil, nil
end

-- Iterate through up to n upcoming restrictive signals, with an optional maximum
-- lookahead distance.
-- Signals are in the form of {{basicstate=..., prostate=..., distance_m=...}, ...}
function RailWorks.iterforwardrestrictsignals(n, maxdistance_m)
  return RailWorks._iterrestrictsignals(0, n, maxdistance_m)
end

-- Iterate through up to n backward-facing restrictive signals, with an optional
-- maximum lookahead distance.
-- Signals are in the form of {{basicstate=..., prostate=..., distance_m=...}, ...}
function RailWorks.iterbackwardrestrictsignals(n, maxdistance_m)
  return RailWorks._iterrestrictsignals(1, n, maxdistance_m)
end

function RailWorks._iterrestrictsignals(direction, n, maxdistance_m)
  local i = 0
  local minsearch_m = 0
  return function ()
    i = i + 1
    if i > n then
      return nil, nil
    end
    local found, basicstate, distance_m, prostate
    if maxdistance_m == nil then
      found, basicstate, distance_m, prostate =
        RailWorks.GetNextRestrictiveSignal(direction, minsearch_m)
    else
      found, basicstate, distance_m, prostate =
        RailWorks.GetNextRestrictiveSignal(direction, minsearch_m, maxdistance_m)
    end
    if found > 0 then
      minsearch_m = distance_m + 0.01
      return i, {basicstate=basicstate, distance_m=distance_m, prostate=prostate}
    else
      return nil, nil
    end
  end, nil, nil
end

function RailWorks.BeginUpdate()
  Call("BeginUpdate")
end

function RailWorks.EndUpdate()
  Call("EndUpdate")
end

function RailWorks.GetSimulationTime()
  return Call("GetSimulationTime")
end

function RailWorks.GetIsPlayer()
  return Call("GetIsPlayer") == 1
end

function RailWorks.GetIsEngineWithKey()
  return Call("GetIsEngineWithKey") == 1
end

function RailWorks.GetControlValue(name, index)
  return Call("GetControlValue", name, index)
end

function RailWorks.SetControlValue(name, index, value)
  Call("SetControlValue", name, index, value)
end

function RailWorks.GetSpeed()
  return Call("GetSpeed")
end

function RailWorks.GetAcceleration()
  return Call("GetAcceleration")
end

function RailWorks.GetCurrentSpeedLimit(...)
  return Call("GetCurrentSpeedLimit", unpack(arg))
end

function RailWorks.GetNextSpeedLimit(...)
  return Call("GetNextSpeedLimit", unpack(arg))
end

function RailWorks.GetNextRestrictiveSignal(...)
  return Call("GetNextRestrictiveSignal", unpack(arg))
end