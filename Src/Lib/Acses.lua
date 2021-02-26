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
  self.running = false
  self._sched = scheduler
  self:_initstate()
  return self
end

-- From the main coroutine, start or stop the subsystem based on the provided
-- condition.
function Acses.setrunstate(self, cond)
  if cond and not self.running then
    self:start()
  elseif not cond and self.running then
    self:stop()
  end
end

-- From the main coroutine, initialize this subsystem.
function Acses.start(self)
  if not self.running then
    self.running = true
    self.speedlimits = AcsesLimits.new(
      function () return self.config.getspeed_mps() end,
      function () return self.config.getforwardspeedlimits() end,
      function () return self.config.getbackwardspeedlimits() end)
    self.trackspeed = AcsesTrackSpeed.new(self._sched,
      function () return self.config.gettrackspeed_mps() end,
      function () return self.speedlimits:getupcomingspeedlimits() end)
    self._coroutines = {
      self._sched:run(Acses._setstate, self),
      self._sched:run(Acses._doenforce, self)
    }
    if not self._sched:isstartup() then
      self._sched:alert("ACSES cut in")
    end
  end
end

-- From the main coroutine, halt and reset this subsystem.
function Acses.stop(self)
  if self.running then
    self.running = false
    for _, co in ipairs(self._coroutines) do
      self._sched:kill(co)
    end
    self.trackspeed:kill()
    self:_initstate()
    self._sched:alert("ACSES cut out")
  end
end

function Acses._initstate(self)
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
  self.speedlimits = nil
  self.trackspeed = nil
  self._coroutines = {}
end

function Acses._setstate(self)
  while true do
    local inforce_mps =
      self.state._enforcingspeed_mps or self.trackspeed.state.speedlimit_mps
    if inforce_mps ~= self.state.inforcespeed_mps then
      self.config.doalert()
    end
    self.state.inforcespeed_mps = inforce_mps
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
  for _, limit in ipairs(self.speedlimits:getupcomingspeedlimits()) do
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
    return math.max(
      math.pow(math.pow(a*t, 2) - 2*a*d + math.pow(vf, 2), 0.5) + a*t,
      vf)
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
  self._sched:info("Track: " .. fspeed(self.config.gettrackspeed_mps()) .. " "
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
      or not Tables.find(self.speedlimits:getupcomingspeedlimits(), function (limit)
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


-- A speed post tracker that calculates the speed limit in force at the
-- player's location, irrespective of train length.
AcsesTrackSpeed = {}
AcsesTrackSpeed.__index = AcsesTrackSpeed

-- From the main coroutine, create a new speed post tracker context. This will
-- add coroutines to the provided scheduler. The caller should also customize
-- the properties in the config table initialized here.
function AcsesTrackSpeed.new(scheduler, gettrackspeed_mps, getupcomingspeedlimits)
  local self = setmetatable({}, AcsesTrackSpeed)
  self.state = {
    speedlimit_mps=0,
    _sensedlimit_mps=nil
  }
  self._gettrackspeed_mps = gettrackspeed_mps
  self._getupcomingspeedlimits = getupcomingspeedlimits
  self._sched = scheduler
  self._coroutines = {
    self._sched:run(AcsesTrackSpeed._setstate, self),
    self._sched:run(AcsesTrackSpeed._look, self)
  }
  return self
end

-- From the main coroutine, kill this subsystem's coroutines.
function AcsesTrackSpeed.kill(self)
  for _, co in ipairs(self._coroutines) do
    self._sched:kill(co)
  end
end

function AcsesTrackSpeed._setstate(self)
  while true do
    self.state.speedlimit_mps =
      self.state._sensedlimit_mps or self._gettrackspeed_mps()
    self._sched:yield()
  end
end

function AcsesTrackSpeed._look(self)
  while true do
    local limit
    self._sched:select(nil, function ()
      local speedlimits = self._getupcomingspeedlimits()
      local i = Tables.find(speedlimits, function(thislimit)
        return thislimit.distance_m < 1
          and thislimit.speed_mps ~= self._gettrackspeed_mps()
      end)
      limit = speedlimits[i]
      return i ~= nil
    end)
    self.state._sensedlimit_mps = limit.speed_mps
    self._sched:select(
      nil,
      function ()
        local nextlimit = self._getupcomingspeedlimits()[1]
        return nextlimit ~= nil
          and nextlimit.speed_mps == limit.speed_mps
          and nextlimit.distance_m >= 1
      end,
      function ()
        return self._gettrackspeed_mps() == limit.speed_mps
      end)
    self.state._sensedlimit_mps = nil
  end
end


-- A speed limits filter that selects posts with valid speeds and with the
-- appropriate speed limit type.
AcsesLimits = {}
AcsesLimits.__index = AcsesLimits

-- From the main coroutine, create a new speed limit filter context.
function AcsesLimits.new(
    getspeed_mps, getforwardspeedlimits, getbackwardspeedlimits)
  local self = setmetatable({}, AcsesLimits)
  self._getspeed_mps = getspeed_mps
  self._getforwardspeedlimits = getforwardspeedlimits
  self._getbackwardspeedlimits = getbackwardspeedlimits
  self._hastype2limits = false
  return self
end

-- Get forward speed limits if the train is running in forward, or backward
-- speed limits if the train is running in reverse.
function AcsesLimits.getupcomingspeedlimits(self)
  if self._getspeed_mps() >= 0 then
    return self:getforwardspeedlimits()
  else
    return self:getbackwardspeedlimits()
  end
end

-- Get forward-facing speed limits.
function AcsesLimits.getforwardspeedlimits(self)
  return self:_filterspeedlimits(self._getforwardspeedlimits())
end

-- Get backward-facing speed limits.
function AcsesLimits.getbackwardspeedlimits(self)
  return self:_filterspeedlimits(self._getbackwardspeedlimits())
end

function AcsesLimits._filterspeedlimits(self, speedlimits)
  if not self._hastype2limits then
    for _, limit in ipairs(speedlimits) do
      -- Default to type 1 limits *unless* we encounter a type 2 (Philadelphia-
      -- New York), at which point we'll search solely for type 2 limits.
      if limit.type == 2 then
        self._hastype2limits = true
        break
      end
    end
  end
  local filtered = {}
  for _, limit in ipairs(speedlimits) do
    local righttype
    if self._hastype2limits then
      righttype = limit.type == 2
    else
      righttype = limit.type == 1
    end
    if AcsesLimits._isvalid(limit) and righttype then
      table.insert(filtered, limit)
    end
  end
  return filtered
end

function AcsesLimits._isvalid(speedlimit)
  return speedlimit.speed_mps < 1e9 and speedlimit.speed_mps > -1e9
end