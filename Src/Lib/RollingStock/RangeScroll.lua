-- A discrete scroller from 1 to <max> controlled by an up/down input signal.
local P = {}
RangeScroll = P

-- Specifies the scroller's current direction.
P.direction = {previous = 0, neutral = 1, next = 2}

local function scrollprevious(self, start_s)
  local event
  repeat
    self._selected = math.max(self._selected - 1, 1)
    event = self._sched:select(self._move_s, function()
      return self._getdirection() ~= P.direction.previous
    end)
  until event == 1
end

local function scrollnext(self, start_s)
  local event
  repeat
    self._selected = math.min(self._selected + 1, self._limit)
    event = self._sched:select(self._move_s, function()
      return self._getdirection() ~= P.direction.next
    end)
  until event == 1
end

local function run(self)
  while true do
    local event = self._sched:select(nil, function()
      return self._getdirection() == P.direction.previous
    end, function() return self._getdirection() == P.direction.next end)
    if event == 1 then
      scrollprevious(self, self._sched:clock())
    elseif event == 2 then
      scrollnext(self, self._sched:clock())
    end
  end
end

-- From the main coroutine, create a new RangeScroll context. This will add a
-- coroutine to the provided scheduler.
function P:new(conf)
  local o = {
    _sched = conf.scheduler,
    _getdirection = conf.getdirection or
      function() return P.direction.neutral end,
    _limit = conf.limit or 1,
    _move_s = conf.move_s or 1,
    _selected = conf.selected or 1
  }
  setmetatable(o, self)
  self.__index = self
  o._sched:run(run, o)
  return o
end

-- Returns the currently selected number.
function P:getselected() return self._selected end

return P
