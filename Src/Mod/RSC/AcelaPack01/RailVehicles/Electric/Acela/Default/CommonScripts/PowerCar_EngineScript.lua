-- Engine script for the Acela Express operated by Amtrak.

local sched
local atc
local acses
local cruise
local alerter
local power
local frontpantoanim, rearpantoanim
local tracteffort
local csflasher
local state = {
  throttle = 0,
  train_brake = 0,
  acknowledge = false,
  cruisespeed_mps = 0,
  cruiseenabled = false,
  startup = true,

  speed_mps = 0,
  acceleration_mps2 = 0,
  trackspeed_mps = 0,
  speedlimits = {},
  restrictsignals = {},

  powertypes = {}
}
local awsclearcount = 0
local lastsignalspeed_mph

local function doalert ()
  awsclearcount = math.mod(awsclearcount + 1, 2)
end

Initialise = RailWorks.wraperrors(function ()
  sched = Scheduler:new{}

  atc = Atc:new{
    scheduler = sched,
    getspeed_mps = function () return state.speed_mps end,
    getacceleration_mps2 = function () return state.acceleration_mps2 end,
    getacknowledge = function () return state.acknowledge end,
    doalert = doalert
  }
  atc:start()

  acses = Acses:new{
    scheduler = sched,
    atc = atc,
    getspeed_mps = function () return state.speed_mps end,
    gettrackspeed_mps = function () return state.trackspeed_mps end,
    iterspeedlimits = function () return pairs(state.speedlimits) end,
    iterrestrictsignals = function () return pairs(state.restrictsignals) end,
    getacknowledge = function () return state.acknowledge end,
    doalert = doalert
  }
  acses:start()

  cruise = Cruise:new{
    scheduler = sched,
    getspeed_mps = function () return state.speed_mps end,
    gettargetspeed_mps = function () return state.cruisespeed_mps end,
    getenabled = function () return state.cruiseenabled end
  }

  alerter = Alerter:new{
    scheduler = sched,
    getspeed_mps = function () return state.speed_mps end
  }
  alerter:start()

  power = Power:new{available={Power.types.overhead}}

  frontpantoanim = Animation:new{
    scheduler = sched,
    animation = "frontPanto",
    duration_s = 2
  }
  rearpantoanim = Animation:new{
    scheduler = sched,
    animation = "rearPanto",
    duration_s = 2
  }

  tracteffort = Average:new{nsamples=30}

  csflasher = Flash:new{
    scheduler = sched,
    off_on=Atc.cabspeedflash_s,
    on_s=Atc.cabspeedflash_s
  }

  RailWorks.BeginUpdate()
end)

local function readcontrols ()
  local vthrottle = RailWorks.GetControlValue("VirtualThrottle", 0)
  local vbrake = RailWorks.GetControlValue("VirtualBrake", 0)
  local change = vthrottle ~= state.throttle or vbrake ~= state.train_brake
  state.throttle = vthrottle
  state.train_brake = vbrake
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) == 1
  if state.acknowledge or change then
    alerter:acknowledge()
  end

  state.startup =
    RailWorks.GetControlValue("Startup", 0) == 1
  state.cruisespeed_mps =
    RailWorks.GetControlValue("CruiseControlSpeed", 0)*Units.mph.tomps
  state.cruiseenabled =
    RailWorks.GetControlValue("CruiseControl", 0) == 1
end

local function readpantographs ()
  local pantoup = RailWorks.GetControlValue("PantographControl", 0) == 1
  local pantosel = RailWorks.GetControlValue("SelPanto", 0)
  frontpantoanim:setanimatedstate(pantoup and pantosel < 1.5)
  rearpantoanim:setanimatedstate(pantoup and pantosel > 0.5)
  if frontpantoanim:getposition() == 1 or rearpantoanim:getposition() == 1 then
    state.powertypes = {Power.types.overhead}
  else
    state.powertypes = {}
  end
end

local function readlocostate ()
  state.speed_mps =
    RailWorks.GetControlValue("SpeedometerMPH", 0)*Units.mph.tomps
  state.acceleration_mps2 =
    RailWorks.GetAcceleration()
  state.trackspeed_mps =
    RailWorks.GetCurrentSpeedLimit(1)
  state.speedlimits =
    Iterator.totable(RailWorks.iterspeedlimits(Acses.nlimitlookahead))
  state.restrictsignals =
    Iterator.totable(RailWorks.iterrestrictsignals(Acses.nsignallookahead))
end

local function haspower ()
  return power:haspower(unpack(state.powertypes)) and state.startup
end

local function getdigit (v, place)
  local tens = math.pow(10, place)
  if place ~= 0 and v < tens then
    return -1
  else
    return math.floor(math.mod(v, tens*10)/tens)
  end
end

local function writelocostate ()
  local penalty = alerter:ispenalty() or atc:ispenalty() or acses:ispenalty()
  do
    local v
    if not haspower() then
      v = 0
    elseif penalty then
      v = 0
    elseif state.cruiseenabled then
      v = math.min(state.throttle, cruise:getthrottle())
    else
      v = state.throttle
    end
    RailWorks.SetControlValue("Regulator", 0, v)
  end
  do
    local v
    if penalty then v = 0.6
    else v = state.train_brake end
    RailWorks.SetControlValue("TrainBrakeControl", 0, v)
  end

  RailWorks.SetControlValue(
    "AWSWarnCount", 0,
    RailWorks.frombool(alerter:isalarm() or atc:isalarm() or acses:isalarm()))
  RailWorks.SetControlValue(
    "AWSClearCount", 0, awsclearcount)
