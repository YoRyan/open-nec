-- Constants, lookup tables, and code for Amtrak's Advanced Civil Speed
-- Enforcement System.
local P = {}
Acses = P

P.nlimitlookahead = 5
P.nsignallookahead = 3
P.mode = {normal=0, approachmed30=1, positivestop=2}

local debuglimits = false
local debugsignals = false
local debugtrackers = false
local stopspeed_mps = 0.01
local direction = {forward=0, stopped=1, backward=2}
local hazardtype = {currentlimit=0, advancelimit=1, stopsignal=2}

local function initstate (self)
  self._running = false
  self._inforcespeed_mps = 0
  self._curvespeed_mps = 0
  self._timetopenalty_s = nil
  self._isalarm = false
  self._ispenalty = false
  self._ispositivestop = false
  self._currenthazardid = {}
  self._isabovealertcurve = false
  self._isabovepenaltycurve = false
  self._issigrestricting = true
  self._movingdirection = direction.forward
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
    _getspeed_mps =
      conf.getspeed_mps or function () return 0 end,
    _gettrackspeed_mps =
      conf.gettrackspeed_mps or function () return 0 end,
    _getconsistlength_m =
      conf.getconsistlength_m or function () return 0 end,
    _iterspeedlimits =
      conf.iterspeedlimits or function () return pairs({}) end,
    _iterrestrictsignals =
      conf.iterrestrictsignals or function () return pairs({}) end,
    _getacknowledge =
      conf.getacknowledge or function () return false end,
    _doalert =
      conf.doalert or function () end,
    _consistspeed_mps =
      conf.consistspeed_mps,
    _penaltylimit_mps =
      conf.penaltylimit_mps or 3*Units.mph.tomps,
    _alertlimit_mps =
      conf.alertlimit_mps or 1*Units.mph.tomps,
    -- -1.3 mph/s
    _penaltycurve_mps2 =
      conf.penaltycurve_mps2 or -1.3*Units.mph.tomps,
    _restrictingspeed_mps =
      conf.restrictingspeed_mps or 20*Units.mph.tomps,
    -- Keep the distance small (not very prototypical) to handle those pesky
    -- closely spaced shunting signals.
    _positivestop_m =
      conf.positivestop_m or 20*Units.m.toft,
    _alertwarning_s =
      conf.alertwarning_s or 7,
    _positivestopwarning_s =
      conf.positivestopwarning_s or 20
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

-- Determine whether this system is currently cut in.
function P:isrunning ()
  return self._running
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

local function getmovingdirection (self)
  local dir = getdirection(self)
  if dir ~= direction.stopped then
    self._movingdirection = dir
  end
  return self._movingdirection
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
  Braking curve calculation and state tracking
]]

local function calcbrakecurve (self, vf, d, t)
  local a = self._penaltycurve_mps2
  return math.max(
    math.pow(math.pow(a*t, 2) - 2*a*d + math.pow(vf, 2), 0.5) + a*t, vf)
end

local function calctimetopenalty (self, vf, d)
  local a = self._penaltycurve_mps2
  local vi = math.abs(self._getspeed_mps())
  if vi <= vf or a == 0 or vi == 0 then return nil
  else return (d - (vf*vf - vi*vi)/(2*a))/vi end
end

local function iteradvancelimithazards (self)
  return Iterator.map(
    function (id, distance_m)
      local speed_mps = self._limittracker:getobject(id).speed_mps
      return {hazardtype.advancelimit, id}, {
        inforce_mps = speed_mps,
        penalty_mps = calcbrakecurve(
          self, speed_mps + self._penaltylimit_mps, distance_m, 0),
        alert_mps = calcbrakecurve(
          self, speed_mps + self._alertlimit_mps, distance_m, self._alertwarning_s),
        timetopenalty_s = calctimetopenalty(
          self, speed_mps + self._penaltylimit_mps, distance_m)
      }
    end,
    Iterator.filter(
      function (_, distance_m)
        if getmovingdirection(self) == direction.forward then
          return distance_m >= 0
        else
          return distance_m <= 0
        end
      end,
      self._limittracker:iterdistances_m()
    )
  )
