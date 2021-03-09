-- Library for interfacing with Train Simulator system calls in a Lua-friendly way.
local P = {}
RailWorks = P

-- Flash an info (middle of screen) message.
function P.showinfo (msg)
  SysCall("ScenarioManager:ShowMessage", "", tostring(msg), 0)
end

-- Flash an alert (top-right corner) message.
function P.showalert (msg)
  SysCall("ScenarioManager:ShowMessage", tostring(msg), "", 1)
end

-- Run the provided function and arguments with pcall and report any errors
-- to the player.
function P.catcherrors (...)
  local success, err = pcall(unpack(arg))
  if not success then
    P.showinfo("ERROR:\n" .. err)
  end
end

-- Wrap the provided function with a pcall wrapper that reports any errors
-- to the player.
function P.wraperrors (fn)
  return function (...)
    return P.catcherrors(fn, unpack(arg))
  end
end

-- Convert a boolean to an integer value that can be passed to SetControlValue().
function P.frombool (b)
  if b then
    return 1
  else
    return 0
  end
end

local function iterspeedlimits (direction, n, maxdistance_m)
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
        P.GetNextSpeedLimit(direction, minsearch_m)
    else
      type, speed_mps, distance_m =
        P.GetNextSpeedLimit(direction, minsearch_m, maxdistance_m)
    end
    if type == 1 or type == 2 or type == 3 then
      minsearch_m = distance_m + 0.01
      return i, {type=type, speed_mps=speed_mps, distance_m=distance_m}
    else
      return nil, nil
    end
  end, nil, nil
end

-- Iterate through up to n upcoming speed posts, with an optional maximum
-- lookahead distance.
-- Speed limits are in the form of {{type=..., speed_mps=..., distance_m=...}, ...}
function P.iterforwardspeedlimits (n, maxdistance_m)
  return iterspeedlimits(0, n, maxdistance_m)
end

-- Iterate through up to n backward-facing speed posts, with an optional maximum
-- lookbehind distance.
-- Speed limits are in the form of {{type=..., speed_mps=..., distance_m=...}, ...}
function P.iterbackwardspeedlimits (n, maxdistance_m)
  return iterspeedlimits(1, n, maxdistance_m)
end

local function iterrestrictsignals (direction, n, maxdistance_m)
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
        P.GetNextRestrictiveSignal(direction, minsearch_m)
    else
      found, basicstate, distance_m, prostate =
        P.GetNextRestrictiveSignal(direction, minsearch_m, maxdistance_m)
    end
    if found > 0 then
      minsearch_m = distance_m + 0.01
      return i, {basicstate=basicstate, distance_m=distance_m, prostate=prostate}
    else
      return nil, nil
    end
  end, nil, nil
end

-- Iterate through up to n upcoming restrictive signals, with an optional maximum
-- lookahead distance.
-- Signals are in the form of {{basicstate=..., prostate=..., distance_m=...}, ...}
function P.iterforwardrestrictsignals (n, maxdistance_m)
  return iterrestrictsignals(0, n, maxdistance_m)
end

-- Iterate through up to n backward-facing restrictive signals, with an optional
-- maximum lookahead distance.
-- Signals are in the form of {{basicstate=..., prostate=..., distance_m=...}, ...}
function P.iterbackwardrestrictsignals (n, maxdistance_m)
  return iterrestrictsignals(1, n, maxdistance_m)
end

function P.BeginUpdate ()
  Call("BeginUpdate")
end

function P.EndUpdate ()
  Call("EndUpdate")
end

function P.GetSimulationTime ()
  return Call("GetSimulationTime")
end

function P.GetIsPlayer ()
  return Call("GetIsPlayer") == 1
end

function P.GetIsEngineWithKey ()
  return Call("GetIsEngineWithKey") == 1
end

function P.GetControlValue (name, index)
  return Call("GetControlValue", name, index)
end

function P.SetControlValue (name, index, value)
  Call("SetControlValue", name, index, value)
end

function P.GetSpeed ()
  return Call("GetSpeed")
end

function P.GetAcceleration ()
  return Call("GetAcceleration")
end

function P.GetCurrentSpeedLimit (...)
  return Call("GetCurrentSpeedLimit", unpack(arg))
end

function P.GetNextSpeedLimit (...)
  return Call("GetNextSpeedLimit", unpack(arg))
end

function P.GetNextRestrictiveSignal (...)
  return Call("GetNextRestrictiveSignal", unpack(arg))
end

return P