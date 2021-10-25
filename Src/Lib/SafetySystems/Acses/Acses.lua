-- Base class for Amtrak and Alstom's Advanced Civil Speed Enforcement System. This models
-- the behavior of an Amtrak-style ADU, with revealing speed limits.
--
-- @include SafetySystems/Acses/LimitFilter.lua
-- @include SafetySystems/Acses/ObjectTracker.lua
-- @include SafetySystems/Acses/TrackSpeed.lua
-- @include Iterator.lua
-- @include Misc.lua
-- @include TupleDictionary.lua
local P = {}
Acses = P

P.nlimitlookahead = 5
P.nsignallookahead = 3
P.mode = {normal = 0, approachmed30 = 1, positivestop = 2}
P._hazardtype = {currentlimit = 0, advancelimit = 1, stopsignal = 2}

local debuglimits = false
local debugsignals = false
local debugtrackers = false
local direction = {forward = 0, stopped = 1, backward = 2}

local function initstate(self)
  self._running = false
  self._isalarm = false
  self._ispenalty = false
  self._hazards = {}
  self._hazardstate = TupleDict:new{}
  self._inforceid = nil
  self._movingdirection = direction.forward
  self._limitfilter = nil
  self._trackspeed = nil
  self._limittracker = nil
  self._signaltracker = nil
  self._coroutines = {}
end

-- From the main coroutine, create a new Acses context. This will add coroutines
-- to the provided scheduler.
function P:new(conf)
  local o = {
    _sched = conf.scheduler,
    _cabsig = conf.cabsignal,
    _getspeed_mps = conf.getspeed_mps or function() return 0 end,
    _gettrackspeed_mps = conf.gettrackspeed_mps or function() return 0 end,
    _getconsistlength_m = conf.getconsistlength_m or function() return 0 end,
    _iterspeedlimits = conf.iterspeedlimits or
      function() return Iterator.empty() end,
    _iterrestrictsignals = conf.iterrestrictsignals or
      function() return Iterator.empty() end,
    _getacknowledge = conf.getacknowledge or function() return false end,
    _consistspeed_mps = conf.consistspeed_mps,
    _penaltylimit_mps = conf.penaltylimit_mps or 6 * Units.mph.tomps,
    _alertlimit_mps = conf.alertlimit_mps or 3 * Units.mph.tomps,
    -- -1.3 mph/s
    _penaltycurve_mps2 = conf.penaltycurve_mps2 or -1.3 * Units.mph.tomps,
    _restrictingspeed_mps = conf.restrictingspeed_mps or 20 * Units.mph.tomps,
    -- Keep the distance small (not very prototypical) to handle those pesky
    -- closely spaced shunting signals.
    _positivestop_m = conf.positivestop_m or 20 * Units.m.toft,
    _alertwarning_s = conf.alertwarning_s or 7,
    _positivestopwarning_s = conf.positivestopwarning_s or 20
  }
  setmetatable(o, self)
  self.__index = self
  initstate(o)
  return o
end

-- From the main coroutine, start or stop the subsystem based on the provided
-- condition.
function P:setrunstate(cond)
  if cond and not self._running then
    self:start()
  elseif not cond and self._running then
    self:stop()
  end
end

-- Determine whether this system is currently cut in.
function P:isrunning() return self._running end

local function getdirection(self)
  local speed_mps = self._getspeed_mps()
  if math.abs(speed_mps) < Misc.stopped_mps then
    return direction.stopped
  elseif speed_mps > 0 then
    return direction.forward
  else
    return direction.backward
  end
end

local function getmovingdirection(self)
  local dir = getdirection(self)
  if dir ~= direction.stopped then self._movingdirection = dir end
  return self._movingdirection
end

--[[
  Debugging views
]]

local function showlimits(self)
  local fspeed = function(mps)
    return string.format("%.2f", mps * Units.mps.tomph) .. "mph"
  end
  local fdist = function(m)
    return string.format("%.2f", m * Units.m.toft) .. "ft"
  end
  if debugtrackers then
    local ids =
      Iterator.totable(Iterator.keys(self._limittracker:iterobjects()))
    table.sort(ids, function(ida, idb)
      return self._limittracker:getdistance_m(ida) <
               self._limittracker:getdistance_m(idb)
    end)
    local show = function(_, id)
      local limit = self._limittracker:getobject(id)
      local distance_m = self._limittracker:getdistance_m(id)
      return tostring(id) .. ": type=" .. limit.type .. ", speed=" ..
               fspeed(limit.speed_mps) .. ", distance=" .. fdist(distance_m)
    end
    self._sched:info(Iterator.join("\n", Iterator.imap(show, ipairs(ids))))
  else
    local speedlimits = Iterator.totable(self._iterspeedlimits())
    local distances_m = Iterator.totable(Iterator.keys(pairs(speedlimits)))
    table.sort(distances_m)
    local show = function(_, distance_m)
      local limit = speedlimits[distance_m]
      return "type=" .. limit.type .. ", speed=" .. fspeed(limit.speed_mps) ..
               ", distance=" .. fdist(distance_m)
    end
    local posts = Iterator.join("\n", Iterator.imap(show, ipairs(distances_m)))
    self._sched:info("Track: " .. fspeed(self._gettrackspeed_mps()) .. " " ..
                       "Sensed: " ..
                       fspeed(self._trackspeed:gettrackspeed_mps()) .. "\n" ..
                       "Posts: " .. posts)
  end
