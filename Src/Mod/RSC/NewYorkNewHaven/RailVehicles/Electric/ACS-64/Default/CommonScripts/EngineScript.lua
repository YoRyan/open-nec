-- Engine script for the Siemens ACS-64 operated by Amtrak.

local playersched, anysched
local atc
local acses
local adu
local alerter
local power
local tracteffort
local acceleration
local alarmonoff
local suppressflasher
local ditchflasher
local spark
local state = {
  throttle = 0,
  train_brake = 0,
  acknowledge = false,
  headlights = 0,
  ditchlights = 0,

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
    getbrakesuppression = function () return state.train_brake >= 0.75 end
  }

  acses = Acses:new{
    scheduler = playersched,
    getspeed_mps = function () return state.speed_mps end,
    gettrackspeed_mps = function () return state.trackspeed_mps end,
    getconsistlength_m = function () return state.consistlength_m end,
    iterspeedlimits = function () return pairs(state.speedlimits) end,
    iterrestrictsignals = function () return pairs(state.restrictsignals) end,
    getacknowledge = function () return state.acknowledge end,
    doalert = function () adu:doacsesalert() end
  }

  local alert_s = 1
  adu = AmtrakCombinedAdu:new{
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

  power = Power:new{available={Power.types.overhead}}

  local avgsamples = 30
  tracteffort = Average:new{nsamples=avgsamples}
  acceleration = Average:new{nsamples=avgsamples}

  -- Modulate the speed reduction alert sound, which normally plays just once.
  alarmonoff = Flash:new{
    scheduler = playersched,
    off_s = 0.1,
    on_s = 0.5
  }

  local suppressflash_s = 0.5
  suppressflasher = Flash:new{
    scheduler = playersched,
    off_s = suppressflash_s,
    on_s = suppressflash_s
  }

  local groundflash_s = 1
  ditchflasher = Flash:new{
    scheduler = playersched,
    off_s = groundflash_s,
    on_s = groundflash_s
  }

  spark = PantoSpark:new{
    scheduler = anysched
  }

  RailWorks.BeginUpdate()
end)

local function readcontrols ()
  if RailWorks.GetControlValue("AutoSuppression", 0) == 1 then
    RailWorks.SetControlValue("AutoSuppression", 0, 0)
    RailWorks.SetControlValue("VirtualBrake", 0, 0.75)
  end

  local throttle = RailWorks.GetControlValue("ThrottleAndBrake", 0)
  local vbrake = RailWorks.GetControlValue("VirtualBrake", 0)
  local change = throttle ~= state.throttle or vbrake ~= state.train_brake
  state.throttle = throttle
  state.train_brake = vbrake
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) == 1
  if state.acknowledge or change then
    alerter:acknowledge()
  end

  if RailWorks.GetControlValue("Horn", 0) == 1 then
    state.lasthorntime_s = playersched:clock()
  end

  state.headlights = RailWorks.GetControlValue("Headlights", 0)
  state.ditchlights = RailWorks.GetControlValue("DitchLight", 0)
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

  if RailWorks.GetControlValue("PantographControl", 0) == 1 then
    power:setcollectors(Power.types.overhead)
  else
    power:setcollectors()
  end
end

local function writelocostate ()
  local penalty = alerter:ispenalty() or atc:ispenalty() or acses:ispenalty()
  local penaltybrake = 0.85
  -- There's no virtual throttle, so just move the throttle handle.
  if not power:haspower() or penalty then
    RailWorks.SetControlValue("ThrottleAndBrake", 0, 0.5) -- no power
  end
  do
    local v
    if penalty then v = penaltybrake
    else v = state.train_brake end
    RailWorks.SetControlValue("TrainBrakeControl", 0, v)
  end

  alarmonoff:setflashstate(atc:isalarm() or acses:isalarm())
  RailWorks.SetControlValue(
    "SpeedReductionAlert", 0,
    RailWorks.frombool(alarmonoff:ison()))
  RailWorks.SetControlValue(
    "SpeedIncreaseAlert", 0,
    RailWorks.frombool(adu:isatcalert() or adu:isacsesalert()))
end

