-- A discrete scroller from 1 to <max> controlled by an up/down input signal.
local P = {}
RangeScroll = P

-- Specifies the scroller's current direction.
P.direction = {previous = 0, neutral = 1, next = 2}

-- Create a new RangeScroll context.
function P:new(conf)
  local o = {
    _getdirection = conf.getdirection or
      function() return P.direction.neutral end,
    _onchange = conf.onchange or function(v) end,
    _lastdirection = P.direction.neutral,
    _lastchange_s = 0,
    _limit = conf.limit or 1,
    _move_s = conf.move_s or 1,
    _selected = conf.selected or 1
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Update this system once every frame.
function P:update(_)
  local now = RailWorks.GetSimulationTime()
  local direction = self._getdirection()
  local changed = direction ~= self._lastdirection
  local helddown = now - self._lastchange_s >= self._move_s
  if changed or helddown then
    local next
    if direction == P.direction.next then
      next = math.min(self._selected + 1, self._limit)
    elseif direction == P.direction.previous then
      next = math.max(self._selected - 1, 1)
    else
      next = self._selected
    end
    if next ~= self._selected then
      self._onchange(next)
      self._selected = next
    end
    self._lastdirection = direction
    self._lastchange_s = now
  end
end

-- Returns the currently selected number.
function P:getselected() return self._selected end

return P
