-- Library for interfacing with Train Simulator system calls in a Lua-friendly way.

RailWorks = {}
RailWorks.__index = RailWorks

function RailWorks.showmessage(msg)
  SysCall("ScenarioManager:ShowMessage", tostring(msg), "", 1)
end

-- Run the provided function and arguments with pcall and report any errors
-- to the player.
function RailWorks.catcherrors(...)
  success, err = pcall(unpack(arg))
  if not success then
    RailWorks.showmessage("ERROR:\n" .. err)
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
function RailWorks.getforwardspeedlimits(n, maxdistance_m)
  return RailWorks._getspeedlimits(0, n, maxdistance_m)
end

-- Iterate through up to n backward-facing speed posts, with an optional maximum
-- lookbehind distance.
function RailWorks.getbackwardspeedlimits(n, maxdistance_m)
  return RailWorks._getspeedlimits(1, n, maxdistance_m)
end

function RailWorks._getspeedlimits(direction, n, maxdistance_m)
  local i = 0
  local minsearch_m = 0
  return function (_, _)
    if i >= n then
      return nil, nil
    end
    i = i + 1
    local found, speed_mps, distance_m =
      RailWorks.GetNextSpeedLimit(direction, minsearch_m, maxdistance_m)
    if found == 1 or found == 3 then
      minsearch_m = minsearch_m + distance_m + 0.01
      return speed_mps, distance_m
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

function RailWorks.GetCurrentSpeedLimit(component)
  return Call("GetCurrentSpeedLimit", component)
end

function RailWorks.GetNextSpeedLimit(direction, minDistance, maxDistance)
  return Call("GetNextSpeedLimit", direction, minDistance, maxDistance)
end