local function setpantocontrol ()
  if RailWorks.GetControlValue("PantographDownButton", 0) == 1 then
    RailWorks.SetControlValue("PantographDownButton", 0, 0)
    RailWorks.SetControlValue("PantographControl", 0, 0)
  elseif RailWorks.GetControlValue("PantographUpButton", 0) == 1 then
    RailWorks.SetControlValue("PantographUpButton", 0, 0)
    RailWorks.SetControlValue("PantographControl", 0, 1)
  end
end

local function setpantosparks ()
  local frontcontact = false
  local rearcontact = RailWorks.GetControlValue("PantographControl", 0) == 1
  spark:setsparkstate(frontcontact or rearcontact)
  local isspark = spark:isspark()
  RailWorks.SetControlValue("Spark", 0, RailWorks.frombool(isspark))

  RailWorks.ActivateNode("PantoBsparkA", frontcontact and isspark)
  RailWorks.ActivateNode("PantoBsparkB", frontcontact and isspark)
  RailWorks.ActivateNode("PantoBsparkC", frontcontact and isspark)
  RailWorks.ActivateNode("PantoBsparkD", frontcontact and isspark)
  RailWorks.ActivateNode("PantoBsparkE", frontcontact and isspark)
  RailWorks.ActivateNode("PantoBsparkF", frontcontact and isspark)
  Call("Spark1:Activate", RailWorks.frombool(frontcontact and isspark))

  RailWorks.ActivateNode("PantoAsparkA", rearcontact and isspark)
  RailWorks.ActivateNode("PantoAsparkB", rearcontact and isspark)
  RailWorks.ActivateNode("PantoAsparkC", rearcontact and isspark)
  RailWorks.ActivateNode("PantoAsparkD", rearcontact and isspark)
  RailWorks.ActivateNode("PantoAsparkE", rearcontact and isspark)
  RailWorks.ActivateNode("PantoAsparkF", rearcontact and isspark)
  Call("Spark2:Activate", RailWorks.frombool(rearcontact and isspark))
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

local function setscreen ()
  do
    local maxeffort_klbs = 71*71/80.5
    tracteffort:sample(RailWorks.GetTractiveEffort()*maxeffort_klbs)

    local effort_klbs = math.abs(tracteffort:get())
    local reffort_klbs = math.floor(effort_klbs + 0.5)
    RailWorks.SetControlValue("effort_tens", 0, getdigit(reffort_klbs, 1))
    RailWorks.SetControlValue("effort_units", 0, getdigit(reffort_klbs, 0))
    RailWorks.SetControlValue("effort_guide", 0, getdigitguide(reffort_klbs))
    RailWorks.SetControlValue("AbsTractiveEffort", 0, effort_klbs*365/80)
  end
  do
    local speed_mph = toroundedmph(state.speed_mps)
    RailWorks.SetControlValue("SpeedDigit_hundreds", 0, getdigit(speed_mph, 2))
    RailWorks.SetControlValue("SpeedDigit_tens", 0, getdigit(speed_mph, 1))
    RailWorks.SetControlValue("SpeedDigit_units", 0, getdigit(speed_mph, 0))
    RailWorks.SetControlValue("SpeedDigit_guide", 0, getdigitguide(speed_mph))
  end
  do
    acceleration:sample(state.acceleration_mps2)
    local accel_mphmin = math.abs(acceleration:get()*134.2162)
    local raccel_mphmin = math.floor(accel_mphmin + 0.5)
    RailWorks.SetControlValue("accel_hundreds", 0, getdigit(raccel_mphmin, 2))
    RailWorks.SetControlValue("accel_tens", 0, getdigit(raccel_mphmin, 1))
    RailWorks.SetControlValue("accel_units", 0, getdigit(raccel_mphmin, 0))
    RailWorks.SetControlValue("accel_guide", 0, getdigitguide(raccel_mphmin))
    RailWorks.SetControlValue("AccelerationMPHPM", 0, accel_mphmin)
  end
  do
    local suppressing = atc:issuppressing()
    local suppression = atc:issuppression()
    suppressflasher:setflashstate(suppressing and not suppression)
    local light
    if suppression then
      light = true
    elseif suppressing and suppressflasher:ison() then
      light = true
    else
      light = false
    end
    RailWorks.SetControlValue("ScreenSuppression", 0, RailWorks.frombool(light))
  end
  RailWorks.SetControlValue(
    "ScreenAlerter", 0,
    RailWorks.frombool(alerter:isalarm()))
