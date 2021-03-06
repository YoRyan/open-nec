-- Constants, lookup tables, and code for Amtrak's Advanced Civil Speed
-- Enforcement System.

Acses = {}
Acses.__index = Acses

Acses.debuglimits = false
Acses.debugsignals = false
Acses.nlimitlookahead = 5
Acses.nsignallookahead = 3

Acses._direction = {forward=0, stopped=1, backward=2}
Acses._hazardtype = {currentlimit=0, advancelimit=1, stopsignal=2}
Acses._violationtype = {alert=0, penalty=1}
Acses._equaldistance_m = 0.1

-- From the main coroutine, create a new Acses context. This will add coroutines
-- to the provided scheduler. The caller should also customize the properties
-- in the config table initialized here.
function Acses.new(scheduler, atc)
  local self = setmetatable({}, Acses)
  self.config = {
    getspeed_mps=function () return 0 end,
    gettrackspeed_mps=function () return 0 end,
    getforwardspeedlimits=function () return {} end,
    getbackwardspeedlimits=function () return {} end,
    getforwardrestrictsignals=function () return {} end,
    getbackwardrestrictsignals=function () return {} end,
    getacknowledge=function () return false end,
    doalert=function () end,
    penaltylimit_mps=3*Units.mph.tomps,
    alertlimit_mps=1*Units.mph.tomps,
    -- -1.3 mph/s
    penaltycurve_mps2=-1.3*Units.mph.tomps,
    -- Keep the distance small (not very prototypical) to handle those pesky
    -- closely spaced shunting signals.
    positivestop_m=20*Units.m.toft,
    alertcurve_s=8
  }
  self.running = false
  self._sched = scheduler
  self._atc = atc
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
      function () return self.config.getforwardspeedlimits() end,
      function () return self.config.getbackwardspeedlimits() end)
    self.trackspeed = AcsesTrackSpeed.new(self._sched,
      function () return self.config.gettrackspeed_mps() end,
      function () return self.speedlimits:getforwardspeedlimits() end,
      function () return self.speedlimits:getbackwardspeedlimits() end)
    self.signaltracker = AcsesTracker.new(self._sched,
      function () return self.config.getspeed_mps() end,
      function ()
        local signals = {}
        for _, signal in ipairs(self.config.getforwardrestrictsignals()) do
          signals[signal.distance_m] = signal
        end
        for _, signal in ipairs(self.config.getbackwardrestrictsignals()) do
          signals[-signal.distance_m] = signal
        end
        return signals
      end)
    self._coroutines = {
      self._sched:run(Acses._setstate, self),
      self._sched:run(Acses._doenforce, self)
    }
    if not self._sched:isstartup() then
      self._sched:alert("ACSES Cut In")
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
    self.signaltracker:kill()
    self:_initstate()
    self._sched:alert("ACSES Cut Out")
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
      local hazards = self:_gethazards()
      self.state.curvespeed_mps = Acses._getcurvespeed(hazards)
      self.state._violation = self:_getviolation(hazards)
    end
    if Acses.debuglimits and self.config.getacknowledge() then
      self:_showlimits()
    end
    if Acses.debugsignals and self.config.getacknowledge() then
      self:_showsignals()
    end
    self._sched:yield()
  end
end

function Acses._gethazards(self)
  local hazards = {self:_gettrackspeedhazard()}
  local direction = self:_getdirection()

  local limits = {}
  if direction == Acses._direction.forward then
    limits = self.speedlimits:getforwardspeedlimits()
  elseif direction == Acses._direction.backward then
    limits = self.speedlimits:getbackwardspeedlimits()
  end
  for _, limit in ipairs(limits) do
    table.insert(hazards, self:_getspeedlimithazard(direction, limit))
  end

  if self._atc.state.pulsecode == Atc.pulsecode.restrict
      or self._atc.state.pulsecode == Atc.pulsecode.approach then
    local id = self:_nextstopsignal(direction)
    if id ~= nil then
      table.insert(hazards, self:_getsignalstophazard(id))
    end
  end

  return hazards
