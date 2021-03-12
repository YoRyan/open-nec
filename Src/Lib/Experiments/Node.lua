-- Continuously hide and display a model node.
local P = {}
NodeExperiment = P

local onoff_s = 1

-- From the main coroutine, create a new NodeExperiment context.
function P:new (conf)
  local sched = conf.scheduler
  local o = {
    _sched = sched,
    _node = conf.node,
    _lasttime = sched:clock(),
    _show = true
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- From the main coroutine, update this experiment.
function P:update ()
  local time = self._sched:clock()
  if time - onoff_s >= self._lasttime then
    self._lasttime = time
    self._show = not self._show
    RailWorks.ActivateNode(self._node, self._show)
  end
end