end

local function setcutin ()
  if not playersched:isstartup() then
    atc:setrunstate(RailWorks.GetControlValue("ATCCutIn", 0) == 1)
    acses:setrunstate(RailWorks.GetControlValue("ACSESCutIn", 0) == 1)
  end
end

local function setadu ()
  do
    local aspect = adu:getaspect()
    local signalspeed_mph = adu:getsignalspeed_mph()
    local tg, ty, tr, bg, bw
    local text
    local s, r, m, l, cs60, cs80, n
    if aspect == Adu.aspect.stop then
      tg, ty, tr, bg, bw = 0, 0, 1, 0, 0
      text = 12
      s, r, m, l, cs60, cs80, n = 1, 0, 0, 0, 0, 0, 0
    elseif aspect == Adu.aspect.restrict then
      tg, ty, tr, bg, bw = 0, 0, 1, 0, 1
      text = 11
      s, r, m, l, cs60, cs80, n = 0, 1, 0, 0, 0, 0, 0
    elseif aspect == Adu.aspect.approach then
      tg, ty, tr, bg, bw = 0, 1, 0, 0, 0
      text = 8
      s, r, m, l, cs60, cs80, n = 0, 0, 1, 0, 0, 0, 0
    elseif aspect == Adu.aspect.approachmed then
      tg, ty, tr, bg, bw = 0, 1, 0, 1, 0
      text = 13
      s, r, m, l, cs60, cs80, n = 0, 0, 0, 1, 0, 0, 0
    elseif aspect == Adu.aspect.cabspeed then
      tg, ty, tr, bg, bw = 1, 0, 0, 0, 0
      text = 2
      if signalspeed_mph == 60 then
        s, r, m, l, cs60, cs80, n = 0, 0, 0, 0, 1, 0, 0
      elseif signalspeed_mph == 80 then
        s, r, m, l, cs60, cs80, n = 0, 0, 0, 0, 0, 1, 0
      end
    elseif aspect == Adu.aspect.cabspeedoff then
      tg, ty, tr, bg, bw = 0, 0, 0, 0, 0
      text = 2
      if signalspeed_mph == 60 then
        s, r, m, l, cs60, cs80, n = 0, 0, 0, 0, 1, 0, 0
      elseif signalspeed_mph == 80 then
        s, r, m, l, cs60, cs80, n = 0, 0, 0, 0, 0, 1, 0
      end
    elseif aspect == Adu.aspect.clear then
      tg, ty, tr, bg, bw = 1, 0, 0, 0, 0
      text = 1
      s, r, m, l, cs60, cs80, n = 0, 0, 0, 0, 0, 0, 1
    end
    RailWorks.SetControlValue("SigAspectTopGreen", 0, tg)
    RailWorks.SetControlValue("SigAspectTopYellow", 0, ty)
    RailWorks.SetControlValue("SigAspectTopRed", 0, tr)
    RailWorks.SetControlValue("SigAspectBottomGreen", 0, bg)
    RailWorks.SetControlValue("SigAspectBottomWhite", 0, bw)
    RailWorks.SetControlValue("SigText", 0, text)
    RailWorks.SetControlValue("SigS", 0, s)
    RailWorks.SetControlValue("SigR", 0, r)
    RailWorks.SetControlValue("SigM", 0, m)
    RailWorks.SetControlValue("SigL", 0, l)
    RailWorks.SetControlValue("Sig60", 0, cs60)
    RailWorks.SetControlValue("Sig80", 0, cs80)
    RailWorks.SetControlValue("SigN", 0, n)
  end
  do
    local speed_mph = adu:getspeedlimit_mph()
    if speed_mph == nil then
      RailWorks.SetControlValue("SpeedLimit_hundreds", 0, 0)
      RailWorks.SetControlValue("SpeedLimit_tens", 0, -1)
      RailWorks.SetControlValue("SpeedLimit_units", 0, -1)
    else
      RailWorks.SetControlValue("SpeedLimit_hundreds", 0, getdigit(speed_mph, 2))
      RailWorks.SetControlValue("SpeedLimit_tens", 0, getdigit(speed_mph, 1))
      RailWorks.SetControlValue("SpeedLimit_units", 0, getdigit(speed_mph, 0))
    end
    RailWorks.SetControlValue(
      "SigModeATC", 0, RailWorks.frombool(adu:getatcindicator()))
    RailWorks.SetControlValue(
      "SigModeACSES", 0, RailWorks.frombool(adu:getacsesindicator()))
  end
  do
    local ttp_s = adu:gettimetopenalty_s()
    if ttp_s == nil then
      RailWorks.SetControlValue("Penalty_hundreds", 0, 0)
      RailWorks.SetControlValue("Penalty_tens", 0, -1)
      RailWorks.SetControlValue("Penalty_units", 0, -1)
    else
      RailWorks.SetControlValue("Penalty_hundreds", 0, getdigit(ttp_s, 2))
      RailWorks.SetControlValue("Penalty_tens", 0, getdigit(ttp_s, 1))
      RailWorks.SetControlValue("Penalty_units", 0, getdigit(ttp_s, 0))
    end
  end
  do
    local cutin = adu:atccutin()
    RailWorks.SetControlValue("SigATCCutIn", 0, RailWorks.frombool(cutin))
    RailWorks.SetControlValue("SigATCCutOut", 0, RailWorks.frombool(not cutin))
  end
  do
    local cutin = adu:acsescutin()
    RailWorks.SetControlValue("SigACSESCutIn", 0, RailWorks.frombool(cutin))
    RailWorks.SetControlValue("SigACSESCutOut", 0, RailWorks.frombool(not cutin))
  end
