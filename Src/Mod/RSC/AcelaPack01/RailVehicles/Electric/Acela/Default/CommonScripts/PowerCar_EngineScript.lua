-- Engine script for the Acela Express operated by Amtrak.

local playersched, anysched
local atc
local acses
local cruise
local alerter
local power
local frontpantoanim, rearpantoanim
local coneanim
local tracteffort
local csflasher
local spark
local state = {
  throttle = 0,
  train_brake = 0,
  acknowledge = false,
  cruisespeed_mps = 0,
  cruiseenabled = false,
  startup = true,
  destinationjoy = 0,

  speed_mps = 0,
  acceleration_mps2 = 0,
  trackspeed_mps = 0,
  speedlimits = {},
  restrictsignals = {},

  powertypes = {},
  awsclearcount = 0,
  raisefrontpantomsg = nil,
  raiserearpantomsg = nil
}

local destscroller
local destinations = {{"No service", 1},
                      {"Philadelphia", 2},
                      {"Trenton", 11},
                      {"Metropark", 18},
                      {"Newark Penn", 24},
                      {"NYC Penn", 27}}

local messageid = {
  -- Reuse ID's from the DTG engine script to avoid conflicts.
  raisefrontpanto = 1207,
  raiserearpanto = 1208,

  -- Used by the Acela coaches. Do not change.
  tiltisolate = 1209,
  destination = 1210
}

local function doalert ()
  state.awsclearcount = math.mod(state.awsclearcount + 1, 2)
end