end

local function showsignals(self)
  local faspect = function(ps)
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
  local fdist = function(m)
    return string.format("%.2f", m * Units.m.toft) .. "ft"
  end
  if debugtrackers then
    local ids = Iterator.totable(
                  Iterator.keys(self._signaltracker:iterobjects()))
    table.sort(ids, function(ida, idb)
      return self._signaltracker:getdistance_m(ida) <
               self._signaltracker:getdistance_m(idb)
    end)
    local show = function(_, id)
      local signal = self._signaltracker:getobject(id)
      local distance_m = self._signaltracker:getdistance_m(id)
      return tostring(id) .. ": state=" .. faspect(signal.prostate) ..
               ", distance=" .. fdist(distance_m)
    end
    self._sched:info(Iterator.join("\n", Iterator.imap(show, ipairs(ids))))
  else
    local restrictsignals = Iterator.totable(self._iterrestrictsignals())
    local distances_m = Iterator.totable(Iterator.keys(pairs(restrictsignals)))
    table.sort(distances_m)
    local show = function(_, distance_m)
      local signal = restrictsignals[distance_m]
      return "state=" .. faspect(signal.prostate) .. ", distance=" ..
               fdist(distance_m)
    end
    self._sched:info(Iterator.join("\n",
                                   Iterator.imap(show, ipairs(distances_m))))
  end
end

--[[
  Braking curve calculation and state tracking
]]

local function calcbrakecurve(self, vf, d, t)
  local a = self._penaltycurve_mps2
  return math.max(
           math.pow(math.pow(a * t, 2) - 2 * a * d + math.pow(vf, 2), 0.5) + a *
             t, vf)
end

local function calctimetopenalty(self, vf, d)
  local a = self._penaltycurve_mps2
  local vi = math.abs(self._getspeed_mps())
  if vi <= vf or a == 0 or vi == 0 then
    return nil
  else
    return (d - (vf * vf - vi * vi) / (2 * a)) / vi
  end
end

local function iteradvancelimithazards(self)
  return Iterator.map(function(id, distance_m)
    local speed_mps = self._limittracker:getobject(id).speed_mps
    return {P._hazardtype.advancelimit, id}, {
      inforce_mps = speed_mps,
      penalty_mps = calcbrakecurve(self, speed_mps + self._penaltylimit_mps,
                                   distance_m, 0),
      alert_mps = calcbrakecurve(self, speed_mps + self._alertlimit_mps,
                                 distance_m, self._alertwarning_s),
      timetopenalty_s = calctimetopenalty(self,
                                          speed_mps + self._penaltylimit_mps,
                                          distance_m)
    }
  end, Iterator.filter(function(_, distance_m)
    if getmovingdirection(self) == direction.forward then
      return distance_m >= 0
    else
      return distance_m <= 0
    end
  end, self._limittracker:iterdistances_m()))
end