end

function Acses._gettrackspeedhazard(self)
  local limit_mps = self.trackspeed.state.speedlimit_mps
  return {
    type=Acses._hazardtype.currentlimit,
    limit_mps=limit_mps,
    penalty_mps=limit_mps + self.config.penaltylimit_mps,
    alert_mps=limit_mps + self.config.alertlimit_mps,
    curve_mps=limit_mps
  }
end

function Acses._getspeedlimithazard(self, direction, speedlimit)
  local speed_mps = speedlimit.speed_mps
  local distance_m = speedlimit.distance_m
  return {
    type=Acses._hazardtype.advancelimit,
    direction=direction,
    limit_mps=speedlimit.speed_mps,
    penalty_mps=self:_calcbrakecurve(
      speed_mps + self.config.penaltylimit_mps, distance_m, 0),
    alert_mps=self:_calcbrakecurve(
      speed_mps + self.config.alertlimit_mps, distance_m, self.config.alertcurve_s),
    curve_mps=self:_calcbrakecurve(
      speed_mps, distance_m, self.config.alertcurve_s),
  }
end

function Acses._getsignalstophazard(self, id)
  local distance_m =
    self.signaltracker.state.distances_m[id] - self.config.positivestop_m
  local alert_mps =
    self:_calcbrakecurve(0, distance_m, self.config.alertcurve_s)
  return {
    type=Acses._hazardtype.stopsignal,
    id=id,
    penalty_mps=self:_calcbrakecurve(0, distance_m, 0),
    alert_mps=alert_mps,
    curve_mps=alert_mps
  }
end

function Acses._calcbrakecurve(self, vf, d, t)
  local a = self.config.penaltycurve_mps2
  return math.max(
    math.pow(math.pow(a*t, 2) - 2*a*d + math.pow(vf, 2), 0.5) + a*t, vf)
end

function Acses._getcurvespeed(hazards)
  local speed_mps = nil
  for _, hazard in ipairs(hazards) do
    if speed_mps == nil then
      speed_mps = hazard.curve_mps
    elseif hazard.curve_mps < speed_mps then
      speed_mps = hazard.curve_mps
    end
  end
  return speed_mps
end

function Acses._getviolation(self, hazards)
  local aspeed_mps = math.abs(self.config.getspeed_mps())
  local violation = nil
  for _, hazard in ipairs(hazards) do
    if aspeed_mps > hazard.penalty_mps then
      violation = {type=Acses._violationtype.penalty, hazard=hazard}
      break
    elseif aspeed_mps > hazard.alert_mps then
      violation = {type=Acses._violationtype.alert, hazard=hazard}
      break
    end
  end
  return violation
end

function Acses._showlimits(self)
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

function Acses._showsignals(self)
  local faspect = function (ps)
    if ps == -1 then
      return "invalid"
    elseif ps == 1 then
      return "yellow"
    elseif ps == 2 then
      return "dbl yellow"
    elseif ps == 3 then
      return "red"
    elseif ps == 10 then
      return "flsh yellow"
    elseif ps == 11 then
      return "flsh dbl yellow"
    end
  end
  local fdist = function (m)
    return string.format("%.2f", m*Units.m.toft) .. "ft"
  end
  local dump = function (signals)
    local res = ""
    for _, signal in ipairs(signals) do
      local s = "state=" .. faspect(signal.prostate)
        .. ", distance=" .. fdist(signal.distance_m)
      res = res .. s .. "\n"
    end
    return res
  end
  self._sched:info("Forward: " .. dump(self.config.getforwardrestrictsignals())
    .. "Backward: " .. dump(self.config.getbackwardrestrictsignals()))
end

function Acses._doenforce(self)
  while true do
    self._sched:select(nil, function () return self.state._violation ~= nil end)
    local violation = self.state._violation
    local type = violation.hazard.type
    if type == Acses._hazardtype.currentlimit then
      self:_currentlimitalert(violation)
    elseif type == Acses._hazardtype.advancelimit then
      self:_advancelimitalert(violation)
    elseif type == Acses._hazardtype.stopsignal then
      self:_stopsignalalert(violation)
    end
  end