Initialise = RailWorks.wraperrors(function ()
  playersched = Scheduler:new{}
  anysched = Scheduler:new{}

  atc = Atc:new{
    scheduler = playersched,
    getspeed_mps = function () return state.speed_mps end,
    getacceleration_mps2 = function () return state.acceleration_mps2 end,
    getacknowledge = function () return state.acknowledge end,
    doalert = doalert
  }
  atc:start()

  acses = Acses:new{
    scheduler = playersched,
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
    scheduler = playersched,
    getspeed_mps = function () return state.speed_mps end,
    gettargetspeed_mps = function () return state.cruisespeed_mps end,
    getenabled = function () return state.cruiseenabled end
  }

  alerter = Alerter:new{
    scheduler = playersched,
    getspeed_mps = function () return state.speed_mps end
  }
  alerter:start()

  power = Power:new{available={Power.types.overhead}}

  frontpantoanim = Animation:new{
    scheduler = anysched,
    animation = "frontPanto",
    duration_s = 2
  }
  rearpantoanim = Animation:new{
    scheduler = anysched,
    animation = "rearPanto",
    duration_s = 2
  }

  coneanim = Animation:new{
    scheduler = playersched,
    animation = "cone",
    duration_s = 2
  }

  tracteffort = Average:new{nsamples=30}

  csflasher = Flash:new{
    scheduler = playersched,
    off_on=Atc.cabspeedflash_s,
    on_s=Atc.cabspeedflash_s
  }

  spark = PantoSpark:new{
    scheduler = anysched
  }

  destscroller = RangeScroll:new{
    scheduler = playersched,
    getdirection = function ()
      if state.destinationjoy == -1 then
        return RangeScroll.direction.previous
      elseif state.destinationjoy == 1 then
        return RangeScroll.direction.next
      else
        return RangeScroll.direction.neutral
      end
    end,
    limit = table.getn(destinations)
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
  state.destinationjoy =
    RailWorks.GetControlValue("DestJoy", 0)
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
    "AWSClearCount", 0,
    state.awsclearcount)
end

local function setplayerpantos ()
  local pantoup = RailWorks.GetControlValue("PantographControl", 0) == 1
  local pantosel = RailWorks.GetControlValue("SelPanto", 0)

  local frontup = pantoup and pantosel < 1.5
  local rearup = pantoup and pantosel > 0.5
  frontpantoanim:setanimatedstate(frontup)
  rearpantoanim:setanimatedstate(rearup)
  RailWorks.SendConsistMessage(messageid.raisefrontpanto, frontup, 0)
  RailWorks.SendConsistMessage(messageid.raisefrontpanto, frontup, 1)
  RailWorks.SendConsistMessage(messageid.raiserearpanto, rearup, 0)
  RailWorks.SendConsistMessage(messageid.raiserearpanto, rearup, 1)

  local frontcontact = frontpantoanim:getposition() == 1
  local rearcontact = rearpantoanim:getposition() == 1
  if frontcontact or rearcontact then
    state.powertypes = {Power.types.overhead}
  else
    state.powertypes = {}
  end
end

local function setaipantos ()
  if state.raisefrontpantomsg ~= nil then
    frontpantoanim:setanimatedstate(state.raisefrontpantomsg)
  end
  if state.raiserearpantomsg ~= nil then
    rearpantoanim:setanimatedstate(state.raiserearpantomsg)
  end
end

local function setpantosparks ()
  local frontcontact = frontpantoanim:getposition() == 1
  local rearcontact = rearpantoanim:getposition() == 1
  spark:setsparkstate(frontcontact or rearcontact)
  local isspark = spark:isspark()

  RailWorks.ActivateNode("Front_spark01", frontcontact and isspark)
  RailWorks.ActivateNode("Front_spark02", frontcontact and isspark)
  Call("Spark:Activate", RailWorks.frombool(frontcontact and isspark))

  RailWorks.ActivateNode("Rear_spark01", rearcontact and isspark)
  RailWorks.ActivateNode("Rear_spark02", rearcontact and isspark)
  Call("Spark2:Activate", RailWorks.frombool(rearcontact and isspark))
end

local function settilt ()
  local isolate = RailWorks.GetControlValue("TiltIsolate", 0)
  RailWorks.SendConsistMessage(messageid.tiltisolate, isolate, 0)
  RailWorks.SendConsistMessage(messageid.tiltisolate, isolate, 1)
end

local function setcone ()
  local open = RailWorks.GetControlValue("FrontCone", 0) == 1
  coneanim:setanimatedstate(open)
end

local setdestination
do
  local lastselected = 1
  function setdestination ()
    local selected = destscroller:getselected()
    local destination, id = unpack(destinations[selected])
    if lastselected ~= selected then
      RailWorks.showalert(string.upper(destination))
      lastselected = selected
    end

    if RailWorks.GetControlValue("DestOnOff", 0) == 1 then
      RailWorks.SendConsistMessage(messageid.destination, id, 0)
      RailWorks.SendConsistMessage(messageid.destination, id, 1)
    else
      RailWorks.SendConsistMessage(messageid.destination, 0, 0)
      RailWorks.SendConsistMessage(messageid.destination, 0, 1)
    end
  end
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

local setadu
do
  local lastsignalspeed_mph
  function setadu ()
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
end

local function updateplayer ()
  readcontrols()
  readlocostate()

  playersched:update()
  anysched:update()
  frontpantoanim:update()
  rearpantoanim:update()
  coneanim:update()

  writelocostate()
  setplayerpantos()
  setpantosparks()
  settilt()
  setcone()
  setdestination()
  setstatusscreen()
  setdrivescreen()
  setcutin()
  setadu()

  -- Prevent the acknowledge button from sticking if the button on the HUD is
  -- clicked.
  if state.acknowledge then
    RailWorks.SetControlValue("AWSReset", 0, 0)
  end
end

local function updateai ()
  anysched:update()
  frontpantoanim:update()
  rearpantoanim:update()

  setaipantos()
  setpantosparks()
end

Update = RailWorks.wraperrors(function (_)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer()
  else
    updateai()
  end
end)

OnControlValueChange = RailWorks.SetControlValue

OnCustomSignalMessage = RailWorks.wraperrors(function (message)
  power:receivemessage(message)
  atc:receivemessage(message)
end)

OnConsistMessage = RailWorks.wraperrors(function (message, argument, direction)
  -- Cross the pantograph states. We assume the slave engine is flipped.
  if message == messageid.raisefrontpanto then
    state.raiserearpantomsg = argument == "true"
  elseif message == messageid.raiserearpanto then
    state.raisefrontpantomsg = argument == "true"
  end
end)