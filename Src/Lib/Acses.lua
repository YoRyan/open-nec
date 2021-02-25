-- Constants, lookup tables, and code for Amtrak's Advanced Civil Speed
-- Enforcement System.

Acses = {}
Acses.__index = Acses

Acses.debuglimits = false
Acses.nlimitlookahead = 5

-- From the main coroutine, create a new Acses context. This will add coroutines
-- to the provided scheduler. The caller should also customize the properties
-- in the config table initialized here.
function Acses.new(scheduler)
  local self = setmetatable({}, Acses)
  self.config = {
    getspeed_mps=function () return 0 end,
    gettrackspeed_mps=function () return 0 end,
    getforwardspeedlimits=function () return {} end,
    getbackwardspeedlimits=function () return {} end,
    getacknowledge=function () return false end,
    doalert=function () end,
    penaltylimit_mps=3*Units.mph.tomps,
    alertlimit_mps=1*Units.mph.tomps,
    -- -1.3 mph/s
    penaltycurve_mps2=-1.3*Units.mph.tomps,
    alertcurve_s=8
  }
  self.state = {
    -- The current track speed in force. In the alert and penalty states, this
    -- communicates the limit that was violated.
    inforcespeed_mps=0,
    -- The current track speed in force, taking into account the advance alert
    -- and penalty braking curves. This value "counts down" to an approaching
    -- speed limit.
    curvespeed_mps=0,
    -- True when the alarm is sounding continuously.
    alarm=false,
    -- True when a penalty brake is applied.
    penalty=false,

    _violation=nil,
    _enforcingspeed_mps=nil
  }
  do
    local newtrackspeed = AcsesTrackSpeed.new(scheduler)
    local config = newtrackspeed.config
    config.gettrackspeed_mps =
      function () return self.config.gettrackspeed_mps() end
    config.getforwardspeedlimits =
      function () return self.config.getforwardspeedlimits() end
    config.getbackwardspeedlimits =
      function () return self.config.getforwardspeedlimits() end
    self.trackspeed = newtrackspeed
  end
  self._sched = scheduler
  self._sched:run(Acses._setstate, self)
  self._sched:run(Acses._doenforce, self)
  return self
end

function Acses._setstate(self)
  while true do
    if self.state._enforcingspeed_mps ~= nil then
      self.state.inforcespeed_mps = self.state._enforcingspeed_mps
    else
      local newspeed_mps = self.trackspeed.state.speedlimit_mps
      if newspeed_mps ~= self.state.inforcespeed_mps then
        self.config.doalert()
      end
      self.state.inforcespeed_mps = newspeed_mps
    end
    do
      local curves = self:_getbrakecurves()
      self.state.curvespeed_mps = Acses._getcurvespeed(curves)
      self.state._violation = self:_getviolation(curves)
    end
    if Acses.debuglimits and self.config.getacknowledge() then
      self:_printlimits()
    end
    self._sched:yield()
  end
end

function Acses._getbrakecurves(self)
  local curves = {self:_gettrackspeedcurves()}
  for _, limit in ipairs(self:_getupcomingspeedlimits()) do
    table.insert(curves, self:_getspeedlimitcurves(limit))
  end
  return curves
end

function Acses._gettrackspeedcurves(self)
  local limit_mps = self.trackspeed.state.speedlimit_mps
  return {
    limit_mps=limit_mps,
    penalty_mps=limit_mps + self.config.penaltylimit_mps,
    alert_mps=limit_mps + self.config.alertlimit_mps,
    curve_mps=limit_mps
  }
end

function Acses._getspeedlimitcurves(self, speedlimit)
  local calcspeed = function(vf, t)
    local a = self.config.penaltycurve_mps2
    local d = speedlimit.distance_m
    return math.pow(math.pow(a*t, 2) - 2*a*d + math.pow(vf, 2), 0.5) + a*t
  end
  return {
    limit_mps=speedlimit.speed_mps,
    penalty_mps=calcspeed(
      speedlimit.speed_mps + self.config.penaltylimit_mps, 0),
    alert_mps=calcspeed(
      speedlimit.speed_mps + self.config.alertlimit_mps, self.config.alertcurve_s),
    curve_mps=calcspeed(
      speedlimit.speed_mps, self.config.alertcurve_s),
  }
end

function Acses._getcurvespeed(brakecurves)
  local speed_mps = nil
  for _, t in ipairs(brakecurves) do
    if speed_mps == nil then
      speed_mps = t.curve_mps
    elseif t.curve_mps < speed_mps then
      speed_mps = t.curve_mps
    end
  end
  return speed_mps
end

function Acses._getviolation(self, brakecurves)
  local aspeed_mps = math.abs(self.config.getspeed_mps())
  local violation = nil
  for _, t in ipairs(brakecurves) do
    if aspeed_mps > t.penalty_mps then
      violation = {type="penalty", limit_mps=t.limit_mps}
      break
    elseif aspeed_mps > t.alert_mps then
      violation = {type="alert", limit_mps=t.limit_mps}
      break
    end
  end
  return violation
end

function Acses._printlimits(self)
  local fspeed = function (mps)
    return string.format("%.2f", mps*Units.mps.tomph) .. "mph"
  end
  local fdist = function (m)
    return string.format("%.2f", m*Units.m.toft) .. "ft"
  end
  local dump = function (limits)
    local res = ""
    for _, limit in ipairs(limits) do
      local s = "type=" .. limit.type
        .. ", speed=" .. fspeed(limit.speed_mps)
        .. ", distance=" .. fdist(limit.distance_m)
      res = res .. s .. "\n"
    end
    return res
  end
  self._sched:print("Track: " .. fspeed(self.config.gettrackspeed_mps()) .. " "
    .. "Sensed: " .. fspeed(self.trackspeed.state.speedlimit_mps) .. "\n"
    .. "Forward: " .. dump(self.config.getforwardspeedlimits())
    .. "Backward: " .. dump(self.config.getbackwardspeedlimits()))
