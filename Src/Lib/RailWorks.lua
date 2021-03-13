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

local function negatedistance (distance_m, obj) return -distance_m, obj end

local function speedlimitsbydistance (direction, n, maxdistance_m)
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
      return distance_m, {type=type, speed_mps=speed_mps}
    else
      return nil, nil
    end
  end, nil, nil
end

-- Iterate through up to n speed posts in both directions, with an optional
-- maximum lookahead/lookbehind distance. Speed limits are in the form of
-- {type=..., speed_mps=...} and the key is the distance in m.
function P.iterspeedlimits (n, maxdistance_m)
  return Iterator.concat(
    {Iterator.map(negatedistance, speedlimitsbydistance(1, n, maxdistance_m))},
    {speedlimitsbydistance(0, n, maxdistance_m)})
end

local function restrictsignalsbydistance (direction, n, maxdistance_m)
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
      return distance_m, {basicstate=basicstate, prostate=prostate}
    else
      return nil, nil
    end
  end, nil, nil
end

-- Iterate through up to n restrictive signals in both directions, with an
-- optional maximum lookahead/lookbehind distance. Signals are in the form
-- of {basicstate=..., prostate=...} and the key is the distance in m.
function P.iterrestrictsignals (n, maxdistance_m)
  return Iterator.concat(
    {Iterator.map(negatedistance, restrictsignalsbydistance(1, n, maxdistance_m))},
    {restrictsignalsbydistance(0, n, maxdistance_m)})
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

function P.ActivateNode (name, activate)
  Call("ActivateNode", name, P.frombool(activate))
end

function P.AddTime (name, time_s)
  return Call("AddTime", name, time_s)
end

function P.SetTime (name, time_s)
  return Call("SetTime", name, time_s)
end

function P.SendConsistMessage (message, argument, direction)
  return Call("SendConsistMessage", message, argument, direction) == 1
end

return P