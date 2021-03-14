-- Constants, lookup tables, and code for Amtrak's Advanced Civil Speed
-- Enforcement System.
local P = {}
Acses = P

P.nlimitlookahead = 5
P.nsignallookahead = 3

local debuglimits = false
local debugsignals = false
local debugtrackers = false
local stopspeed_mps = 0.01
local direction = {forward=0, stopped=1, backward=2}
local hazardtype = {currentlimit=0, advancelimit=1, stopsignal=2}
local violationtype = {alert=0, penalty=1}

local function initstate (self)
  self._running = false
  self._inforcespeed_mps = 0
  self._curvespeed_mps = 0
  self._isalarm = false
  self._ispenalty = false
  self._violation = nil
  self._enforcingspeed_mps = nil
  self._limitfilter = nil
  self._trackspeed = nil
  self._limittracker = nil
  self._signaltracker = nil
  self._coroutines = {}
end

-- From the main coroutine, create a new Acses context. This will add coroutines
-- to the provided scheduler.
function P:new (conf)
  local o = {
    _sched =
      conf.scheduler,
    _atc =
      conf.atc,
    _getspeed_mps =
      conf.getspeed_mps or function () return 0 end,
    _gettrackspeed_mps =
      conf.gettrackspeed_mps or function () return 0 end,
    _iterspeedlimits =
      conf.iterspeedlimits or function () return pairs({}) end,
    _iterrestrictsignals =
      conf.iterrestrictsignals or function () return pairs({}) end,
    _getacknowledge =
      conf.getacknowledge or function () return false end,
    _doalert =
      conf.doalert or function () end,
    _penaltylimit_mps =
      conf.penaltylimit_mps or 3*Units.mph.tomps,
    _alertlimit_mps =
      conf.alertlimit_mps or 1*Units.mph.tomps,
    -- -1.3 mph/s
    _penaltycurve_mps2 =
      conf.penaltycurve_mps2 or -1.3*Units.mph.tomps,
    -- Keep the distance small (not very prototypical) to handle those pesky
    -- closely spaced shunting signals.
    _positivestop_m =
      conf.positivestop_m or 20*Units.m.toft,
    _alertcurve_s =
      conf.alertcurve_s or 8
  }
  setmetatable(o, self)
  self.__index = self
  initstate(o)
  return o
end

-- From the main coroutine, start or stop the subsystem based on the provided
-- condition.
function P:setrunstate (cond)
  if cond and not self._running then
    self:start()
  elseif not cond and self._running then
    self:stop()
  end
end

local function getdirection (self)
  local speed_mps = self._getspeed_mps()
  if math.abs(speed_mps) < stopspeed_mps then
    return direction.stopped
  elseif speed_mps > 0 then
    return direction.forward
  else
    return direction.backward
  end
end

--[[
  Debugging views
]]

local function showlimits (self)
  local fspeed = function (mps)
    return string.format("%.2f", mps*Units.mps.tomph) .. "mph"
  end
  local fdist = function (m)
    return string.format("%.2f", m*Units.m.toft) .. "ft"
  end
  if debugtrackers then
    local ids = Iterator.totable(Iterator.keys(self._limittracker:iterobjects()))
    table.sort(ids, function (ida, idb)
      return self._limittracker:getdistance_m(ida)
        < self._limittracker:getdistance_m(idb)
    end)
    local show = function (_, id)
      local limit = self._limittracker:getobject(id)
      local distance_m = self._limittracker:getdistance_m(id)
      return tostring(id) .. ": type=" .. limit.type
        .. ", speed=" .. fspeed(limit.speed_mps)
        .. ", distance=" .. fdist(distance_m)
    end
    self._sched:info(Iterator.join("\n", Iterator.imap(show, ipairs(ids))))
  else
    local speedlimits = Iterator.totable(self._iterspeedlimits())
    local distances_m = Iterator.totable(Iterator.keys(pairs(speedlimits)))
    table.sort(distances_m)
    local show = function (_, distance_m)
      local limit = speedlimits[distance_m]
      return "type=" .. limit.type
        .. ", speed=" .. fspeed(limit.speed_mps)
        .. ", distance=" .. fdist(distance_m)
    end
    local posts = Iterator.join("\n", Iterator.imap(show, ipairs(distances_m)))
    self._sched:info("Track: " .. fspeed(self._gettrackspeed_mps()) .. " "
      .. "Sensed: " .. fspeed(self._trackspeed:gettrackspeed_mps()) .. "\n"
      .. "Posts: " .. posts)
  end
