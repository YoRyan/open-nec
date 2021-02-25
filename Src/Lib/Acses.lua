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
    -- 3 mph
    penaltylimit_mps=1.34,
    -- 1 mph
    alertlimit_mps=0.45,
    -- -2 mph/s
    penaltycurve_mps2=-0.894,
    -- 8 s
    alertcurve_s=8
  }
  self.state = {
    -- The current track speed in effect.
    enforcedspeed_mps=0,
    -- True when the alarm is sounding continuously.
    alarm=false,
    -- True when a penalty brake is applied.
    penalty=false,

    _violatedspeed_mps=nil
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
    if self.state._violatedspeed_mps ~= nil then
      self.state.enforcedspeed_mps = self.state._violatedspeed_mps
    else
      local newspeed_mps = self.trackspeed.state.speedlimit_mps
      if newspeed_mps ~= self.state.enforcedspeed_mps then
        self.config.doalert()
      end
      self.state.enforcedspeed_mps = newspeed_mps
    end
    if Acses.debuglimits and self.config.getacknowledge() then
      self:_printlimits()
    end
    self._sched:yield()
  end
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
    local speed_mps
    self._sched:select(nil, function ()
      _, speed_mps = self:_getviolation()
      return speed_mps ~= nil
    end)
    self:_alert(speed_mps)
  end
end

function Acses._alert(self, limit_mps)
  self.state._violatedspeed_mps = limit_mps
  self.state.alarm = true
  local violation, speed_mps, reachedlimit, stopped
  local acknowledged = false
  repeat
    violation, speed_mps = self:_getviolation()
    acknowledged = acknowledged or self.config.getacknowledge()
    if acknowledged then
      self.state.alarm = false
    end
    do
      local matchlimit = function (limit)
        return limit.speed_mps == limit_mps
      end
      reachedlimit = self.config.gettrackspeed_mps() == limit_mps
        or (not Tables.find(self.config.getforwardspeedlimits(), matchlimit)
            and not Tables.find(self.config.getbackwardspeedlimits(), matchlimit))
      stopped = math.abs(self.config.getspeed_mps()) <= 1*Units.mph.tomps
    end
    if violation == "penalty" then
      self:_penalty(speed_mps)
      -- You have to have acknowledged to get out of the penalty state.
      acknowledged = true
    end
    self._sched:yield()
  until violation == nil and acknowledged and (reachedlimit or stopped)
  self.state._violatedspeed_mps = nil
  self.state.alarm = false
end

function Acses._penalty(self, limit_mps)
  self.state.alarm = true
  self.state.penalty = true
  self._sched:select(nil, function ()
    return math.abs(self.config.getspeed_mps()) <= limit_mps and self.config.getacknowledge()
  end)
  self.state.penalty = false
  self.state.alarm = false
end

function Acses._getviolation(self)
  local type, speed_mps = self:_getspeedviolation()
  if type ~= nil then
    return type, speed_mps
  end
  if self.config.getspeed_mps() >= 0 then
    return self:_getlimitviolation(self.config.getforwardspeedlimits)
  else
    return self:_getlimitviolation(self.config.getbackwardspeedlimits)
  end
end

function Acses._getspeedviolation(self)
  local speed_mps = math.abs(self.config.getspeed_mps())
  local trackspeed_mps = self.trackspeed.state.speedlimit_mps
  if speed_mps > trackspeed_mps + self.config.penaltylimit_mps then
    return "penalty", trackspeed_mps
  elseif speed_mps > trackspeed_mps + self.config.alertlimit_mps then
    return "alert", trackspeed_mps
  else
    return nil, nil
  end
end

function Acses._getlimitviolation(self, getspeedlimits)
  local speed_mps = math.abs(self.config.getspeed_mps())
  for _, limit in ipairs(getspeedlimits()) do
    local penaltydistance_m, alertdistance_m
    do
      local v2 = math.pow(limit.speed_mps + self.config.penaltylimit_mps, 2)
      local v02 = math.pow(speed_mps + self.config.penaltylimit_mps, 2)
      penaltydistance_m = (v2 - v02)/(2*self.config.penaltycurve_mps2)
    end
    do
      local v2 = math.pow(limit.speed_mps + self.config.alertlimit_mps, 2)
      local v02 = math.pow(speed_mps + self.config.alertlimit_mps, 2)
      alertdistance_m = (v2 - v02)/(2*self.config.penaltycurve_mps2)
        + speed_mps*self.config.alertcurve_s
    end
    if speed_mps > limit.speed_mps + self.config.penaltylimit_mps
        and limit.distance_m < penaltydistance_m then
      return "penalty", limit.speed_mps
    elseif speed_mps > limit.speed_mps + self.config.alertlimit_mps
        and limit.distance_m < alertdistance_m then
      return "alert", limit.speed_mps
    end
  end
  return nil, nil
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