end

function Acses._currentlimitalert(self, violation)
  self.state._enforcingspeed_mps = violation.hazard.limit_mps
  self.state.alarm = true
  local acknowledged = false
  while true do
    local event = self._sched:select(
      nil,
      function ()
        return self.state._violation ~= nil
          and self.state._violation.type == Acses._violationtype.penalty
      end,
      function ()
        return self.config.getacknowledge()
      end,
      function ()
        return math.abs(self.config.getspeed_mps()) <= violation.hazard.limit_mps
          and acknowledged
      end,
      function ()
        return self.trackspeed.state.speedlimit_mps ~= violation.hazard.limit_mps
          and acknowledged
      end)
    if event == 1 then
      self:_limitpenalty(self.state._violation)
      break
    elseif event == 2 then
      self.state.alarm = false
      acknowledged = true
    elseif event == 3 or event == 4 then
      self.state._enforcingspeed_mps = nil
      self.state.alarm = false
      break
    end
  end
end

function Acses._advancelimitalert(self, violation)
  self.state._enforcingspeed_mps = violation.hazard.limit_mps
  self.state.alarm = true
  local acknowledged = false
  while true do
    local event = self._sched:select(
      nil,
      function ()
        return self.state._violation ~= nil
          and self.state._violation.type == Acses._violationtype.penalty
      end,
      function ()
        return self.config.getacknowledge()
      end,
      function ()
        return self.trackspeed.state.speedlimit_mps == violation.hazard.limit_mps
          and acknowledged
      end,
      function ()
        local direction = violation.hazard.direction
        local speedlimits = {}
        if direction == Acses._direction.forward then
          speedlimits = self.speedlimits:getforwardspeedlimits()
        elseif direction == Acses._direction.backward then
          speedlimits = self.speedlimits:getbackwardspeedlimits()
        end
        local limitgone = not Tables.find(
          speedlimits,
          function (limit) return limit.speed_mps == violation.hazard.limit_mps end)
        return limitgone and acknowledged
      end)
    if event == 1 then
      self:_penalty(self.state._violation)
      break
    elseif event == 2 then
      self.state.alarm = false
      acknowledged = true
    elseif event == 3 or event == 4 then
      self.state._enforcingspeed_mps = nil
      self.state.alarm = false
      break
    end
  end
end

function Acses._stopsignalalert(self, violation)
  self.state._enforcingspeed_mps = 0
  self.state.alarm = true
  local acknowledged = false
  local initdirection = self:_getdirection()
  while true do
    local signal =
      self.signaltracker.state.objects[violation.hazard.id]
    local upgraded =
      signal == nil or signal.prostate ~= 3
    local direction =
      self:_getdirection()
    local reversed =
      direction ~= initdirection and direction ~= Acses._direction.stopped
    if upgraded or reversed then
      if not acknowledged then
        self._sched:select(nil, function () return self.config.getacknowledge() end)
        self.state.alarm = false
      end
      self.state._enforcingspeed_mps = nil
      break
    end

    local event = self._sched:select(
      0,
      function ()
        return self.state._violation ~= nil
          and self.state._violation.type == Acses._violationtype.penalty
      end,
      function ()
        return self.config.getacknowledge()
      end)
    if event == 1 then
      self:_penalty(self.state._violation)
      break
    elseif event == 2 then
      self.state.alarm = false
      acknowledged = true
    end
  end
end

function Acses._penalty(self, violation)
  local type = violation.hazard.type
  if type == Acses._hazardtype.currentlimit
      or type == Acses._hazardtype.advancelimit then
    self:_limitpenalty(violation)
  elseif type == Acses._hazardtype.stopsignal then
    self:_stopsignalpenalty(violation)
  end
end