end

local function showsignals (self)
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
    else
      return tostring(ps) .. "(?)"
    end
  end
  local fdist = function (m)
    return string.format("%.2f", m*Units.m.toft) .. "ft"
  end
  if debugtrackers then
    local ids = Iterator.totable(Iterator.keys(self._signaltracker:iterobjects()))
    table.sort(ids, function (ida, idb)
      return self._signaltracker:getdistance_m(ida)
        < self._signaltracker:getdistance_m(idb)
    end)
    local show = function (_, id)
      local signal = self._signaltracker:getobject(id)
      local distance_m = self._signaltracker:getdistance_m(id)
      return tostring(id) .. ": state=" .. faspect(signal.prostate)
        .. ", distance=" .. fdist(distance_m)
    end
    self._sched:info(Iterator.join("\n", Iterator.imap(show, ipairs(ids))))
  else
    local restrictsignals = Iterator.totable(self._iterrestrictsignals())
    local distances_m = Iterator.totable(Iterator.keys(pairs(restrictsignals)))
    table.sort(distances_m)
    local show = function (_, distance_m)
      local signal = restrictsignals[distance_m]
      return "state=" .. faspect(signal.prostate)
        .. ", distance=" .. fdist(distance_m)
    end
    self._sched:info(Iterator.join("\n", Iterator.imap(show, ipairs(distances_m))))
  end
end

--[[
  Speed limit and stop signal hazard acquisition
]]

local function calcbrakecurve (self, vf, d, t)
  local a = self._penaltycurve_mps2
  return math.max(
    math.pow(math.pow(a*t, 2) - 2*a*d + math.pow(vf, 2), 0.5) + a*t, vf)
end

local function getspeedlimithazard (self, id)
  local speed_mps = self._limittracker:getobject(id).speed_mps
  local distance_m = self._limittracker:getdistance_m(id)
  return {
    type=hazardtype.advancelimit,
    id=id,
    penalty_mps=calcbrakecurve(
      self, speed_mps + self._penaltylimit_mps, distance_m, 0),
    alert_mps=calcbrakecurve(
      self, speed_mps + self._alertlimit_mps, distance_m, self._alertcurve_s),
    curve_mps=calcbrakecurve(
      self, speed_mps, distance_m, self._alertcurve_s),
  }
end

local function gettrackspeedhazard (self)
  local limit_mps = self._trackspeed:gettrackspeed_mps()
  return {
    type=hazardtype.currentlimit,
    penalty_mps=limit_mps + self._penaltylimit_mps,
    alert_mps=limit_mps + self._alertlimit_mps,
    curve_mps=limit_mps
  }
end

local function getnextstopsignalid (self, dir)
  local isstop = function (id, _)
    local signal = self._signaltracker:getobject(id)
    return signal ~= nil and signal.prostate == 3
  end
  if dir == direction.forward then
    return Iterator.min(
      Iterator.ltcomp,
      Iterator.filter(
        isstop,
        Iterator.filter(
          function (_, distance_m) return distance_m >= 0 end,
          self._signaltracker:iterdistances_m()
        )
      )
    )
  elseif dir == direction.backward then
    return Iterator.max(
      Iterator.ltcomp,
      Iterator.filter(
        isstop,
        Iterator.filter(
          function (_, distance_m) return distance_m < 0 end,
          self._signaltracker:iterdistances_m()
        )
      )
    )
  else
    return nil
  end
end

local function getsignalstophazard (self, id)
  local distance_m =
    self._signaltracker:getdistance_m(id) - self._positivestop_m
  local alert_mps =
    calcbrakecurve(self, 0, distance_m, self._alertcurve_s)
  return {
    type=hazardtype.stopsignal,
    id=id,
    penalty_mps=calcbrakecurve(self, 0, distance_m, 0),
    alert_mps=alert_mps,
    curve_mps=alert_mps
  }
end

local function iteradvancespeedlimithazards (self, dir)
  local rightdirection = function (_, distance_m)
    if dir == direction.forward then
      return distance_m >= 0
    elseif dir == direction.backward then
      return distance_m < 0
    else
      return false
    end
  end
  return Iterator.imap(
    function (id, _) return getspeedlimithazard(self, id) end,
    Iterator.filter(rightdirection, self._limittracker:iterdistances_m()))
end

