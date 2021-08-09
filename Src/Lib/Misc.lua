-- "Junk drawer" of Lua helper functions.

-- @include Iterator.lua

local P = {}
Misc = P

-- Flash an info (middle of screen) message.
function P.showinfo (title, msg)
  if msg == nil then
    SysCall("ScenarioManager:ShowMessage", "", tostring(title), 0)
  else
    SysCall("ScenarioManager:ShowMessage", title, tostring(msg), 0)
  end
end

-- Flash an alert (top-right corner) message.
function P.showalert (title, msg)
  if msg == nil then
    SysCall("ScenarioManager:ShowMessage", tostring(title), "", 1)
  else
    SysCall("ScenarioManager:ShowMessage", title, tostring(msg), 1)
  end
end

-- Run the provided function and arguments with pcall and report any errors
-- to the player.
function P.catcherrors (...)
  local success, err = pcall(unpack(arg))
  if not success then
    P.showinfo("Lua Error", err)
  end
end

-- Wrap the provided function with a pcall wrapper that reports any errors
-- to the player.
function P.wraperrors (fn)
  return function (...)
    return P.catcherrors(fn, unpack(arg))
  end
end

-- Convert a boolean to an integer value that can be passed to system calls.
function P.intbool (b) return b and 1 or 0 end

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
        RailWorks.GetNextSpeedLimit(direction, minsearch_m)
    else
      type, speed_mps, distance_m =
        RailWorks.GetNextSpeedLimit(direction, minsearch_m, maxdistance_m)
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
        RailWorks.GetNextRestrictiveSignal(direction, minsearch_m)
    else
      found, basicstate, distance_m, prostate =
        RailWorks.GetNextRestrictiveSignal(direction, minsearch_m, maxdistance_m)
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

return P