local function iterstopsignalhazards(self)
  -- Positive stop disabled until we can figure out how to avoid irritating
  -- activations in yard and platform areas.
  return Iterator.empty()
  --[[return Iterator.map(
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
        return {P._hazardtype.stopsignal, id}, {
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
  )]]
end

local function itercurrentlimithazards(self)
  local track_mps = self._trackspeed:gettrackspeed_mps()
  local consist_mps = self._consistspeed_mps
  local limit_mps
  if track_mps ~= nil and consist_mps ~= nil then
    limit_mps = math.min(track_mps, consist_mps)
  else
    limit_mps = track_mps or consist_mps
  end
  if limit_mps == nil then
    return Iterator.empty()
  else
    return Iterator.singleton({P._hazardtype.currentlimit, limit_mps}, {
      inforce_mps = limit_mps,
      penalty_mps = limit_mps + self._penaltylimit_mps,
      alert_mps = limit_mps + self._alertlimit_mps
    })
  end
end

local function gethazardsdict(self)
  local hazards = TupleDict:new{}
  for k, hazard in iteradvancelimithazards(self) do hazards[k] = hazard end
  local isrestricting = self._cabsig:getpulsecode() == Nec.pulsecode.restrict
  if isrestricting and not self._sched:isstartup() then
    for k, hazard in iterstopsignalhazards(self) do hazards[k] = hazard end
  end
  for k, hazard in itercurrentlimithazards(self) do hazards[k] = hazard end
  return hazards
end

-- Set useful properties once every update. May be subclassed by other
-- implementations.
function P:_update() end

local function setstate(self)
  while true do
    -- Refresh the list of hazards, and maintain persistent hazard state.
    self._hazards = gethazardsdict(self)
    local newstate = TupleDict:new{}
    for k, hazard in TupleDict.pairs(self._hazards) do
      local s = self._hazardstate[k]
      newstate[k] = s == nil and {} or s
    end
    self._hazardstate = newstate

    -- Get the current hazard in force. If this hazard is violated, trip its
    -- persistent flag.
    local inforceid = Iterator.min(Iterator.ltcomp,
                                   Iterator.map(
                                     function(k, hazard)
        return k, hazard.alert_mps
      end, TupleDict.pairs(self._hazards)))
    if inforceid ~= nil and inforceid[1] == P._hazardtype.advancelimit then
      local hazard = self._hazards[inforceid]
      self._hazardstate[inforceid].violated =
        self._hazardstate[inforceid].violated or math.abs(self._getspeed_mps()) >
          hazard.alert_mps
    end
    self._inforceid = inforceid

    -- Call the class-specific update function.
    self:_update()

    -- Activate the debug views if enabled.
    if self._getacknowledge() then
      if debuglimits then showlimits(self) end
      if debugsignals then showsignals(self) end
    end
    self._sched:yield()
  end
end

--[[
  Alert and penalty enforcement
]]

local function tableeq(a, b)
  local an = table.getn(a)
  local bn = table.getn(b)
  if an ~= bn then return false end
  for i = 1, an do if a[i] ~= b[i] then return false end end
  return true
end

-- True if ACSES should enter the alarm state. May be subclassed by other
-- implementations.
function P:_shouldalarm()
  if self._inforceid ~= nil then
    local hazard = self._hazards[self._inforceid]
    return math.abs(self._getspeed_mps()) > hazard.alert_mps
  else
    return false
  end
end

-- True if ACSES should enter the penalty state. (Implies _shouldalarm() is
-- true, too.) May be subclassed by other implementations.
function P:_shouldpenalty()
  if self._inforceid ~= nil then
    local hazard = self._hazards[self._inforceid]
    return math.abs(self._getspeed_mps()) > hazard.penalty_mps
  else
    return false
  end
end

local function penalty(self)
  self._ispenalty = true
  local trippedid = self._inforceid
  if trippedid[1] == P._hazardtype.stopsignal then
    self._sched:select(nil, function()
      return getdirection(self) == direction.stopped
    end)
    self._isalarm = false
    -- Now wait for the signal to upgrade.
    -- TODO: Implement stop release function.
    self._sched:select(nil, function()
      return not tableeq(self._inforceid, trippedid)
    end)
  else
    self._sched:select(nil, function()
      return self._getacknowledge() and not self:_shouldalarm()
    end)
  end
  self._ispenalty = false
end

local function enforce(self)
  while true do
    self._sched:select(nil, function() return self:_shouldalarm() end)
    self._isalarm = true
    local ack = self._sched:select(self._alertwarning_s, self._getacknowledge,
                                   function() return self:_shouldpenalty() end)
    if ack == nil or ack == 2 then
      penalty(self)
    else
      local curve = self._sched:select(nil, function()
        return not self:_shouldalarm()
      end, function() return self:_shouldpenalty() end)
      if curve == 2 then penalty(self) end
    end
    self._isalarm = false
  end
end

-- From the main coroutine, initialize this subsystem.
function P:start()
  if not self._running then
    self._running = true

    self._limitfilter = AcsesLimits:new{iterspeedlimits = self._iterspeedlimits}
    self._limittracker = AcsesTracker:new{
      scheduler = self._sched,
      getspeed_mps = self._getspeed_mps,
      iterbydistance = function()
        return self._limitfilter:iterspeedlimits()
      end
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
    if not self._sched:isstartup() then self._sched:alert("ACSES", "Cut In") end
  end
end

-- From the main coroutine, halt and reset this subsystem.
function P:stop()
  if self._running then
    self._running = false
    for _, co in ipairs(self._coroutines) do self._sched:kill(co) end
    self._limittracker:kill()
    self._signaltracker:kill()
    self._trackspeed:kill()
    initstate(self)
    self._sched:alert("ACSES", "Cut Out")
  end
end

-- Returns the time to penalty countdown for positive stop signals.
function P:gettimetopenalty_s()
  if self:getmode() == P.mode.positivestop then
    local maxttp_s = 60
    -- This cannot be nil because getmode() already checked it.
    local hazard = self._hazards[self._inforceid]
    local ttp_s = hazard.timetopenalty_s
    if not self:_shouldpenalty() and ttp_s ~= nil and ttp_s <= maxttp_s then
      return ttp_s
    end
  end
  return nil
end

-- Returns true when the alarm is sounding.
function P:isalarm() return self._isalarm end

-- Returns true when a penalty brake is applied.
function P:ispenalty() return self._ispenalty end

-- Returns the current enforcing state.
function P:getmode()
  local isstop = self._inforceid ~= nil and self._inforceid[1] ==
                   P._hazardtype.stopsignal
  if isstop and self._hazardstate[self._inforceid].violated then
    return P.mode.positivestop
  else
    return P.mode.normal
  end
end

return P