local function iterhazards (self)
  local dir = getdirection(self)
  local hazards = {gettrackspeedhazard(self)}

  local pulsecode = self._atc:getpulsecode()
  if pulsecode == Atc.pulsecode.restrict
      or pulsecode == Atc.pulsecode.approach then
    local id = getnextstopsignalid(self, dir)
    if id ~= nil then
      table.insert(hazards, getsignalstophazard(self, id))
    end
  end

  return Iterator.iconcat(
    {ipairs(hazards)}, {iteradvancespeedlimithazards(self, dir)})
end

local function getviolation (self, ...)
  local aspeed_mps = math.abs(self._getspeed_mps())
  local violation = nil
  for _, hazard in unpack(arg) do
    if aspeed_mps > hazard.penalty_mps then
      violation = {type=violationtype.penalty, hazard=hazard}
      break
    elseif aspeed_mps > hazard.alert_mps then
      violation = {type=violationtype.alert, hazard=hazard}
      break
    end
  end
  return violation
end

local function setstate (self)
  while true do
    local inforce_mps =
      self._enforcingspeed_mps or self._trackspeed:gettrackspeed_mps()
    if inforce_mps ~= self._inforcespeed_mps and not self._isalarm then
      self._doalert()
    end
    self._inforcespeed_mps = inforce_mps
    do
      local hazards = Iterator.totable(iterhazards(self))
      local lowestcurve = Iterator.min(Iterator.ltcomp, Iterator.imap(
        function (_, hazard) return hazard.curve_mps end,
        ipairs(hazards)))
      self._curvespeed_mps = hazards[lowestcurve]
      self._violation = getviolation(self, ipairs(hazards))
    end
    if debuglimits and self._getacknowledge() then
      showlimits(self)
    end
    if debugsignals and self._getacknowledge() then
      showsignals(self)
    end
    self._sched:yield()
  end
end

--[[
  Alert and penalty states
]]

local function currentlimitpenalty (self)
  local limit_mps = self._trackspeed:gettrackspeed_mps()
  self._enforcingspeed_mps = limit_mps
  self._ispenalty = true
  self._isalarm = true
  self._sched:select(nil, function ()
    return math.abs(self._getspeed_mps()) <= limit_mps
      and self._getacknowledge()
  end)
  self._enforcingspeed_mps = nil
  self._ispenalty = false
  self._isalarm = false
end

local function advancelimitpenalty (self, violation)
  local limit = self._limittracker:getobject(violation.hazard.id)
  if limit == nil then
    return
  end
  self._enforcingspeed_mps = limit.speed_mps
  self._ispenalty = true
  self._isalarm = true
  self._sched:select(nil, function ()
    return math.abs(self._getspeed_mps()) <= limit.speed_mps
      and self._getacknowledge()
  end)
  self._enforcingspeed_mps = nil
  self._ispenalty = false
  self._isalarm = false
end

local function stopsignalpenalty (self, violation)
  self._enforcingspeed_mps = 0
  self._ispenalty = true
  self._sched:select(nil, function ()
    local signal = self._signaltracker:getobject(violation.hazard.id)
    local upgraded = signal == nil or signal.prostate ~= 3
    return upgraded
  end)
  self._sched:select(nil, function ()
    return self._getacknowledge()
  end)
  self._enforcingspeed_mps = nil
  self._ispenalty = false
  self._isalarm = false
end

local function penalty (self, violation)
  local type = violation.hazard.type
  if type == hazardtype.currentlimit then
    currentlimitpenalty(self)
  elseif type == hazardtype.advancelimit then
    advancelimitpenalty(self, violation)
  elseif type == hazardtype.stopsignal then
    stopsignalpenalty(self, violation)
  end
end

local function currentlimitalert (self)
  local limit_mps = self._trackspeed:gettrackspeed_mps()
  self._enforcingspeed_mps = limit_mps
  self._isalarm = true
  local acknowledged = false
  while true do
    local event = self._sched:select(
      nil,
      function ()
        return self._violation ~= nil
          and self._violation.type == violationtype.penalty
      end,
      function ()
        return self._getacknowledge()
      end,
      function ()
        return math.abs(self._getspeed_mps()) <= limit_mps
          and acknowledged
      end,
      function ()
        return self._trackspeed:gettrackspeed_mps() ~= limit_mps
          and acknowledged
      end)
    if event == 1 then
      penalty(self, self._violation)
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

