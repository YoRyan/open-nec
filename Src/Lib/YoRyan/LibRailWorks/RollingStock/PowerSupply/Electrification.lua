-- Class for tracking the presence of lineside 3rd rail/catenary, and for
-- processing invisible change point signal messages.
--
-- These messages are only received by the locomotive in control of the entire
-- train. Therefore, even cab cars need to use this class, so that helper
-- locomotives can be made aware of the current electrification state.
--
-- This state is normally transmitted via controls that are synchronized
-- across the entire consist. However, if these controls are unavailable,
-- then a Lua dictionary (which won't be synced) can also be used.
--
-- @include YoRyan/LibRailWorks/Misc.lua
-- @include YoRyan/LibRailWorks/RailWorks.lua
local P = {}
Electrification = P

P.type = {thirdrail = 0, overhead = 1}
P.endchangepoint = {start = 0, stop = 1}
P.autochangepoint = {ai_to_thirdrail = 0, ai_to_overhead = 1, ai_to_diesel = 2}

local controlmap = {
  [P.type.thirdrail] = "Power3rdRail",
  [P.type.overhead] = "PowerOverhead"
}

-- Create a new Electrification context.
function P:new(conf)
  local o = {
    -- maps electrification type to status control
    _controlmap = conf.controlmap or controlmap,
    -- executes at an electrification start/stop change point
    _onendchangepoint = conf.onendchangepoint or function(type, status) end,
    -- executes at an AI automatic change point
    _onautochangepoint = conf.onautochangepoint or function(cp) end,
    -- memory-backed dictionary to be used if status controls are not available
    _luaavailable = {}
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Check for the presence of a type of electrification.
function P:isavailable(type)
  local control = self._controlmap[type]
  if control == nil then
    return
  elseif RailWorks.ControlExists(control, 0) then
    return RailWorks.GetControlValue(control, 0) == 1
  else
    return self._luaavailable[type]
  end
end

-- Set the presence of a type of electrification.
function P:setavailable(type, present)
  local control = self._controlmap[type]
  if control == nil then
    return
  elseif RailWorks.ControlExists(control, 0) then
    RailWorks.SetControlValue(control, 0, Misc.intbool(present))
  else
    self._luaavailable[type] = present and true or nil
  end
end

local function readendcp(self, type, status)
  local change = false
  if status == P.endchangepoint.start then
    change = not self:isavailable(type)
    self:setavailable(type, true)
  elseif status == P.endchangepoint.stop then
    change = self:isavailable(type)
    self:setavailable(type, false)
  end
  -- Fire the callback if warranted.
  if change then self._onendchangepoint(type, status) end
end

local function readautocp(self, cp) self._onautochangepoint(cp) end

-- Receive a custom signal message and, if it is a power change point, process it.
function P:receivemessage(message)
  local _, _, point = string.find(message, "P%-(%a+)")

  if point == "OverheadStart" then
    readendcp(self, P.type.overhead, P.endchangepoint.start)
  elseif point == "OverheadEnd" then
    readendcp(self, P.type.overhead, P.endchangepoint.stop)
  elseif point == "ThirdRailStart" then
    readendcp(self, P.type.thirdrail, P.endchangepoint.start)
  elseif point == "ThirdRailEnd" or point == "DieselRailStart" then
    readendcp(self, P.type.thirdrail, P.endchangepoint.stop)

    -- New York to New Haven AI change points
  elseif point == "AIOverheadToThirdNow" then
    readautocp(self, P.autochangepoint.ai_to_thirdrail)
  elseif point == "AIThirdToOverheadNow" then
    readautocp(self, P.autochangepoint.ai_to_overhead)

    -- North Jersey Coast Line AI change points
  elseif point == "AIOverheadToDieselNow" then
    readautocp(self, P.autochangepoint.ai_to_diesel)
  elseif point == "AIDieselToOverheadNow" then
    readautocp(self, P.autochangepoint.ai_to_overhead)
  end
end

return P
