-- Library for interfacing with Train Simulator system calls in a Lua-friendly way.

RailWorks = {}
RailWorks.__index = RailWorks

function RailWorks.showMessage(msg)
  SysCall("ScenarioManager:ShowMessage", tostring(msg), "", 1)
end

-- Run the provided function and arguments with pcall and report any errors
-- to the player.
function RailWorks.catchErrors(...)
  success, err = pcall(unpack(arg))
  if not success then
    RailWorks.showMessage("ERROR:\n" .. err)
  end
end

-- Wrap the provided function with a pcall wrapper that reports any errors
-- to the player.
function RailWorks.wrapErrors(fn)
  return function (...)
    return RailWorks.catchErrors(fn, unpack(arg))
  end
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