local function advancelimitalert (self, violation)
  local limit = self._limittracker:getobject(violation.hazard.id)
  if limit == nil then
    return
  end
  self._enforcingspeed_mps = limit.speed_mps
  self._isalarm = true
  local acknowledged = false
  local initdir = getdirection(self)
  while true do
    local event = self._sched:select(
      nil,
      function ()
        return self._violation ~= nil
          and self._violation.type == violationtype.penalty
      end,
      function ()
        return self._getacknowledge()
      end,
      function ()
        local pastlimit
        local distanceto_m =
          self._limittracker:getdistance_m(violation.hazard.id)
        if distanceto_m == nil then
          pastlimit = true
        elseif initdir == direction.forward and distanceto_m < 0 then
          pastlimit = true
        elseif initdir == direction.backward and distanceto_m > 0 then
          pastlimit = true
        else
          pastlimit = false
        end

        local dir = getdirection(self)
        local reversed = dir ~= initdir and dir ~= direction.stopped

        return (pastlimit or reversed) and acknowledged
      end)
    if event == 1 then
      penalty(self, self._violation)
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

local function stopsignalalert (self, violation)
  self._enforcingspeed_mps = 0
  self._isalarm = true
  local acknowledged = false
  local initdir = getdirection(self)
  while true do
    local signal =
      self._signaltracker:getobject(violation.hazard.id)
    local upgraded =
      signal == nil or signal.prostate ~= 3
    local dir = getdirection(self)
    local reversed = dir ~= initdir and dir ~= direction.stopped
    if upgraded or reversed then
      if not acknowledged then
        self._sched:select(nil, function () return self._getacknowledge() end)
        self._isalarm = false
      end
      self._enforcingspeed_mps = nil
      break
    end

    local event = self._sched:select(
      0,
      function ()
        return self._violation ~= nil
          and self._violation.type == violationtype.penalty
      end,
      function ()
        return self._getacknowledge()
      end)
    if event == 1 then
      penalty(self, self._violation)
      break
    elseif event == 2 then
      self._isalarm = false
      acknowledged = true
    end
  end
end

local function enforce (self)
  while true do
    self._sched:select(nil, function () return self._violation ~= nil end)
    local violation = self._violation
    local type = violation.hazard.type
    if type == hazardtype.currentlimit then
      currentlimitalert(self)
    elseif type == hazardtype.advancelimit then
      advancelimitalert(self, violation)
    elseif type == hazardtype.stopsignal then
      stopsignalalert(self, violation)
    end
  end
end

-- From the main coroutine, initialize this subsystem.
function P:start ()
  if not self._running then
    self._running = true

    self._limitfilter = AcsesLimits:new{iterspeedlimits = self._iterspeedlimits}
    self._limittracker = AcsesTracker:new{
      scheduler = self._sched,
      getspeed_mps = self._getspeed_mps,
      iterbydistance = function () return self._limitfilter:iterspeedlimits() end
    }
    self._signaltracker = AcsesTracker:new{
      scheduler = self._sched,
      getspeed_mps = self._getspeed_mps,
      iterbydistance = self._iterrestrictsignals
    }
    self._trackspeed = AcsesTrackSpeed:new{
      scheduler = self._sched,
      speedlimittracker = self._limittracker,
      gettrackspeed_mps = self._gettrackspeed_mps
    }

    self._coroutines = {
      self._sched:run(setstate, self),
      self._sched:run(enforce, self)
    }
    if not self._sched:isstartup() then
      self._sched:alert("ACSES Cut In")
    end
  end
end

-- From the main coroutine, halt and reset this subsystem.
function P:stop ()
  if self._running then
    self._running = false
    for _, co in ipairs(self._coroutines) do
      self._sched:kill(co)
    end
    self._limittracker:kill()
    self._signaltracker:kill()
    self._trackspeed:kill()
    initstate(self)
    self._sched:alert("ACSES Cut Out")
  end
end

-- Returns the current track speed in force. In the alert and penalty states,
-- this communicates the limit that was violated.
function P:getinforcespeed_mps ()
  return self._inforcespeed_mps
end

-- Returns the current track speed in force, taking into account the advance
-- alert and penalty braking curves. This value "counts down" to an
-- approaching speed limit.
function P:getcurvespeed_mps ()
  return self._curvespeed_mps
end

-- Returns true when the alarm is sounding.
function P:isalarm ()
  return self._isalarm
end

-- Returns true when a penalty brake is applied.
function P:ispenalty ()
  return self._ispenalty
end

return P