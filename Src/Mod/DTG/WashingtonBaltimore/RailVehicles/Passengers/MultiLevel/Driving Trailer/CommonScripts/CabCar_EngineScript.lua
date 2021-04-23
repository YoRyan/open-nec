-- Engine script for the Bombardier Multilevel cab car operated by MARC.

local sched
local atc
local acses
local adu
local alerter
local alarmonoff
local ditchflasher
local state = {
  throttle = 0,
  train_brake = 0,
  acknowledge = false,
  headlights = 0,

  speed_mps = 0,
  acceleration_mps2 = 0,
  trackspeed_mps = 0,
  consistlength_m = 0,
  speedlimits = {},
  restrictsignals = {},

  lasthorntime_s = nil
}

Initialise = RailWorks.wraperrors(function ()
  sched = Scheduler:new{}

  atc = Atc:new{
    scheduler = sched,
    getspeed_mps = function () return state.speed_mps end,
    getacceleration_mps2 = function () return state.acceleration_mps2 end,
    getacknowledge = function () return state.acknowledge end,
    doalert = function () adu:doatcalert() end,
    getbrakesuppression = function () return state.train_brake >= 0.6 end
  }

  acses = Acses:new{
    scheduler = sched,
    getspeed_mps = function () return state.speed_mps end,
    gettrackspeed_mps = function () return state.trackspeed_mps end,
    getconsistlength_m = function () return state.consistlength_m end,
    iterspeedlimits = function () return pairs(state.speedlimits) end,
    iterrestrictsignals = function () return pairs(state.restrictsignals) end,
    getacknowledge = function () return state.acknowledge end,
    doalert = function () adu:doacsesalert() end,
    consistspeed_mps = 125*Units.mph.tomps
  }

  local onebeep_s = 1
  adu = NjTransitDigitalAdu:new{
    scheduler = sched,
    atc = atc,
    atcalert_s = onebeep_s,
    acses = acses,
    acsesalert_s = onebeep_s
  }

  atc:start()
  acses:start()

  alerter = Alerter:new{
    scheduler = sched,
    getspeed_mps = function () return state.speed_mps end
  }
  alerter:start()

  -- Modulate the speed reduction alert sound, which normally plays just once.
  alarmonoff = Flash:new{
    scheduler = sched,
    off_s = 0.1,
    on_s = 0.5
  }

  local ditchflash_s = 1
  ditchflasher = Flash:new{
    scheduler = sched,
    off_s = ditchflash_s,
    on_s = ditchflash_s
  }

  RailWorks.BeginUpdate()
end)

local function readcontrols ()
  local throttle = RailWorks.GetControlValue("ThrottleAndBrake", 0)
  local vbrake = RailWorks.GetControlValue("VirtualBrake", 0)
  local change = throttle ~= state.throttle or vbrake ~= state.train_brake
  state.throttle = throttle
  state.train_brake = vbrake
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) == 1
  if state.acknowledge or change then
    alerter:acknowledge()
  end

  if RailWorks.GetControlValue("Horn", 0) > 0 then
    state.lasthorntime_s = sched:clock()
  end

  state.headlights = RailWorks.GetControlValue("HeadlightSwitch", 0)
end

local function readlocostate ()
  state.speed_mps =
    RailWorks.GetControlValue("SpeedometerMPH", 0)*Units.mph.tomps
  state.acceleration_mps2 =
    RailWorks.GetAcceleration()
  state.trackspeed_mps =
    RailWorks.GetCurrentSpeedLimit(1)
  state.consistlength_m =
    RailWorks.GetConsistLength()
  state.speedlimits =
    Iterator.totable(RailWorks.iterspeedlimits(Acses.nlimitlookahead))
  state.restrictsignals =
    Iterator.totable(RailWorks.iterrestrictsignals(Acses.nsignallookahead))
end

local function writelocostate ()
  local penalty = alerter:ispenalty() or atc:ispenalty() or acses:ispenalty()
  do
    local throttle, dynbrake
    if penalty then
      throttle = 0
      dynbrake = 0
    else
      throttle = math.max(state.throttle, 0)
      dynbrake = math.max(-state.throttle, 0)
    end
    RailWorks.SetControlValue("Regulator", 0, throttle)
    RailWorks.SetControlValue("DynamicBrake", 0, dynbrake)
  end
  do
    local v
    if penalty then v = 0.6
    else v = state.train_brake end
    RailWorks.SetControlValue("TrainBrakeControl", 0, v)
  end

  RailWorks.SetControlValue(
    "Reverser", 0, RailWorks.GetControlValue("UserVirtualReverser", 0))
  RailWorks.SetControlValue(
    "Horn", 0, RailWorks.GetControlValue("VirtualHorn", 0))
  RailWorks.SetControlValue(
    "Bell", 0, RailWorks.GetControlValue("VirtualBell", 0))
  RailWorks.SetControlValue(
    "Wipers", 0, RailWorks.GetControlValue("VirtualWipers", 0))
  RailWorks.SetControlValue(
    "Sander", 0, RailWorks.GetControlValue("VirtualSander", 0))

  do
    local atcalarm = atc:isalarm()
    local acsesalarm = acses:isalarm()
    local alertalarm = alerter:isalarm()
    RailWorks.SetControlValue(
      "ACSES_Alert", 0,
      RailWorks.frombool(alertalarm))
    RailWorks.SetControlValue(
      "ACSES_AlertIncrease", 0,
      RailWorks.frombool(adu:isatcalert() or adu:isacsesalert()))
    alarmonoff:setflashstate(atcalarm or acsesalarm)
    RailWorks.SetControlValue(
      "ACSES_AlertDecrease", 0,
      RailWorks.frombool(alarmonoff:ison()))
    RailWorks.SetControlValue(
      "AWSWarnCount", 0,
      RailWorks.frombool(atcalarm or acsesalarm or alertalarm))
  end
