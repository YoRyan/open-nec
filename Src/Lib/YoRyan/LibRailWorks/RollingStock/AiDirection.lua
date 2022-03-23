-- Class that tracks the current moving direction for AI locomotives. This is
-- useful for controlling Lua-driven headlights and taillights. A locomotive
-- moving backwards could be reversing--or it could be reversed in the consist.
--
-- @include YoRyan/LibRailWorks/Misc.lua
-- @include YoRyan/LibRailWorks/RailWorks.lua
local P = {}
AiDirection = P

P.direction = {forward = 1, reverse = 2, unknown = 3}

-- Create a new AiDirection context.
function P:new(conf)
  local o = {_direction = P.direction.unknown}
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Update this module every frame.
function P:aiupdate(_)
  local speed_mps = RailWorks.GetSpeed()
  if speed_mps > Misc.stopped_mps then
    self._direction = P.direction.forward
  elseif speed_mps < -Misc.stopped_mps then
    self._direction = P.direction.reverse
  end
end

-- Get the current sensed direction.
function P:getdirection() return self._direction end

return P