end

local function setstatusscreen ()
  RailWorks.SetControlValue(
    "ControlScreenIzq", 0, RailWorks.frombool(not haspower()))
  do
    local frontpantoup = frontpantoanim:getposition() == 1
    local rearpantoup = rearpantoanim:getposition() == 1
    local indicator
    if not frontpantoup and not rearpantoup then
      indicator = -1
    elseif not frontpantoup and rearpantoup then
      indicator = 2
    elseif frontpantoup and not rearpantoup then
      indicator = 0
    elseif frontpantoup and rearpantoup then
      indicator = 1
    end
    RailWorks.SetControlValue("PantoIndicator", 0, indicator)
  end
  tracteffort:sample(RailWorks.GetTractiveEffort()*300)
  RailWorks.SetControlValue("Effort", 0, tracteffort:get())
end

local function setdrivescreen ()
  RailWorks.SetControlValue(
    "ControlScreenDer", 0, RailWorks.frombool(not haspower()))
  do
    local speed_mph = math.floor(state.speed_mps*Units.mps.tomph + 0.5)
    RailWorks.SetControlValue("SPHundreds", 0, getdigit(speed_mph, 2))
    RailWorks.SetControlValue("SPTens", 0, getdigit(speed_mph, 1))
    RailWorks.SetControlValue("SPUnits", 0, getdigit(speed_mph, 0))

    local speedlog10 = math.log10(speed_mph)
    local offset
    if speedlog10 > 1e9 or speedlog10 < 0 then
      offset = 0
    else
      offset = math.floor(speedlog10)
    end
    RailWorks.SetControlValue("SpeedoGuide", 0, offset)
  end
  do
    local v
    if state.cruiseenabled then v = 8
    else v = math.floor(state.throttle*6 + 0.5) end
    RailWorks.SetControlValue("PowerState", 0, v)
  end
end

local function setcutin ()
  -- Reverse the polarities so that safety systems are on by default.
  atc:setrunstate(RailWorks.GetControlValue("ATCCutIn", 0) == 0)
  acses:setrunstate(RailWorks.GetControlValue("ACSESCutIn", 0) == 0)
end

local function setadu ()
  local pulsecode =
    atc:getpulsecode()
  do
    local signalspeed_mph =
      math.floor(Atc.amtrakpulsecodespeed_mps(pulsecode)*Units.mps.tomph + 0.5)
    -- TODO: Handle 100, 125, and 150 mph correctly.
    -- Can't set the signal speed continuously, or else the digits flash
    -- randomly for some reason.
    if signalspeed_mph ~= lastsignalspeed_mph then
      RailWorks.SetControlValue("SignalSpeed", 0, signalspeed_mph)
      lastsignalspeed_mph = signalspeed_mph
    end
  end
  do
    local f = 2 -- cab speed flash
    local n, l, s, m, r
    if pulsecode == Atc.pulsecode.restrict then
      n, l, s, m, r = 0, 0, 1, 0, 1
    elseif pulsecode == Atc.pulsecode.approach then
      n, l, s, m, r = 0, 1, 0, 0, 0
    elseif pulsecode == Atc.pulsecode.approachmed then
      n, l, s, m, r = 0, 1, 0, 1, 0
    elseif pulsecode == Atc.pulsecode.cabspeed60
        or pulsecode == Atc.pulsecode.cabspeed80 then
      n, l, s, m, r = f, 0, 0, 0, 0
    elseif pulsecode == Atc.pulsecode.clear100
        or pulsecode == Atc.pulsecode.clear125
        or pulsecode == Atc.pulsecode.clear150 then
      n, l, s, m, r = 1, 0, 0, 0, 0
    else
      n, l, s, m, r = 0, 0, 0, 0, 0
    end
    csflasher:setflashstate(n == f)
    local nlight = n == 1 or (n == f and csflasher:ison())
    RailWorks.SetControlValue("SigN", 0, RailWorks.frombool(nlight))
    RailWorks.SetControlValue("SigL", 0, l)
    RailWorks.SetControlValue("SigS", 0, s)
    RailWorks.SetControlValue("SigM", 0, m)
    RailWorks.SetControlValue("SigR", 0, r)
  end
  do
    local acsesspeed_mph =
      math.floor(acses:getinforcespeed_mps()*Units.mps.tomph + 0.5)
    RailWorks.SetControlValue("TSHundreds", 0, getdigit(acsesspeed_mph, 2))
    RailWorks.SetControlValue("TSTens", 0, getdigit(acsesspeed_mph, 1))
    RailWorks.SetControlValue("TSUnits", 0, getdigit(acsesspeed_mph, 0))
  end
end

Update = RailWorks.wraperrors(function (_)
  if not RailWorks.GetIsEngineWithKey() then
    RailWorks.EndUpdate()
    return
  end

  readcontrols()
  readpantographs()
  readlocostate()

  sched:update()
  frontpantoanim:update()
  rearpantoanim:update()

  writelocostate()
  setstatusscreen()
  setdrivescreen()
  setcutin()
  setadu()

  -- Prevent the acknowledge button from sticking if the button on the HUD is
  -- clicked.
  if state.acknowledge then
    RailWorks.SetControlValue("AWSReset", 0, 0)
  end
end)

OnControlValueChange = RailWorks.SetControlValue

OnCustomSignalMessage = RailWorks.wraperrors(function (message)
  power:receivemessage(message)
  atc:receivemessage(message)
end)