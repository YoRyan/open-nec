-- Engine script for the EMD AEM-7 operated by Amtrak.

local sched = nil
local alerttone = nil
local atc = nil
local acses = nil
local cruise = nil
local alerter = nil
local power = nil
local cs1flasher = nil
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
  restrictsignals={},

  powertypes={}
}
local onebeep_s = 0.3

Initialise = RailWorks.wraperrors(function ()
  sched = Scheduler:new{}

  alerttone = Tone:new{scheduler=sched, time_s=onebeep_s}

  atc = Atc:new{
    scheduler = sched,
    getspeed_mps = function () return state.speed_mps end,
    getacceleration_mps2 = function () return state.acceleration_mps2 end,
    getacknowledge = function () return state.acknowledge end,
    doalert = function () alerttone:trigger() end
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
    doalert = function () alerttone:trigger() end
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
    scheduler=sched,
    off_s=Atc.cabspeedflash_s,
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
end

local function readlocostate ()
  state.cruisespeed_mps =
    RailWorks.GetControlValue("CruiseSet", 0)*Units.mph.tomps
  state.cruiseenabled =
    RailWorks.GetControlValue("CruiseSet", 0) > 10
  state.speed_mps =
    RailWorks.GetSpeed()
  state.acceleration_mps2 =
    RailWorks.GetAcceleration()
  state.trackspeed_mps =
    RailWorks.GetCurrentSpeedLimit(1)
  state.speedlimits =
    Iterator.totable(RailWorks.iterspeedlimits(Acses.nlimitlookahead))
  state.restrictsignals =
    Iterator.totable(RailWorks.iterrestrictsignals(Acses.nsignallookahead))
  if RailWorks.GetControlValue("PantographControl", 0) == 1 then
    state.powertypes = {Power.types.overhead}
  else
    state.powertypes = {}
  end
end

local function writelocostate ()
  local penalty = atc:ispenalty() or acses:ispenalty() or alerter:ispenalty()
  do
    local v
    if not power:haspower(unpack(state.powertypes)) then
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
  RailWorks.SetControlValue(
    "OverSpeedAlert", 0,
    RailWorks.frombool(alerttone:isplaying() or atc:isalarm() or acses:isalarm()))
  RailWorks.SetControlValue(
    "TrackSpeed", 0,
    math.floor(acses:getinforcespeed_mps()*Units.mps.tomph + 0.5))
end

local function setcabsignal ()
  local f = 2 -- cab speed flash

  local code = atc:getpulsecode()
  local cs, cs1, cs2
  if code == Atc.pulsecode.restrict then
    cs, cs1, cs2 = 7, 0, 0
  elseif code == Atc.pulsecode.approach then
    cs, cs1, cs2 = 6, 0, 0
  elseif code == Atc.pulsecode.approachmed then
    cs, cs1, cs2 = 4, 0, 1
  elseif code == Atc.pulsecode.cabspeed60 then
    cs, cs1, cs2 = 3, f, 0
  elseif code == Atc.pulsecode.cabspeed80 then
    cs, cs1, cs2 = 2, f, 0
  elseif code == Atc.pulsecode.clear100
      or code == Atc.pulsecode.clear125
      or code == Atc.pulsecode.clear150 then
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
end)