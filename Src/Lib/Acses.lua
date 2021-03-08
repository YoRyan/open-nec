-- Constants, lookup tables, and code for Amtrak's Advanced Civil Speed
-- Enforcement System.

Acses = {}
Acses.__index = Acses

Acses.debuglimits = false
Acses.debugsignals = false
Acses.debugtrackers = false
Acses.nlimitlookahead = 5
Acses.nsignallookahead = 3

Acses._direction = {forward=0, stopped=1, backward=2}
Acses._hazardtype = {currentlimit=0, advancelimit=1, stopsignal=2}
Acses._violationtype = {alert=0, penalty=1}
Acses._equaldistance_m = 0.1
Acses._stopspeed_mps = 0.01

-- From the main coroutine, create a new Acses context. This will add coroutines
-- to the provided scheduler. The caller should also customize the properties
-- in the config table initialized here.
function Acses.new(scheduler, atc)
  local self = setmetatable({}, Acses)
  self.config = {
    getspeed_mps=function () return 0 end,
    gettrackspeed_mps=function () return 0 end,
    iterforwardspeedlimits=function () return ipairs({}) end,
    iterbackwardspeedlimits=function () return ipairs({}) end,
    iterforwardrestrictsignals=function () return ipairs({}) end,
    iterbackwardrestrictsignals=function () return ipairs({}) end,
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
  self._sched = scheduler
  self._atc = atc
  self:_initstate()
  return self
end

function Acses._initstate(self)
  self._running = false
  self._inforcespeed_mps = 0
  self._curvespeed_mps = 0
  self._isalarm = false
  self._ispenalty = false
  self._violation = nil
  self._enforcingspeed_mps = nil
  self._speedlimits = nil
  self.trackspeed = nil
  self._limittracker = nil
  self._signaltracker = nil
  self._coroutines = {}
end

-- From the main coroutine, start or stop the subsystem based on the provided
-- condition.
function Acses.setrunstate(self, cond)
  if cond and not self._running then
    self:start()
  elseif not cond and self._running then
    self:stop()
  end
end

-- From the main coroutine, initialize this subsystem.
function Acses.start(self)
  if not self._running then
    self._running = true
    self._speedlimits = AcsesLimits.new(
      function () return self.config.iterforwardspeedlimits() end,
      function () return self.config.iterbackwardspeedlimits() end)
    self._limittracker = AcsesTracker.new(
      self._sched,
      function () return self.config.getspeed_mps() end,
      function ()
        return Iterator.concat(
          {
            Iterator.map(
              function (i, limit) return limit.distance_m, limit end,
              self._speedlimits:iterforwardspeedlimits())
          },
          {
            Iterator.map(
              function (i, limit) return -limit.distance_m, limit end,
              self._speedlimits:iterbackwardspeedlimits())
          }
        )
      end)
    self._signaltracker = AcsesTracker.new(self._sched,
      function () return self.config.getspeed_mps() end,
      function ()
        return Iterator.concat(
          {
            Iterator.map(
              function (i, signal) return signal.distance_m, signal end,
              self.config.iterforwardrestrictsignals())
          },
          {
            Iterator.map(
              function (i, signal) return -signal.distance_m, signal end,
              self.config.iterbackwardrestrictsignals())
          }
        )
      end)
    self._trackspeed = AcsesTrackSpeed.new(
      self._sched,
      self._limittracker,
      function () return self.config.gettrackspeed_mps() end)
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
  if self._running then
    self._running = false
    for _, co in ipairs(self._coroutines) do
      self._sched:kill(co)
    end
    self._limittracker:kill()
    self._signaltracker:kill()
    self._trackspeed:kill()
    self:_initstate()
    self._sched:alert("ACSES Cut Out")
  end
end

-- Returns the current track speed in force. In the alert and penalty states,
-- this communicates the limit that was violated.
function Acses.getinforcespeed_mps(self)
  return self._inforcespeed_mps
end

-- Returns the current track speed in force, taking into account the advance
-- alert and penalty braking curves. This value "counts down" to an
-- approaching speed limit.
function Acses.getcurvespeed_mps(self)
  return self._curvespeed_mps
end

-- Returns true when the alarm is sounding.
function Acses.isalarm(self)
  return self._isalarm
end

-- Returns true when a penalty brake is applied.
function Acses.ispenalty(self)
  return self._ispenalty
end

function Acses._setstate(self)
  while true do
    local inforce_mps =
      self._enforcingspeed_mps or self._trackspeed:gettrackspeed_mps()
    if inforce_mps ~= self._inforcespeed_mps then
      self.config.doalert()
    end
    self._inforcespeed_mps = inforce_mps
    do
      local hazards = Iterator.totable(self:_iterhazards())
      local lowestcurve = Iterator.min(
        function (hazarda, hazardb)
          return hazarda.curve_mps < hazardb.curve_mps
        end, ipairs(hazards))
      self._curvespeed_mps = hazards[lowestcurve]
      self._violation = self:_getviolation(ipairs(hazards))
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

--[[
  Speed limit and stop signal hazard acquisition
]]

function Acses._iterhazards(self)
  local direction = self:_getdirection()
  local hazards = {self:_gettrackspeedhazard()}

  local pulsecode = self._atc:getpulsecode()
  if pulsecode == Atc.pulsecode.restrict
      or pulsecode == Atc.pulsecode.approach then
    local id = self:_getnextstopsignalid(direction)
    if id ~= nil then
      table.insert(hazards, self:_getsignalstophazard(id))
    end
  end

  return Iterator.iconcat(
    {ipairs(hazards)},
    {
      Iterator.map(
        function (i, id) return i, self:_getspeedlimithazard(id) end,
        self:_iterupcomingspeedlimitids(direction))
    }
  )
end

function Acses._gettrackspeedhazard(self)
  local limit_mps = self._trackspeed:gettrackspeed_mps()
  return {
    type=Acses._hazardtype.currentlimit,
    penalty_mps=limit_mps + self.config.penaltylimit_mps,
    alert_mps=limit_mps + self.config.alertlimit_mps,
    curve_mps=limit_mps
  }
end

function Acses._getnextstopsignalid(self, direction)
  local rightdirection = function (id, distance_m)
    if direction == Acses._direction.forward then
      return distance_m >= 0
    elseif direction == Acses._direction.backward then
      return distance_m < 0
    else
      return false
    end
  end
  local isstop = function (id, distance_m)
    local signal = self._signaltracker:getobject(id)
    return signal ~= nil and signal.prostate == 3
  end
  return Iterator.min(
    function (a, b) return a < b end,
    Iterator.filter(
      isstop,
      Iterator.filter(rightdirection, self._signaltracker:iterdistances_m())
    )
  )
end

function Acses._getsignalstophazard(self, id)
  local distance_m =
    self._signaltracker:getdistance_m(id) - self.config.positivestop_m
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

function Acses._iterupcomingspeedlimitids(self, direction)
  local rightdirection = function (id, distance_m)
    if direction == Acses._direction.forward then
      return distance_m >= 0
    elseif direction == Acses._direction.backward then
      return distance_m < 0
    else
      return false
    end
  end
  local toid = function (id, distance_m) return id end
  return Iterator.imap(
    toid, Iterator.filter(rightdirection, self._limittracker:iterdistances_m()))
end

function Acses._getspeedlimithazard(self, id)
  local speed_mps = self._limittracker:getobject(id).speed_mps
  local distance_m = self._limittracker:getdistance_m(id)
  return {
    type=Acses._hazardtype.advancelimit,
    id=id,
    penalty_mps=self:_calcbrakecurve(
      speed_mps + self.config.penaltylimit_mps, distance_m, 0),
    alert_mps=self:_calcbrakecurve(
      speed_mps + self.config.alertlimit_mps, distance_m, self.config.alertcurve_s),
    curve_mps=self:_calcbrakecurve(
      speed_mps, distance_m, self.config.alertcurve_s),
  }
end

function Acses._calcbrakecurve(self, vf, d, t)
  local a = self.config.penaltycurve_mps2
  return math.max(
    math.pow(math.pow(a*t, 2) - 2*a*d + math.pow(vf, 2), 0.5) + a*t, vf)
end

function Acses._getviolation(self, ...)
  local aspeed_mps = math.abs(self.config.getspeed_mps())
  local violation = nil
  for _, hazard in unpack(arg) do
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

--[[
  Debugging views
]]

function Acses._showlimits(self)
  local fspeed = function (mps)
    return string.format("%.2f", mps*Units.mps.tomph) .. "mph"
  end
  local fdist = function (m)
    return string.format("%.2f", m*Units.m.toft) .. "ft"
  end
  if Acses.debugtrackers then
    local ids = {}
    for id, _ in self._limittracker:iterobjects() do
      table.insert(ids, id)
    end
    table.sort(ids, function (ida, idb)
      return self._limittracker:getdistance_m(ida)
        < self._limittracker:getdistance_m(idb)
    end)
    local dumpid = function (i, id)
      local limit = self._limittracker:getobject(id)
      local distance_m = self._limittracker:getdistance_m(id)
      return tostring(id) .. ": type=" .. limit.type
        .. ", speed=" .. fspeed(limit.speed_mps)
        .. ", distance=" .. fdist(distance_m)
    end
    self._sched:info(Iterator.join("\n", Iterator.imap(dumpid, ipairs(ids))))
  else
    local dump = function (iterlimits)
      local res = ""
      for _, limit in iterlimits do
        local s = "type=" .. limit.type
          .. ", speed=" .. fspeed(limit.speed_mps)
          .. ", distance=" .. fdist(limit.distance_m)
        res = res .. s .. "\n"
      end
      return res
    end
    self._sched:info("Track: " .. fspeed(self.config.gettrackspeed_mps()) .. " "
      .. "Sensed: " .. fspeed(self._trackspeed:gettrackspeed_mps()) .. "\n"
      .. "Forward: " .. dump(self.config.iterforwardspeedlimits())
      .. "Backward: " .. dump(self.config.iterbackwardspeedlimits()))
  end
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
  if Acses.debugtrackers then
    local ids = {}
    for id, _ in self._signaltracker:iterobjects() do
      table.insert(ids, id)
    end
    table.sort(ids, function (ida, idb)
      return self._signaltracker:getdistance_m(ida)
        < self._signaltracker:getdistance_m(idb)
    end)
    local dumpid = function (i, id)
      local signal = self._signaltracker:getobject(id)
      local distance_m = self._signaltracker:getdistance_m(id)
      return tostring(id) .. ": state=" .. faspect(signal.prostate)
        .. ", distance=" .. fdist(distance_m)
    end
    self._sched:info(Iterator.join("\n", Iterator.imap(dumpid, ipairs(ids))))
  else
    local dump = function (itersignals)
      local res = ""
      for _, signal in itersignals do
        local s = "state=" .. faspect(signal.prostate)
          .. ", distance=" .. fdist(signal.distance_m)
        res = res .. s .. "\n"
      end
      return res
    end
    self._sched:info("Forward: " .. dump(self.config.iterforwardrestrictsignals())
      .. "Backward: " .. dump(self.config.iterbackwardrestrictsignals()))
  end
end

function Acses._doenforce(self)
  while true do
    self._sched:select(nil, function () return self._violation ~= nil end)
    local violation = self._violation
    local type = violation.hazard.type
    if type == Acses._hazardtype.currentlimit then
      self:_currentlimitalert()
    elseif type == Acses._hazardtype.advancelimit then
      self:_advancelimitalert(violation)
    elseif type == Acses._hazardtype.stopsignal then
      self:_stopsignalalert(violation)
    end
  end
end

--[[
  Alert and penalty states
]]

function Acses._currentlimitalert(self)
  local limit_mps = self._trackspeed:gettrackspeed_mps()
  self._enforcingspeed_mps = limit_mps
  self._isalarm = true
  local acknowledged = false
  while true do
    local event = self._sched:select(
      nil,
      function ()
        return self._violation ~= nil
          and self._violation.type == Acses._violationtype.penalty
      end,
      function ()
        return self.config.getacknowledge()
      end,
      function ()
        return math.abs(self.config.getspeed_mps()) <= limit_mps
          and acknowledged
      end,
      function ()
        return self._trackspeed:gettrackspeed_mps() ~= limit_mps
          and acknowledged
      end)
    if event == 1 then
      self:_penalty(self._violation)
      break
    elseif event == 2 then
      self._isalarm = false
      acknowledged = true
    elseif event == 3 or event == 4 then
      self._enforcingspeed_mps = nil
      self._isalarm = false
      break
    end
  end
end

function Acses._advancelimitalert(self, violation)
  local limit = self._limittracker:getobject(violation.hazard.id)
  if limit == nil then
    return
  end
  self._enforcingspeed_mps = limit.speed_mps
  self._isalarm = true
  local acknowledged = false
  local initdirection = self:_getdirection()
  while true do
    local event = self._sched:select(
      nil,
      function ()
        return self._violation ~= nil
          and self._violation.type == Acses._violationtype.penalty
      end,
      function ()
        return self.config.getacknowledge()
      end,
      function ()
        local pastlimit
        local distanceto_m =
          self._limittracker:getdistance_m(violation.hazard.id)
        if distanceto_m == nil then
          pastlimit = true
        elseif initdirection == Acses._direction.forward and distanceto_m < 0 then
          pastlimit = true
        elseif initdirection == Acses._direction.backward and distanceto_m > 0 then
          pastlimit = true
        else
          pastlimit = false
        end

        local direction =
          self:_getdirection()
        local reversed =
          direction ~= initdirection and direction ~= Acses._direction.stopped

        return (pastlimit or reversed) and acknowledged
      end)
    if event == 1 then
      self:_penalty(self._violation)
      break
    elseif event == 2 then
      self._isalarm = false
      acknowledged = true
    elseif event == 3 then
      self._enforcingspeed_mps = nil
      self._isalarm = false
      break
    end
  end
end

function Acses._stopsignalalert(self, violation)
  self._enforcingspeed_mps = 0
  self._isalarm = true
  local acknowledged = false
  local initdirection = self:_getdirection()
  while true do
    local signal =
      self._signaltracker:getobject(violation.hazard.id)
    local upgraded =
      signal == nil or signal.prostate ~= 3
    local direction =
      self:_getdirection()
    local reversed =
      direction ~= initdirection and direction ~= Acses._direction.stopped
    if upgraded or reversed then
      if not acknowledged then
        self._sched:select(nil, function () return self.config.getacknowledge() end)
        self._isalarm = false
      end
      self._enforcingspeed_mps = nil
      break
    end

    local event = self._sched:select(
      0,
      function ()
        return self._violation ~= nil
          and self._violation.type == Acses._violationtype.penalty
      end,
      function ()
        return self.config.getacknowledge()
      end)
    if event == 1 then
      self:_penalty(self._violation)
      break
    elseif event == 2 then
      self._isalarm = false
      acknowledged = true
    end
  end
end

function Acses._penalty(self, violation)
  local type = violation.hazard.type
  if type == Acses._hazardtype.currentlimit then
    self:_currentlimitpenalty()
  elseif type == Acses._hazardtype.advancelimit then
    self:_advancelimitpenalty(violation)
  elseif type == Acses._hazardtype.stopsignal then
    self:_stopsignalpenalty(violation)
  end
end

function Acses._currentlimitpenalty(self)
  local limit_mps = self._trackspeed:gettrackspeed_mps()
  self._enforcingspeed_mps = limit_mps
  self._ispenalty = true
  self._isalarm = true
  self._sched:select(nil, function ()
    return math.abs(self.config.getspeed_mps()) <= limit_mps
      and self.config.getacknowledge()
  end)
  self._enforcingspeed_mps = nil
  self._ispenalty = false
  self._isalarm = false
end

function Acses._advancelimitpenalty(self, violation)
  local limit = self._limittracker:getobject(violation.hazard.id)
  if limit == nil then
    return
  end
  self._enforcingspeed_mps = limit.speed_mps
  self._ispenalty = true
  self._isalarm = true
  self._sched:select(nil, function ()
    return math.abs(self.config.getspeed_mps()) <= limit.speed_mps
      and self.config.getacknowledge()
  end)
  self._enforcingspeed_mps = nil
  self._ispenalty = false
  self._isalarm = false
end

function Acses._stopsignalpenalty(self, violation)
  self._enforcingspeed_mps = 0
  self._ispenalty = true
  self._sched:select(nil, function ()
    local signal = self._signaltracker:getobject(violation.hazard.id)
    local upgraded = signal == nil or signal.prostate ~= 3
    return upgraded
  end)
  self._sched:select(nil, function ()
    return self.config.getacknowledge()
  end)
  self._enforcingspeed_mps = nil
  self._ispenalty = false
  self._isalarm = false
end

function Acses._getdirection(self)
  local speed_mps = self.config.getspeed_mps()
  if math.abs(speed_mps) < Acses._stopspeed_mps then
    return Acses._direction.stopped
  elseif speed_mps > 0 then
    return Acses._direction.forward
  else
    return Acses._direction.backward
  end
end


-- A speed post tracker that calculates the speed limit in force at the
-- player's location, irrespective of train length.
AcsesTrackSpeed = {}
AcsesTrackSpeed.__index = AcsesTrackSpeed

-- From the main coroutine, create a new speed post tracker context. This will
-- add coroutines to the provided scheduler.
function AcsesTrackSpeed.new(
    scheduler, speedlimittracker, gettrackspeed_mps)
  local self = setmetatable({}, AcsesTrackSpeed)
  self._trackspeed_mps = 0
  self._sched = scheduler
  self._coroutines = {
    self._sched:run(
      AcsesTrackSpeed._run, self, speedlimittracker, gettrackspeed_mps)
  }
  return self
end

-- From the main coroutine, kill this subsystem's coroutines.
function AcsesTrackSpeed.kill(self)
  for _, co in ipairs(self._coroutines) do
    self._sched:kill(co)
  end
end

-- Get the current sensed track speed.
function AcsesTrackSpeed.gettrackspeed_mps(self)
  return self._trackspeed_mps
end

function AcsesTrackSpeed._run(self, limittracker, gettrackspeed_mps)
  local before_mps = {}
  local after_mps = {}
  local sensed_mps = nil
  while true do
    self._sched:yield()
    do
      local newbefore_mps = {}
      local newafter_mps = {}
      for id, distance_m in limittracker:iterdistances_m() do
        local limit = limittracker:getobject(id)
        if distance_m > 0 then
          newbefore_mps[id] = before_mps[id]
          newafter_mps[id] = limit.speed_mps
        elseif distance_m < 0 then
          newbefore_mps[id] = limit.speed_mps
          newafter_mps[id] = after_mps[id]
        else
          newbefore_mps[id] = before_mps[id]
          newafter_mps[id] = after_mps[id]
        end
      end
      before_mps = newbefore_mps
      after_mps = newafter_mps
    end
    do
      local lastid = Iterator.max(
        AcsesTrackSpeed._comparedistances_m,
        Iterator.filter(
          function (id, distance_m) return distance_m < 0 end,
          limittracker:iterdistances_m()
        )
      )
      local nextid = Iterator.min(
        AcsesTrackSpeed._comparedistances_m,
        Iterator.filter(
          function (id, distance_m) return distance_m > 0 end,
          limittracker:iterdistances_m()
        )
      )
      -- Retain the deduced speed limit even if the original speed post is more
      -- than 10km away.
      sensed_mps = after_mps[lastid] or before_mps[nextid] or sensed_mps
      local gamespeed_mps = gettrackspeed_mps()
      if sensed_mps == nil then
        self._trackspeed_mps = gamespeed_mps
      else
        -- The game-calculated speed limit is strictly lower than the track
        -- speed limit we want, so if that is higher, then we should use it.
        self._trackspeed_mps = math.max(sensed_mps, gamespeed_mps)
      end
    end
  end
end

function AcsesTrackSpeed._comparedistances_m(dista_m, distb_m)
  return dista_m < distb_m
end


-- Assigns persistent unique identifiers to trackside objects that are sensed by
-- their relative distances from the player.
AcsesTracker = {}
AcsesTracker.__index = AcsesTracker

--[[
  From the main coroutine, create a new track object tracker context. This will
  add coroutines to the provided scheduler.

  iterbydistance should return an iterator of (distance (m), tracked object) pairs.
]]
function AcsesTracker.new(scheduler, getspeed_mps, iterbydistance)
  local self = setmetatable({}, AcsesTracker)
  self._passing_m = 16
  self._trackmargin_m = 2
  self._objects = {}
  self._distances_m = {}
  self._sched = scheduler
  self._coroutines = {
    self._sched:run(AcsesTracker._run, self, getspeed_mps, iterbydistance)
  }
  return self
end

-- From the main coroutine, kill this subsystem's coroutines.
function AcsesTracker.kill(self)
  for _, co in ipairs(self._coroutines) do
    self._sched:kill(co)
  end
end

-- Iterate through all tracked objects by their identifiers.
function AcsesTracker.iterobjects(self)
  return pairs(self._objects)
end

-- Get a tracked object by identifier.
function AcsesTracker.getobject(self, id)
  return self._objects[id]
end

-- Iterate through all relative distances by identifier.
function AcsesTracker.iterdistances_m(self)
  return Iterator.map(
    function (id, distance_m) return id, self:_getcorrectdistance_m(id) end,
    pairs(self._distances_m))
end

-- Get a relative distance by identifier.
function AcsesTracker.getdistance_m(self, id)
  return self:_getcorrectdistance_m(id)
end

function AcsesTracker._getcorrectdistance_m(self, id)
  local distance_m = self._distances_m[id]
  if distance_m == nil then
    return nil
  elseif distance_m < -self._passing_m/2 then
    return distance_m + self._passing_m/2
  elseif distance_m > self._passing_m/2 then
    return distance_m - self._passing_m/2
  else
    return 0
  end
end

function AcsesTracker._run(self, getspeed_mps, iterbydistance)
  local ctr = 1
  local lasttime = self._sched:clock()
  while true do
    self._sched:yield()
    local time = self._sched:clock()
    local travel_m = getspeed_mps()*(time - lasttime)
    lasttime = time

    local newobjects = {}
    local newdistances_m = {}

    -- Match sensed objects to tracked objects, taking into consideration the
    -- anticipated travel distance.
    for rawdistance_m, obj in iterbydistance() do
      local sensedistance_m
      if rawdistance_m >= 0 then
        sensedistance_m = rawdistance_m + self._passing_m/2
      else
        sensedistance_m = rawdistance_m - self._passing_m/2
      end
      local match = Iterator.findfirst(
        function (id, trackdistance_m)
          return math.abs(trackdistance_m - travel_m - sensedistance_m)
            < self._trackmargin_m/2
        end,
        pairs(self._distances_m))
      if match == nil then
        -- Add unmatched objects.
        newobjects[ctr] = obj
        newdistances_m[ctr] = sensedistance_m
        ctr = ctr + 1
      else
        -- Update matched objects.
        newobjects[match] = obj
        newdistances_m[match] = sensedistance_m
      end
    end

    --[[
      Track objects will briefly disappear for about 16 m of travel before they
      reappear in the reverse direction. We call this area the "passing" zone.

      d < 0|invisible|d > 0
      ---->|__~16_m__|<----

      Here, we add back objects that are no longer detected, but are within the
      passing zone.
    ]]
    local ispassing = function (id, distance_m)
      -- Use a generous retention margin here so that users will be notified
      -- with a positive or negative distance if an object cannot be tracked
      -- in the reverse direction.
      return newdistances_m[id] == nil and math.abs(distance_m - travel_m)
        < self._passing_m/2 + self._trackmargin_m
    end
    for id, distance_m in Iterator.filter(ispassing, pairs(self._distances_m)) do
      newobjects[id] = self._objects[id]
      newdistances_m[id] = distance_m - travel_m
    end

    self._objects = newobjects
    self._distances_m = newdistances_m
  end
end


-- A speed limits filter that selects posts with valid speeds and with the
-- appropriate speed limit type.
AcsesLimits = {}
AcsesLimits.__index = AcsesLimits

-- From the main coroutine, create a new speed limit filter context.
function AcsesLimits.new(iterforwardspeedlimits, iterbackwardspeedlimits)
  local self = setmetatable({}, AcsesLimits)
  self._iterforwardspeedlimits = iterforwardspeedlimits
  self._iterbackwardspeedlimits = iterbackwardspeedlimits
  self._hastype2limits = false
  return self
end

-- Iterate through forward-facing speed limits.
function AcsesLimits.iterforwardspeedlimits(self)
  return self:_filterspeedlimits(self._iterforwardspeedlimits)
end

-- Iterate through backward-facing speed limits.
function AcsesLimits.iterbackwardspeedlimits(self)
  return self:_filterspeedlimits(self._iterbackwardspeedlimits)
end

function AcsesLimits._filterspeedlimits(self, iterspeedlimits)
  if not self._hastype2limits then
    -- Default to type 1 limits *unless* we encounter a type 2 (Philadelphia-
    -- New York), at which point we'll search solely for type 2 limits.
    self._hastype2limits = Iterator.hasone(
      function (i, limit) return limit.type == 2 end,
      iterspeedlimits())
  end
  return Iterator.ifilter(
    function (i, limit)
      local righttype
      if self._hastype2limits then
        righttype = limit.type == 2
      else
        righttype = limit.type == 1
      end
      return AcsesLimits._isvalid(limit) and righttype
    end,
    iterspeedlimits())
end

function AcsesLimits._isvalid(speedlimit)
  return speedlimit.speed_mps < 1e9 and speedlimit.speed_mps > -1e9
end