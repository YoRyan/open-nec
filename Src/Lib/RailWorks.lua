-- Library for interfacing with Train Simulator system calls in a Lua-friendly way.
-- @include Misc.lua
local P = {}
RailWorks = P

--[[
  Script Component
]]

function P.BeginUpdate() Call("BeginUpdate") end

function P.EndUpdate() Call("EndUpdate") end

function P.GetSimulationTime() return Call("GetSimulationTime") end

--[[
  Rail Vehicle Component
]]

function P.GetIsPlayer() return Call("GetIsPlayer") == 1 end

function P.GetSpeed() return Call("GetSpeed") end

function P.GetAcceleration() return Call("GetAcceleration") end

function P.GetConsistLength() return Call("GetConsistLength") end

function P.GetRVNumber() return Call("GetRVNumber") end

function P.Engine_SendConsistMessage(message, argument, direction)
  return Call("SendConsistMessage", message, tostring(argument), direction) == 1
end

function P.GetNextRestrictiveSignal(...)
  return Call("GetNextRestrictiveSignal", unpack(arg))
end

function P.GetNextSpeedLimit(...) return Call("GetNextSpeedLimit", unpack(arg)) end

function P.GetCurrentSpeedLimit(...)
  return Call("GetCurrentSpeedLimit", unpack(arg))
end

--[[
  Render Component
]]

function P.ActivateNode(name, activate)
  Call("ActivateNode", name, Misc.intbool(activate))
end

function P.AddTime(name, time_s) return Call("AddTime", name, time_s) end

function P.SetTime(name, time_s) return Call("SetTime", name, time_s) end

--[[
  Control Container
]]

function P.ControlExists(name, index)
  return Call("ControlExists", name, index) == 1
end

function P.GetControlValue(name, index)
  return Call("GetControlValue", name, index)
end

function P.SetControlValue(name, index, value)
  Call("SetControlValue", name, index, value)
end

function P.GetControlMinimum(name, index)
  return Call("GetControlMinimum", name, index)
end

function P.GetControlMaximum(name, index)
  return Call("GetControlMaximum", name, index)
end

--[[
  Engine
]]

function P.GetTractiveEffort() return Call("GetTractiveEffort") end

function P.GetIsEngineWithKey() return Call("GetIsEngineWithKey") == 1 end

function P.SetPowerProportion(index, value)
  Call("SetPowerProportion", index, value)
end

--[[
  Signal scripting
]]

P.sigmessage = {
  RESET_SIGNAL_STATE = 0,
  INITIALISE_SIGNAL_TO_BLOCKED = 1,
  JUNCTION_STATE_CHANGE = 2,
  INITIALISE_TO_PREPARED = 3,
  REQUEST_TO_PASS_DANGER = 4,
  OCCUPATION_INCREMENT = 10,
  OCCUPATION_DECREMENT = 11,

  SIGMSG_CUSTOM = 15
}

P.sigstate = {clear = 0, warning = 1, blocked = 2}

P.sigprostate = {green = 0, yellow = 1, dblyellow = 2, red = 3}

-- Contrary to the SDK documentation, signals *can* receive messages from their
-- own links. In addition, this function will only work from OnConsistPass or
-- OnSignalMessage.
function P.SendSignalMessage(message, argument, direction, link, index)
  return Call("SendSignalMessage", message, argument, direction, link, index)
end

function P.Signal_SendConsistMessage(message, argument)
  if argument == nil then
    Call("SendConsistMessage", message)
  else
    Call("SendConsistMessage", message, argument)
  end
end

function P.GetConnectedLink(index)
  local link = Call("GetConnectedLink", nil, nil, index)
  if link == -1 then
    return nil
  else
    return link
  end
end

function P.GetLinkCount() return Call("GetLinkCount") end

function P.Set2DMapSignalState(state) Call("Set2DMapSignalState", state) end

function P.Set2DMapProSignalState(state) Call("Set2DMapProSignalState", state) end

--[[
  Undocumented signal functions - see
  https://forums.dovetailgames.com/threads/missing-signaling-functions-in-developer-docs.16740/
]]

function P.GetLinkApproachControl(link)
  return Call("GetLinkApproachControl", link) == 1
end

function P.GetLinkLimitedToYellow(link)
  return Call("GetLinkLimitedToYellow", link) == 1
end

function P.GetLinkFeatherChar(link) return Call("GetLinkFeatherChar", link) end

function P.GetLinkSpeedLimit(link) return Call("GetLinkSpeedLimit", link) end

function P.GetId() return Call("GetId") end

return P