function Acses._limitpenalty(self, violation)
  self.state._enforcingspeed_mps = violation.hazard.limit_mps
  self.state.penalty = true
  self.state.alarm = true
  self._sched:select(nil, function ()
    return math.abs(self.config.getspeed_mps()) <= violation.hazard.limit_mps
      and self.config.getacknowledge()
  end)
  self.state._enforcingspeed_mps = nil
  self.state.penalty = false
  self.state.alarm = false
end

function Acses._stopsignalpenalty(self, violation)
  self.state._enforcingspeed_mps = 0
  self.state.penalty = true
  self._sched:select(nil, function ()
    local signal = self.signaltracker.state.objects[violation.hazard.id]
    local upgraded = signal == nil or signal.prostate ~= 3
    return upgraded
  end)
  self._sched:select(nil, function ()
    return self.config.getacknowledge()
  end)
  self.state._enforcingspeed_mps = nil
  self.state.penalty = false
  self.state.alarm = false
end

function Acses._nextstopsignal(self, direction)
  local disttest
  if direction == Acses._direction.forward then
    disttest = function (d) return d >= 0 end
  elseif direction == Acses._direction.stopped then
    return nil
  elseif direction == Acses._direction.backward then
    disttest = function (d) return d < 0 end
  end
  local closestid = nil
  for id, signal in pairs(self.signaltracker.state.objects) do
    if signal.prostate == 3 then
      local distance_m = self.signaltracker.state.distances_m[id]
      if closestid == nil
          or distance_m < self.signaltracker.state.distances_m[closestid] then
        if disttest(distance_m) then
          closestid = id
        end
      end
    end
  end
  return closestid
end

function Acses._getdirection(self)
  local speed_mps = self.config.getspeed_mps()
  if math.abs(speed_mps) < 0.01 then
    return Acses._direction.stopped
  elseif speed_mps > 0 then
    return Acses._direction.forward
  else
    return Acses._direction.backward
  end
end

function Acses._softgt(a, b)
  if math.abs(a - b) < Acses._equaldistance_m then
    return false
  else
    return a > b
  end
end


-- A speed post tracker that calculates the speed limit in force at the
-- player's location, irrespective of train length.
AcsesTrackSpeed = {}
AcsesTrackSpeed.__index = AcsesTrackSpeed

