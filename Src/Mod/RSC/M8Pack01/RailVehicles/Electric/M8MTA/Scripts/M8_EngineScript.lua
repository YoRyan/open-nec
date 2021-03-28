-- Engine script for the Kawasaki M8 operated by Metro-North.

local playersched, anysched
local atc
local acses
local adu
local alerter
local alarmonoff
local ditchflasher
local spark
local state = {
  throttle = 0,
  acknowledge = false,

  speed_mps = 0,
  acceleration_mps2 = 0,
  trackspeed_mps = 0,
  consistlength_m = 0,
  speedlimits = {},
  restrictsignals = {},

  lasthorntime_s = nil
}

Initialise = RailWorks.wraperrors(function ()
  playersched = Scheduler:new{}
  anysched = Scheduler:new{}

  atc = Atc:new{
    scheduler = playersched,
    getspeed_mps = function () return state.speed_mps end,
    getacceleration_mps2 = function () return state.acceleration_mps2 end,
    getacknowledge = function () return state.acknowledge end,
    doalert = function () adu:doatcalert() end,
    getbrakesuppression = function () return state.throttle <= -0.4 end
  }

  acses = Acses:new{
    scheduler = playersched,
    getspeed_mps = function () return state.speed_mps end,
    gettrackspeed_mps = function () return state.trackspeed_mps end,
    getconsistlength_m = function () return state.consistlength_m end,
    iterspeedlimits = function () return pairs(state.speedlimits) end,
    iterrestrictsignals = function () return pairs(state.restrictsignals) end,
    getacknowledge = function () return state.acknowledge end,
    doalert = function () adu:doacsesalert() end,
    restrictingspeed_mps = 15*Units.mph.tomps
  }

  local alert_s = 1
  adu = MetroNorthAdu:new{
    scheduler = playersched,
    atc = atc,
    atcalert_s = alert_s,
    acses = acses,
    acsesalert_s = alert_s
  }

  atc:start()
  acses:start()

  alerter = Alerter:new{
    scheduler = playersched,
    getspeed_mps = function () return state.speed_mps end
  }
  alerter:start()

  -- Modulate the speed reduction alert sound, which normally plays just once.
  alarmonoff = Flash:new{
    scheduler = playersched,
    off_s = 0.1,
    on_s = 0.5
  }

  local ditchflash_s = 1
  ditchflasher = Flash:new{
    scheduler = playersched,
    off_s = ditchflash_s,
    on_s = ditchflash_s
  }

  spark = PantoSpark:new{
    scheduler = anysched
  }

  RailWorks.BeginUpdate()
end)

local function readcontrols ()
  local throttle = RailWorks.GetControlValue("ThrottleAndBrake", 0)
  local change = throttle ~= state.throttle
  state.throttle = throttle
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) == 1
  if state.acknowledge or change then
    alerter:acknowledge()
  end

  if RailWorks.GetControlValue("Horn", 0) == 1 then
    state.lasthorntime_s = playersched:clock()
  end

  state.headlights = RailWorks.GetControlValue("Headlights", 0)
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
  do
    local throttle, brake
    if alerter:ispenalty() or atc:ispenalty() or acses:ispenalty() then
      throttle = 0
      brake = 0.85
    else
      throttle = math.max(state.throttle, 0)
      brake = math.max(-state.throttle, 0)
    end
    RailWorks.SetControlValue("Regulator", 0, throttle)
    RailWorks.SetControlValue("TrainBrakeControl", 0, brake)
    -- TODO: Also set DynamicBrake using DTG's algorithm.
  end

  alarmonoff:setflashstate(atc:isalarm() or acses:isalarm())
  RailWorks.SetControlValue(
    "SpeedReductionAlert", 0,
    RailWorks.frombool(alarmonoff:ison()))
  RailWorks.SetControlValue(
    "SpeedIncreaseAlert", 0,
    RailWorks.frombool(adu:isatcalert() or adu:isacsesalert()))
end

local function round (v)
  return math.floor(v + 0.5)
end

local function getdigit (v, place)
  local tens = math.pow(10, place)
  if place ~= 0 and v < tens then
    return -1
  else
    return math.floor(math.mod(v, tens*10)/tens)
  end
end