end

local function iterstopsignalhazards (self)
  return Iterator.map(
    function (id, distance_m)
      local target_m
      if distance_m > 0 then
        target_m = distance_m - self._positivestop_m
      else
        target_m = distance_m + self._positivestop_m
      end
      local prostate =
        self._signaltracker:getobject(id).prostate
      local alert_mps =
        calcbrakecurve(self, 0, target_m, self._positivestopwarning_s)
      if prostate == 3 and alert_mps <= self._restrictingspeed_mps then
        return {hazardtype.stopsignal, id}, {
          inforce_mps = 0,
          penalty_mps = calcbrakecurve(self, 0, target_m, 0),
          alert_mps = alert_mps,
          timetopenalty_s = calctimetopenalty(self, 0, target_m)
        }
      else
        return nil, nil
      end
    end,
    Iterator.filter(
      function (_, distance_m)
        if getmovingdirection(self) == direction.forward then
          return distance_m >= 0
        else
          return distance_m <= 0
        end
      end,
      self._signaltracker:iterdistances_m()
    )
  )
end

local function itercurrentlimithazards (self)
  local limits = {self._trackspeed:gettrackspeed_mps()}
  if self._consistspeed_mps ~= nil then
    table.insert(limits, self._consistspeed_mps)
  end
  return Iterator.map(
    function (_, speed_mps)
      return {hazardtype.currentlimit, speed_mps}, {
        inforce_mps = speed_mps,
        penalty_mps = speed_mps + self._penaltylimit_mps,
        alert_mps = speed_mps + self._alertlimit_mps
      }
    end,
    ipairs(limits)
  )
end

local function gethazardsdict (self)
  local hazards = TupleDict:new{}
  for k, hazard in iteradvancelimithazards(self) do
    hazards[k] = hazard
  end
  -- Positive stop disabled until we can figure out how to avoid irritating
  -- activations in yard and platform areas.
  --[[if self._issigrestricting and not self._sched:isstartup() then
    for k, hazard in iterstopsignalhazards(self) do
      hazards[k] = hazard
    end
  end]]
  for k, hazard in itercurrentlimithazards(self) do
    hazards[k] = hazard
  end
  return hazards
end

local function setinforcespeed_mps (self, v)
  if self._inforcespeed_mps ~= v then
    self._sched:yield() -- Give other coroutines the opportunity to set the alarm.
    if not self._isalarm then
      self._doalert()
    end
  end
  self._inforcespeed_mps = v
end

