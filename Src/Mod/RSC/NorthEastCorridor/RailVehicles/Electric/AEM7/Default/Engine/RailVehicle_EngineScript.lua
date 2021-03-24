-- Engine script for the EMD AEM-7 operated by Amtrak.

local sched
local atcalert, atc
local acsesalert, acses
local cruise
local alerter
local power
local cs1flasher
local sigspeedflasher
local state = {
  throttle=0,
  train_brake=0,
  acknowledge=false,
  cruisespeed_mps=0,
  cruiseenabled=false,

  speed_mps=0,
  acceleration_mps2=0,
  trackspeed_mps=0,
  speedlimits={},
  restrictsignals={}
}
local onebeep_s = 0.3

Initialise = RailWorks.wraperrors(function ()
  sched = Scheduler:new{}

  atcalert = Tone:new{
    scheduler = sched,
    time_s = onebeep_s
  }
  atc = Atc:new{
    scheduler = sched,
    getspeed_mps = function () return state.speed_mps end,
    getacceleration_mps2 = function () return state.acceleration_mps2 end,
    getacknowledge = function () return state.acknowledge end,
    doalert = function () atcalert:trigger() end
  }
  atc:start()

  acsesalert = Tone:new{
    scheduler = sched,
    time_s = onebeep_s
  }
  acses = Acses:new{
    scheduler = sched,
    getspeed_mps = function () return state.speed_mps end,
    gettrackspeed_mps = function () return state.trackspeed_mps end,
    iterspeedlimits = function () return pairs(state.speedlimits) end,
    iterrestrictsignals = function () return pairs(state.restrictsignals) end,
    getacknowledge = function () return state.acknowledge end,
    doalert = function () acsesalert:trigger() end
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

  cs1flasher = Flash:new{
    scheduler = sched,
    off_s = Nec.cabspeedflash_s,
    on_s = Nec.cabspeedflash_s
  }

  sigspeedflasher = Flash:new{
    scheduler = sched,
    off_s = 0.5,
    on_s = 1.5
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
end

local function readlocostate ()
  local cruise_mph = RailWorks.GetControlValue("CruiseSet", 0)
  state.cruisespeed_mps =
    cruise_mph*Units.mph.tomps
  state.cruiseenabled =
    cruise_mph > 10
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
  if RailWorks.GetControlValue("PantographControl", 0) == 1 then
    power:setcollectors(Power.types.overhead)
  else
    power:setcollectors()
  end
end

local function writelocostate ()
  local penalty = atc:ispenalty() or acses:ispenalty() or alerter:ispenalty()
  do
    local v
    if not power:haspower() then
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
    if penalty then v = 0.99
    else v = state.train_brake end
    RailWorks.SetControlValue("TrainBrakeControl", 0, v)
  end
  do
    local v
    if penalty then v = 0.5
    else v = state.train_brake/2 end -- "blended braking"
    RailWorks.SetControlValue("DynamicBrake", 0, v)
  end

  -- Used for the dynamic brake sound?
  RailWorks.SetControlValue(
    "DynamicCurrent", 0, math.abs(RailWorks.GetControlValue("Ammeter", 0)))

  RailWorks.SetControlValue(
    "AWS", 0,
    RailWorks.frombool(atc:isalarm() or acses:isalarm() or alerter:isalarm()))
  RailWorks.SetControlValue(
    "AWSWarnCount", 0,
    RailWorks.frombool(alerter:isalarm()))
  do
    local alert = atcalert:isplaying() or acsesalert:isplaying()
    local alarm = atc:isalarm() or acses:isalarm()
    RailWorks.SetControlValue(
      "OverSpeedAlert", 0,
      RailWorks.frombool(alert or alarm))
  end
end

local function setcabsignal ()
  local f = 2 -- cab speed flash

  local acsesmode = acses:getmode()
  local atccode = atc:getpulsecode()
  local cs, cs1, cs2
  if acsesmode == Acses.mode.positivestop then
    cs, cs1, cs2 = 7, 0, 0 -- Unfortunately, we can't show a Stop aspect.
  elseif acsesmode == Acses.mode.approachmed30 then
    cs, cs1, cs2 = 6, 0, 1
  elseif atccode == Nec.pulsecode.restrict then
    cs, cs1, cs2 = 7, 0, 0
  elseif atccode == Nec.pulsecode.approach then
    cs, cs1, cs2 = 6, 0, 0
  elseif atccode == Nec.pulsecode.approachmed then
    cs, cs1, cs2 = 4, 0, 1
  elseif atccode == Nec.pulsecode.cabspeed60 then
    cs, cs1, cs2 = 3, f, 0
  elseif atccode == Nec.pulsecode.cabspeed80 then
    cs, cs1, cs2 = 2, f, 0
  elseif atccode == Nec.pulsecode.clear100
      or atccode == Nec.pulsecode.clear125
      or atccode == Nec.pulsecode.clear150 then
    cs, cs1, cs2 = 1, 1, 0
  else
    cs, cs1, cs2 = 8, 0, 0
  end

  RailWorks.SetControlValue("CabSignal", 0, cs)

  cs1flasher:setflashstate(cs1 == f)
  local cs1light = cs1 == 1 or (cs1 == f and cs1flasher:ison())
  RailWorks.SetControlValue("CabSignal1", 0, RailWorks.frombool(cs1light))

  RailWorks.SetControlValue("CabSignal2", 0, cs2)
end

local function toroundedmph (v)
  return math.floor(v*Units.mps.tomph + 0.5)
end

local function settrackspeed ()
  local signalspeed_mph = toroundedmph(atc:getinforcespeed_mps())
  local trackspeed_mph = toroundedmph(acses:getinforcespeed_mps())
  local canshowsigspeed = signalspeed_mph ~= 100
    and signalspeed_mph ~= 125
    and signalspeed_mph ~= 150
  local showsigspeed = not canshowsigspeed
    and not (acses:isalarm() or acsesalert:isplaying())
    and (signalspeed_mph < trackspeed_mph or atc:isalarm() or atcalert:isplaying())

  sigspeedflasher:setflashstate(showsigspeed)

  local show_mph
  local blank = 14.5
  if showsigspeed then
    if sigspeedflasher:ison() then
      show_mph = signalspeed_mph
    else
      show_mph = blank
    end
  else
    show_mph = trackspeed_mph
  end
  RailWorks.SetControlValue("TrackSpeed", 0, show_mph)
end

local function setcablight ()
  local light = RailWorks.GetControlValue("CabLightControl", 0)
  Call("FrontCabLight:Activate", light)
  Call("RearCabLight:Activate", light)
end

local function setcutin ()
  -- Reverse the polarities of the safety systems buttons so they are activated
  -- by default. If we set them ourselves, they won't stick.
  alerter:setrunstate(RailWorks.GetControlValue("AlertControl", 0) == 0)
  local speedcontrol = RailWorks.GetControlValue("SpeedControl", 0) == 0
  atc:setrunstate(speedcontrol)
  acses:setrunstate(speedcontrol)
end

Update = RailWorks.wraperrors(function (_)
  if not RailWorks.GetIsEngineWithKey() then
    RailWorks.EndUpdate()
    return
  end

  readcontrols()
  readlocostate()

  sched:update()

  writelocostate()
  setcabsignal()
  settrackspeed()
  setcablight()
  setcutin()

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
  acses:receivemessage(message)
end)

OnConsistMessage = RailWorks.SendConsistMessage