end

local function toroundedmph (v)
  return math.floor(v*Units.mps.tomph + 0.5)
end

local function getdigit (v, place)
  local tens = math.pow(10, place)
  if place ~= 0 and v < tens then
    return -1
  else
    return math.floor(math.mod(v, tens*10)/tens)
  end
end

local function getdigitguide (v)
  if v < 10 then return 0
  else return math.floor(math.log10(v)) end
end

local function setspeedometer ()
  do
    local restrict = adu:isspeedrestriction()
    local rspeed_mph = toroundedmph(math.abs(state.speed_mps))
    local h = getdigit(rspeed_mph, 2)
    local t = getdigit(rspeed_mph, 1)
    local u = getdigit(rspeed_mph, 0)
    if restrict then
      RailWorks.SetControlValue("SpeedH", 0, -1)
      RailWorks.SetControlValue("SpeedT", 0, -1)
      RailWorks.SetControlValue("SpeedU", 0, -1)
      RailWorks.SetControlValue("Speed2H", 0, h)
      RailWorks.SetControlValue("Speed2T", 0, t)
      RailWorks.SetControlValue("Speed2U", 0, u)
    else
      RailWorks.SetControlValue("SpeedH", 0, h)
      RailWorks.SetControlValue("SpeedT", 0, t)
      RailWorks.SetControlValue("SpeedU", 0, u)
      RailWorks.SetControlValue("Speed2H", 0, -1)
      RailWorks.SetControlValue("Speed2T", 0, -1)
      RailWorks.SetControlValue("Speed2U", 0, -1)
    end
    RailWorks.SetControlValue("SpeedP", 0, getdigitguide(rspeed_mph))
  end
  RailWorks.SetControlValue(
    "ACSES_SpeedGreen", 0, adu:getgreenzone_mph(state.speed_mps))
  RailWorks.SetControlValue(
    "ACSES_SpeedRed", 0, adu:getredzone_mph(state.speed_mps))
end

local function setcablight ()
  local dome = RailWorks.GetControlValue("CabLight", 0)
  RailWorks.ActivateNode("cablights", dome == 1)
  Call("CabLight:Activate", dome)
  Call("CabLight2:Activate", dome)
end

local function setditchlights ()
  local horntime_s = 30
  local show = state.lasthorntime_s ~= nil
    and sched:clock() <= state.lasthorntime_s + horntime_s
  ditchflasher:setflashstate(show)
  local flashleft = ditchflasher:ison()
  do
    local showleft = show and flashleft
    RailWorks.ActivateNode("ditch_left", showleft)
    Call("Ditch_L:Activate", RailWorks.frombool(showleft))
  end
  do
    local showright = show and not flashleft
    RailWorks.ActivateNode("ditch_right", showright)
    Call("Ditch_R:Activate", RailWorks.frombool(showright))
  end
end

local function setstatuslights ()
  RailWorks.ActivateNode("LightsBlue", RailWorks.GetIsEngineWithKey())
  -- The door open light, except I have no idea how to program it.
  RailWorks.ActivateNode("LightsRed", false)
  -- The brake application lights, except I have no idea how to program them.
  RailWorks.ActivateNode("LightsYellow", false)
  RailWorks.ActivateNode("LightsGreen", true)
end

local function updateplayer ()
  readcontrols()
  readlocostate()

  sched:update()

  writelocostate()
  setspeedometer()
  setcablight()
  setditchlights()
  setstatuslights()

  -- Prevent the acknowledge button from sticking if the button on the HUD is
  -- clicked.
  if state.acknowledge then
    RailWorks.SetControlValue("AWSReset", 0, 0)
  end
end

local function updateai ()
  setcablight()
  setditchlights()
  setstatuslights()
end

Update = RailWorks.wraperrors(function (_)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer()
  else
    updateai()
    RailWorks.EndUpdate()
    return
  end
end)

OnControlValueChange = RailWorks.wraperrors(function (name, index, value)
  -- Synchronize headlight controls.
  if name == "HeadlightSwitch" then
    if value == 0 then
      RailWorks.SetControlValue("Headlights", 0, 0)
    elseif value == 1 then
      RailWorks.SetControlValue("Headlights", 0, 2)
    elseif value == 2 then
      RailWorks.SetControlValue("Headlights", 0, 3)
    end
  elseif name == "Headlights" then
    if value == 0 or value == 1 then
      RailWorks.SetControlValue("HeadlightSwitch", 0, 0)
    elseif value == 2 then
      RailWorks.SetControlValue("HeadlightSwitch", 0, 1)
    elseif value == 3 then
      RailWorks.SetControlValue("HeadlightSwitch", 0, 2)
    end
  end

  RailWorks.SetControlValue(name, index, value)
end)

OnCustomSignalMessage = RailWorks.wraperrors(function (message)
  atc:receivemessage(message)
  acses:receivemessage(message)
end)

OnConsistMessage = RailWorks.Engine_SendConsistMessage