local function setstate (self)
  local state = TupleDict:new{}
  while true do
    local hazards = gethazardsdict(self)
    do
      local newstate = TupleDict:new{}
      for k, hazard in TupleDict.pairs(hazards) do
        local s = state[k]
        if s == nil then
          newstate[k] = {}
        else
          newstate[k] = s
        end
      end
      state = newstate
    end

    -- Get the current hazard in effect.
    local currentid = Iterator.min(
      Iterator.ltcomp,
      Iterator.map(
        function (k, hazard) return k, hazard.alert_mps end,
        TupleDict.pairs(hazards)
      )
    )
    local currenthazard = hazards[currentid]
    self._currenthazardid = currentid
    self._curvespeed_mps = math.max(0, currenthazard.alert_mps - 1*Units.mph.tomps)
    self._ispositivestop = currentid[1] == hazardtype.stopsignal

    -- Set the current time to penalty.
    local maxttp_s = 60
    local ttp_s = currenthazard.timetopenalty_s
    if not self._ispenalty and ttp_s ~= nil and ttp_s <= maxttp_s then
      self._timetopenalty_s = ttp_s
    else
      self._timetopenalty_s = nil
    end

    -- Check for violation of the alert and/or penalty curves.
    local aspeed_mps = math.abs(self._getspeed_mps())
    local abovealert = aspeed_mps > currenthazard.alert_mps
    if currentid[1] == hazardtype.advancelimit then
      local violated = state[currentid].violated or abovealert
      local abovelimit = aspeed_mps > currenthazard.inforce_mps
      state[currentid].violated = violated
      self._isabovealertcurve = violated and abovelimit
    else
      self._isabovealertcurve = abovealert
    end
    self._isabovepenaltycurve = aspeed_mps > currenthazard.penalty_mps

    -- Get the most restrictive hazard in effect that also has an in-force speed.
    local inforceid = Iterator.min(
      Iterator.ltcomp,
      Iterator.map(
        function (k, hazard)
          if k[1] == hazardtype.advancelimit then
            if state[k] ~= nil and state[k].violated then
              return k, hazard.alert_mps
            else
              return nil, nil
            end
          else
            return k, hazard.alert_mps
          end
        end,
        Iterator.filter(
          function (_, hazard) return hazard.inforce_mps ~= nil end,
          TupleDict.pairs(hazards)
        )
      )
    )
    setinforcespeed_mps(self, hazards[inforceid].inforce_mps)

    -- Activate the debug views if enabled.
    if self._getacknowledge() then
      if debuglimits then
        showlimits(self)
      end
      if debugsignals then
        showsignals(self)
      end
    end
    self._sched:yield()
  end
end

--[[
  Alert and penalty enforcement
]]

local function tableeq (a, b)
  local an = table.getn(a)
  local bn = table.getn(b)
  if an ~= bn then
    return false
  end
  for i = 1, an do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

local function penalty (self)
  self._ispenalty = true
  local hazardid = self._currenthazardid
  if hazardid[1] == hazardtype.stopsignal then
    self._sched:select(nil, function ()
      return getdirection(self) == direction.stopped
    end)
    self._isalarm = false
    -- Now wait for the signal to upgrade.
    -- TODO: Implement stop release function.
    self._sched:select(nil, function ()
      return not tableeq(self._currenthazardid, hazardid)
    end)
  else
    self._sched:select(nil, function ()
      return self._getacknowledge() and not self._isabovealertcurve
    end)
  end
  self._ispenalty = false
end

local function enforce (self)
  while true do
    self._sched:select(nil, function () return self._isabovealertcurve end)
    self._isalarm = true
    local acknowledge = self._sched:select(
      self._alertwarning_s,
      self._getacknowledge,
      function () return self._isabovepenaltycurve end)
    if acknowledge == nil or acknowledge == 2 then
      penalty(self)
      self._isalarm = false
    else
      local curve = self._sched:select(
        nil,
        function () return not self._isabovealertcurve end,
        function () return self._isabovepenaltycurve end)
      if curve == 2 then
        penalty(self)
      end
      self._isalarm = false
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
      gettrackspeed_mps = self._gettrackspeed_mps,
      getconsistlength_m = self._getconsistlength_m
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

-- Returns the current alert curve speed in force. This value "counts down"
-- to an approaching speed limit.
function P:getcurvespeed_mps ()
  return self._curvespeed_mps
end

-- Returns the time to penalty countdown.
function P:gettimetopenalty_s ()
  return self._timetopenalty_s
end

-- Returns true when the alarm is sounding.
function P:isalarm ()
  return self._isalarm
end

-- Returns true when a penalty brake is applied.
function P:ispenalty ()
  return self._ispenalty
end

-- Returns the current enforcing state.
function P:getmode ()
  if self._ispositivestop then
    return P.mode.positivestop
  else
    return P.mode.normal
  end
end

-- Receive a custom signal message.
function P:receivemessage (message)
  if self._running then
    local pulsecode, _ = Nec.parsesigmessage(message)
    if pulsecode ~= nil then
      self._issigrestricting = pulsecode == Nec.pulsecode.restrict
    end
  end
end

return P