end

local function setcablights ()
  do
    local dome = RailWorks.GetControlValue("CabLight", 0)
    Call("FrontLight:Activate", dome)
    Call("RearCabLight:Activate", dome)
  end
  do
    local control = RailWorks.GetControlValue("DeskConsoleLight", 0)

    local desk = RailWorks.frombool(control >= 1 and control < 3)
    Call("Front_DeskLight_01:Activate", desk)
    Call("Rear_DeskLight_01:Activate", desk)

    local console = RailWorks.frombool(control >= 2)
    Call("Front_ConsoleLight_01:Activate", console)
    Call("Front_ConsoleLight_02:Activate", console)
    Call("Front_ConsoleLight_03:Activate", console)
    Call("Rear_ConsoleLight_01:Activate", console)
    Call("Rear_ConsoleLight_02:Activate", console)
    Call("Rear_ConsoleLight_03:Activate", console)
  end
end

local function setditchlights ()
  local horntime_s = 30
  local horn = state.lasthorntime_s ~= nil
    and playersched:clock() <= state.lasthorntime_s + horntime_s
  local fixed = state.headlights == 1 and state.ditchlights == 1
  local flash = (state.headlights == 1 and state.ditchlights == 2) or horn
  ditchflasher:setflashstate(flash)
  local flashleft = ditchflasher:ison()
  do
    local showleft = fixed or (flash and flashleft)
    RailWorks.ActivateNode("ditch_fwd_l", showleft)
    Call("FrontDitchLightL:Activate", RailWorks.frombool(showleft))
  end
  do
    local showright = fixed or (flash and not flashleft)
    RailWorks.ActivateNode("ditch_fwd_r", showright)
    Call("FrontDitchLightR:Activate", RailWorks.frombool(showright))
  end
  RailWorks.ActivateNode("ditch_rev_l", false)
  Call("RearDitchLightL:Activate", RailWorks.frombool(false))
  RailWorks.ActivateNode("ditch_rev_r", false)
  Call("RearDitchLightR:Activate", RailWorks.frombool(false))
end

local function updateplayer ()
  readcontrols()
  readlocostate()

  playersched:update()
  anysched:update()

  writelocostate()
  setpantocontrol()
  setpantosparks()
  setscreen()
  setcutin()
  setadu()
  setcablights()
  setditchlights()

  -- Prevent the acknowledge button from sticking if the button on the HUD is
  -- clicked.
  if state.acknowledge then
    RailWorks.SetControlValue("AWSReset", 0, 0)
  end
end

local function updateai ()
  anysched:update()

  setpantosparks()
  setcablights()
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
  power:receivemessage(message)
  atc:receivemessage(message)
  acses:receivemessage(message)
end)

OnConsistMessage = RailWorks.SendConsistMessage