end

function Acses._doenforce(self)
  while true do
    self._sched:select(nil, function () return self.state._violation ~= nil end)
    self:_alert(self.state._violation)
  end
end

function Acses._alert(self, violation)
  self.state._enforcingspeed_mps = self.state._violation.limit_mps
  self.state.alarm = true
  local curviolation, reachedlimit, stopped
  local acknowledged = false
  repeat
    acknowledged = acknowledged or self.config.getacknowledge()
    if acknowledged then
      self.state.alarm = false
    end
    curviolation = self.state._violation
    if curviolation ~= nil and curviolation.type == "penalty" then
      self:_penalty(curviolation)
      -- You have to have acknowledged to have left the penalty state.
      acknowledged = true
    end
    reachedlimit = self.config.gettrackspeed_mps() == violation.limit_mps
      or not Tables.find(self:_getupcomingspeedlimits(), function (limit)
        return limit.speed_mps == violation.limit_mps
      end)
    stopped = math.abs(self.config.getspeed_mps()) <= 1*Units.mph.tomps
    self._sched:yield()
  until curviolation == nil and acknowledged and (reachedlimit or stopped)
  self.state._enforcingspeed_mps = nil
  self.state.alarm = false
end

function Acses._penalty(self, violation)
  self.state.penalty = true
  self._sched:select(nil, function ()
    return math.abs(self.config.getspeed_mps()) <= violation.limit_mps
      and self.config.getacknowledge()
  end)
  self.state.penalty = false
end

function Acses._getupcomingspeedlimits(self)
  if self.config.getspeed_mps() >= 0 then
    return self.config.getforwardspeedlimits()
  else
    return self.config.getbackwardspeedlimits()
  end
end


-- A speed post tracker that calculates the speed limit in force at the
-- player's location, irrespective of train length.
AcsesTrackSpeed = {}
AcsesTrackSpeed.__index = AcsesTrackSpeed

-- From the main coroutine, create a new speed post tracker context. This will
-- add coroutines to the provided scheduler. The caller should also customize
-- the properties in the config table initialized here.
function AcsesTrackSpeed.new(scheduler)
  local self = setmetatable({}, AcsesTrackSpeed)
  self.config = {
    gettrackspeed_mps=function () return 0 end,
    getforwardspeedlimits=function () return {} end,
    getbackwardspeedlimits=function () return {} end
  }
  self.state = {
    speedlimit_mps=0,
    _hastype2limits=false,
    _forwardlimit_mps=nil,
    _backwardlimit_mps=nil
  }
  self._sched = scheduler
  self._sched:run(AcsesTrackSpeed._setstate, self)
  self._sched:run(AcsesTrackSpeed._lookforward, self)
  self._sched:run(AcsesTrackSpeed._lookbackward, self)
  return self
end

function AcsesTrackSpeed._setstate(self)
  while true do
    local speed_mps
    if self.state._forwardlimit_mps ~= nil then
      speed_mps = self.state._forwardlimit_mps
    elseif self.state._backwardlimit_mps ~= nil then
      speed_mps = self.state._backwardlimit_mps
    else
      speed_mps = self.config.gettrackspeed_mps()
    end
    self.state.speedlimit_mps = speed_mps
    self:_sethastype2limits()
    self._sched:yield()
  end
end

function AcsesTrackSpeed._sethastype2limits(self)
  local search = function (limits)
    self.state._hastype2limits = Tables.find(
      limits,
      function (limit) return limit.type == 2 end
    ) ~= nil
  end
  if not self.state._hastype2limits then
    search(self.config.getforwardspeedlimits())
  end
  if not self.state._hastype2limits then
    search(self.config.getbackwardspeedlimits())
  end
end

function AcsesTrackSpeed._lookforward(self)
  self:_look(
    function () return self.config.getforwardspeedlimits() end,
    function (speed_mps) self.state._forwardlimit_mps = speed_mps end)
end

function AcsesTrackSpeed._lookbackward(self)
  self:_look(
    function () return self.config.getbackwardspeedlimits() end,
    function (speed_mps) self.state._backwardlimit_mps = speed_mps end)
end

function AcsesTrackSpeed._look(self, getspeedlimits, setspeed)
  while true do
    local limit
    self._sched:select(nil, function ()
      local speedlimits = getspeedlimits()
      local i = Tables.find(speedlimits, function(thislimit)
        -- Default to type 1 limits *unless* we encounter a type 2 (Philadelphia-
        -- New York), at which point we'll search solely for type 2 limits.
        local righttype
        if self.state._hastype2limits then
          righttype = thislimit.type == 2
        else
          righttype = thislimit.type == 1
        end
        return righttype
          and thislimit.distance_m < 1
          and AcsesTrackSpeed._isvalid(thislimit.speed_mps)
          and thislimit.speed_mps ~= self.config.gettrackspeed_mps()
      end)
      if i ~= nil then
        limit = speedlimits[i]
        return true
      else
        return false
      end
    end)
    setspeed(limit.speed_mps)
    self._sched:select(
      nil,
      function ()
        local nextlimit = getspeedlimits()[1] 
        return nextlimit ~= nil
          and nextlimit.speed_mps == limit.speed_mps
          and nextlimit.distance_m >= 1
      end,
      function ()
        return self.config.gettrackspeed_mps() == limit.speed_mps
      end)
    setspeed(nil)
  end
end

function AcsesTrackSpeed._isvalid(v)
  return v < 1e9 and v > -1e9
end