-- From the main coroutine, create a new speed post tracker context. This will
-- add coroutines to the provided scheduler.
function AcsesTrackSpeed.new(
    scheduler, gettrackspeed_mps, getforwardspeedlimits, getbackwardspeedlimits)
  local self = setmetatable({}, AcsesTrackSpeed)
  self.state = {
    speedlimit_mps=0,

    _sensedforwardlimit_mps=nil,
    _sensedbackwardlimit_mps=nil
  }
  self._sensedistance_m = 10*Units.m.toft
  self._sched = scheduler
  self._gettrackspeed_mps = gettrackspeed_mps
  self._coroutines = {
    self._sched:run(AcsesTrackSpeed._setstate, self),
    self._sched:run(
      AcsesTrackSpeed._look,
      self,
      getforwardspeedlimits,
      function (limit_mps) self.state._sensedforwardlimit_mps = limit_mps end),
    self._sched:run(
      AcsesTrackSpeed._look,
      self,
      getbackwardspeedlimits,
      function (limit_mps) self.state._sensedbackwardlimit_mps = limit_mps end)
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
    self.state.speedlimit_mps = self.state._sensedforwardlimit_mps
      or self.state._sensedbackwardlimit_mps
      or self._gettrackspeed_mps()
    self._sched:yield()
  end
end

function AcsesTrackSpeed._look(self, getspeedlimits, report)
  while true do
    local startlimit = getspeedlimits()[1]
    if startlimit ~= nil and startlimit.distance_m > self._sensedistance_m then
      local cmpdistance_m = startlimit.distance_m
      local startspeed_mps = startlimit.speed_mps
      while true do
        self._sched:yield()
        local newlimit = getspeedlimits()[1]
        if newlimit ~= nil then
          local newdistance_m = newlimit.distance_m
          if Acses._softgt(newdistance_m, cmpdistance_m) then
            break
          elseif newlimit.speed_mps ~= startspeed_mps then
            break
          elseif newdistance_m < self._sensedistance_m then
            self:_sensejustpassed(getspeedlimits, startspeed_mps, report)
            break
          else
            cmpdistance_m = newdistance_m
          end
        end
      end
    end
    self._sched:yield()
  end
end

function AcsesTrackSpeed._sensejustpassed(self, getspeedlimits, limit_mps, report)
  local backedout = function ()
    local nextlimit = getspeedlimits()[1]
    return nextlimit ~= nil
      and nextlimit.speed_mps == limit_mps
      and nextlimit.distance_m >= self._sensedistance_m
  end
  local event = self._sched:select(nil, backedout, function ()
    local nextlimit = getspeedlimits()[1]
    return nextlimit == nil
      or nextlimit.speed_mps ~= limit_mps
  end)
  if event == 2 then
    report(limit_mps)
    self._sched:select(nil, backedout, function ()
      return self._gettrackspeed_mps() == limit_mps
    end)
    report(nil)
  end
end


-- Assigns persistent unique identifiers to trackside objects that are sensed by
-- their relative distances from the player.
AcsesTracker = {}
AcsesTracker.__index = AcsesTracker

--[[
  From the main coroutine, create a new track object tracker context. This will
  add coroutines to the provided scheduler.

  getbydistance should return a dictionary that maps distances to tracked objects.
]]--
function AcsesTracker.new(scheduler, getspeed_mps, getbydistance)
  local self = setmetatable({}, AcsesTracker)
  self.state = {
    -- id -> tracked object
    objects = {},
    -- id -> distance (m)
    distances_m = {}
  }
  self._minretain_m = 1
  self._matchmargin_m = 1
  self._sched = scheduler
  self._coroutines = {
    self._sched:run(AcsesTracker._run, self, getspeed_mps, getbydistance)
  }
  return self
end

-- From the main coroutine, kill this subsystem's coroutines.
function AcsesTracker.kill(self)
  for _, co in ipairs(self._coroutines) do
    self._sched:kill(co)
  end
end

function AcsesTracker._run(self, getspeed_mps, getbydistance)
  local ctr = 1
  local lasttime = self._sched:clock()
  while true do
    self._sched:yield()
    local time = self._sched:clock()
    local travel_m = getspeed_mps()*(time - lasttime)
    lasttime = time

    local newobjects = {}
    local newdistances = {}

    -- Match sensed objects to tracked objects, taking into consideration the
    -- anticipated travel distance.
    for sensedist_m, obj in pairs(getbydistance()) do
      local match = false
      for id, trackdist_m in pairs(self.state.distances_m) do
        -- Update matched objects.
        if math.abs(trackdist_m - travel_m - sensedist_m)
            < self._matchmargin_m/2 then
          match = true
          newobjects[id] = obj
          newdistances[id] = sensedist_m
          break
        end
      end
      -- Add unmatched objects.
      if not match then
        newobjects[ctr] = obj
        newdistances[ctr] = sensedist_m
        ctr = ctr + 1
      end
    end

    -- Add back objects that are no longer sensed, but are within the minimum
    -- distance retention zone.
    for id, dist_m in pairs(self.state.distances_m) do
      if newdistances[id] == nil then
        if math.abs(dist_m + travel_m) < self._minretain_m then
          newobjects[id] = self.state.objects[id]
          newdistances[id] = dist_m + travel_m
        end
      end
    end

    self.state.objects = newobjects
    self.state.distances_m = newdistances
  end
end


-- A speed limits filter that selects posts with valid speeds and with the
-- appropriate speed limit type.
AcsesLimits = {}
AcsesLimits.__index = AcsesLimits

-- From the main coroutine, create a new speed limit filter context.
function AcsesLimits.new(getforwardspeedlimits, getbackwardspeedlimits)
  local self = setmetatable({}, AcsesLimits)
  self._getforwardspeedlimits = getforwardspeedlimits
  self._getbackwardspeedlimits = getbackwardspeedlimits
  self._hastype2limits = false
  return self
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