local function setdrivescreen ()
  local speed_mph = round(state.speed_mps*Units.mps.tomph)
  RailWorks.SetControlValue("SpeedoHundreds", 0, getdigit(speed_mph, 2))
  RailWorks.SetControlValue("SpeedoTens", 0, getdigit(speed_mph, 1))
  RailWorks.SetControlValue("SpeedoUnits", 0, getdigit(speed_mph, 0))

  local bp_psi = round(RailWorks.GetControlValue("AirBrakePipePressurePSI", 0))
  RailWorks.SetControlValue("PipeHundreds", 0, getdigit(bp_psi, 2))
  RailWorks.SetControlValue("PipeTens", 0, getdigit(bp_psi, 1))
  RailWorks.SetControlValue("PipeUnits", 0, getdigit(bp_psi, 0))

  local bc_psi = round(RailWorks.GetControlValue("TrainBrakeCylinderPressurePSI", 0))
  RailWorks.SetControlValue("CylinderHundreds", 0, getdigit(bc_psi, 2))
  RailWorks.SetControlValue("CylinderTens", 0, getdigit(bc_psi, 1))
  RailWorks.SetControlValue("CylinderUnits", 0, getdigit(bc_psi, 0))
end

local function setcutin ()
  if not playersched:isstartup() then
    atc:setrunstate(RailWorks.GetControlValue("ATCCutIn", 0) == 1)
    acses:setrunstate(RailWorks.GetControlValue("ACSESCutIn", 0) == 1)
  end
end

local function setadu ()
  local signalspeed_mph = adu:getsignalspeed_mph()
  do
    local aspect = adu:getaspect()
    local n, l, m, r, s
    if aspect == MetroNorthAdu.aspect.stop then
      n, l, m, r, s = 0, 0, 0, 0, 1
    elseif aspect == MetroNorthAdu.aspect.restrict then
      n, l, m, r, s = 0, 0, 0, 1, 0
    elseif aspect == MetroNorthAdu.aspect.medium then
      n, l, m, r, s = 0, 0, 1, 0, 0
    elseif aspect == MetroNorthAdu.aspect.limited then
      n, l, m, r, s = 0, 1, 0, 0, 0
    elseif aspect == MetroNorthAdu.aspect.normal then
      n, l, m, r, s = 1, 0, 0, 0, 0
    end
    RailWorks.SetControlValue("SigN", 0, n)
    RailWorks.SetControlValue("SigL", 0, l)
    RailWorks.SetControlValue("SigM", 0, m)
    RailWorks.SetControlValue("SigR", 0, r)
    RailWorks.SetControlValue("SigS", 0, s)
  end
  if signalspeed_mph == nil then
    RailWorks.SetControlValue("SignalSpeed", 0, 1) -- blank
  else
    RailWorks.SetControlValue("SignalSpeed", 0, signalspeed_mph)
  end
  do
    local civilspeed_mph = adu:getcivilspeed_mph()
    if civilspeed_mph == nil then
      RailWorks.SetControlValue("TrackSpeedHundreds", 0, 0)
      RailWorks.SetControlValue("TrackSpeedTens", 0, -1)
      RailWorks.SetControlValue("TrackSpeedUnits", 0, -1)
    else
      RailWorks.SetControlValue("TrackSpeedHundreds", 0, getdigit(civilspeed_mph, 2))
      RailWorks.SetControlValue("TrackSpeedTens", 0, getdigit(civilspeed_mph, 1))
      RailWorks.SetControlValue("TrackSpeedUnits", 0, getdigit(civilspeed_mph, 0))
    end
  end
end

local function setpantospark ()
  local contact = false
  spark:setsparkstate(contact)

  local isspark = spark:isspark()
  RailWorks.ActivateNode("panto_spark", isspark)
  Call("Spark:Activate", RailWorks.frombool(isspark))
end

local function setinteriorlights ()
  do
    local cab = RailWorks.GetControlValue("Cablight", 0)
    Call("Cablight:Activate", cab)
  end
end

local function setditchlights ()
  local horntime_s = 30
  local show = state.lasthorntime_s ~= nil
    and playersched:clock() <= state.lasthorntime_s + horntime_s
  ditchflasher:setflashstate(show)
  local flashleft = ditchflasher:ison()

  RailWorks.ActivateNode("left_ditch_light", show and flashleft)
  Call("Fwd_DitchLightLeft:Activate", RailWorks.frombool(show and flashleft))

  RailWorks.ActivateNode("right_ditch_light", show and not flashleft)
  Call("Fwd_DitchLightRight:Activate", RailWorks.frombool(show and not flashleft))
end

local function updateplayer ()
  readcontrols()
  readlocostate()

  playersched:update()
  anysched:update()

  writelocostate()
  setdrivescreen()
  setcutin()
  setadu()
  setpantospark()
  setinteriorlights()
  setditchlights()
end

local function updateai ()
  anysched:update()

  setpantospark()
  setinteriorlights()
  setditchlights()
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
  atc:receivemessage(message)
  acses:receivemessage(message)
end)

OnConsistMessage = RailWorks.SendConsistMessage