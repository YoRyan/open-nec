-- Continuously hide and display a model node.
--
-- @include Misc.lua
-- @include RailWorks.lua
local P = {}
NodeExperiment = P

local onoff_s = 1

-- Create a new NodeExperiment context.
function P:new(conf)
  local o = {
    _node = conf.node,
    _lasttime = RailWorks.GetSimulationTime(),
    _show = true
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Update this experiment.
function P:update()
  local time = RailWorks.GetSimulationTime()
  if time - onoff_s >= self._lasttime then
    self._lasttime = time
    self._show = not self._show
    RailWorks.ActivateNode(self._node, self._show)
  end
end

return P
