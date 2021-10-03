-- Engine script for the Siemens ACS-64 operated by Amtrak.
--
-- @include RollingStock/PowerSupply/Electrification.lua
-- @include RollingStock/PowerSupply/PowerSupply.lua
-- @include RollingStock/BrakeLight.lua
-- @include RollingStock/Spark.lua
-- @include SafetySystems/Acses/Acses.lua
-- @include SafetySystems/AspectDisplay/AmtrakCombined.lua
-- @include SafetySystems/Alerter.lua
-- @include SafetySystems/Atc.lua
-- @include Signals/CabSignal.lua
-- @include Flash.lua
-- @include Iterator.lua
-- @include Misc.lua
-- @include MovingAverage.lua
-- @include RailWorks.lua
-- @include Scheduler.lua
-- @include Units.lua
local playersched, anysched
local cabsig
local atc
local acses
local adu
local alerter
local power
local blight
local tracteffort
local acceleration
local alarmonoff
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

Initialise = Misc.wraperrors(function()
  playersched = Scheduler:new{}
  anysched = Scheduler:new{}

  cabsig = CabSignal:new{scheduler = playersched}

  atc = Atc:new{
    scheduler = playersched,
    cabsignal = cabsig,
    getspeed_mps = function() return state.speed_mps end,
    getacceleration_mps2 = function() return state.acceleration_mps2 end,
    getacknowledge = function() return state.acknowledge end,
    doalert = function() adu:doatcalert() end,
    getbrakesuppression = function() return state.train_brake > 0.6 end
  }

  acses = Acses:new{
    scheduler = playersched,
    cabsignal = cabsig,
    getspeed_mps = function() return state.speed_mps end,
    gettrackspeed_mps = function() return state.trackspeed_mps end,
    getconsistlength_m = function() return state.consistlength_m end,
    iterspeedlimits = function() return pairs(state.speedlimits) end,
    iterrestrictsignals = function() return pairs(state.restrictsignals) end,
    getacknowledge = function() return state.acknowledge end,
    doalert = function() adu:doacsesalert() end,
    consistspeed_mps = 125 * Units.mph.tomps
  }

  local alert_s = 1
  adu = AmtrakCombinedAdu:new{
    scheduler = playersched,
    cabsignal = cabsig,
    atc = atc,
    atcalert_s = alert_s,
    acses = acses,
    acsesalert_s = alert_s
  }

  atc:start()
  acses:start()

  alerter = Alerter:new{
    scheduler = playersched,
    getspeed_mps = function() return state.speed_mps end
  }
  alerter:start()

  power = PowerSupply:new{
    scheduler = anysched,
    modes = {
      [0] = function(elec)
        local frontcontact = RailWorks.GetControlValue("FrontPantographControl",
                                                       0) == 1
        local rearcontact =
          RailWorks.GetControlValue("RearPantographControl", 0) == 1
        return (frontcontact or rearcontact) and
                 elec:isavailable(Electrification.type.overhead)
      end
    }
  }
  power:setavailable(Electrification.type.overhead, true)

  blight = BrakeLight:new{}

  local avgsamples = 30
  tracteffort = Average:new{nsamples = avgsamples}
  acceleration = Average:new{nsamples = avgsamples}

  -- Modulate the speed reduction alert sound, which normally plays just once.
  alarmonoff = Flash:new{scheduler = playersched, off_s = 0.1, on_s = 0.5}

  local ditchflash_s = 0.65
  ditchflasher = Flash:new{
    scheduler = playersched,
    off_s = ditchflash_s,
    on_s = ditchflash_s
  }

  spark = PantoSpark:new{scheduler = anysched}

  RailWorks.BeginUpdate()
end)

local function readcontrols()
  local throttle = RailWorks.GetControlValue("ThrottleAndBrake", 0)
  local vbrake = RailWorks.GetControlValue("VirtualBrake", 0)
  local change = throttle ~= state.throttle or vbrake ~= state.train_brake
  state.throttle = throttle
  state.train_brake = vbrake
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) > 0
  if state.acknowledge or change then alerter:acknowledge() end

  if RailWorks.GetControlValue("Horn", 0) > 0 then
    state.lasthorntime_s = playersched:clock()
  end

  state.headlights = RailWorks.GetControlValue("Headlights", 0)
  state.ditchlights = RailWorks.GetControlValue("DitchLight", 0)
end

local function readlocostate()
  state.speed_mps = RailWorks.GetControlValue("SpeedometerMPH", 0) *
                      Units.mph.tomps
  state.acceleration_mps2 = RailWorks.GetAcceleration()
  state.trackspeed_mps = RailWorks.GetCurrentSpeedLimit(1)
  state.consistlength_m = RailWorks.GetConsistLength()
  state.speedlimits = Iterator.totable(Misc.iterspeedlimits(
                                         Acses.nlimitlookahead))
  state.restrictsignals = Iterator.totable(
                            Misc.iterrestrictsignals(Acses.nsignallookahead))
end

local function writelocostate()
  local penalty = alerter:ispenalty() or atc:ispenalty() or acses:ispenalty()

  local throttle, dynbrake
  if not power:haspower() then
    throttle, dynbrake = 0, 0
  elseif penalty then
    throttle, dynbrake = 0, 0
  else
    local min = RailWorks.GetControlMinimum("ThrottleAndBrake", 0)
    local max = RailWorks.GetControlMaximum("ThrottleAndBrake", 0)
    local mid = (max + min) / 2
    throttle = math.max(state.throttle - mid, 0) / (max - mid)
    dynbrake = math.max(mid - state.throttle, 0) / (mid - min)
  end
  RailWorks.SetControlValue("Regulator", 0, throttle)
  RailWorks.SetControlValue("DynamicBrake", 0, dynbrake)

  local cmdbrake = penalty and 0.85 or state.train_brake
  -- DTG's nonlinear braking algorithm
  local brake
  if cmdbrake < 0.1 then
    brake = 0
  elseif cmdbrake < 0.35 then
    brake = 0.07
  elseif cmdbrake < 0.75 then
    brake = 0.07 + (cmdbrake - 0.35) / (0.6 - 0.35) * 0.1
  elseif cmdbrake < 0.85 then
    brake = 0.17
  elseif cmdbrake < 1 then
    brake = 0.24
  else
    brake = 1
  end
  RailWorks.SetControlValue("TrainBrakeControl", 0, brake)

  local alarm = atc:isalarm() or acses:isalarm()
  alarmonoff:setflashstate(alarm)
  RailWorks.SetControlValue("AWSWarnCount", 0, Misc.intbool(alarm))
  RailWorks.SetControlValue("SpeedReductionAlert", 0,
                            Misc.intbool(alarmonoff:ison()))
  RailWorks.SetControlValue("SpeedIncreaseAlert", 0, Misc.intbool(
                              adu:isatcalert() or adu:isacsesalert()))
end

local function setpantosparks()
  local frontcontact = RailWorks.GetControlValue("FrontPantographControl", 0) ==
                         1
  local rearcontact = RailWorks.GetControlValue("RearPantographControl", 0) == 1
  local isspark = power:haspower() and (frontcontact or rearcontact) and
                    spark:isspark()
  RailWorks.SetControlValue("Spark", 0, Misc.intbool(isspark))

  RailWorks.ActivateNode("PantoBsparkA", frontcontact and isspark)
  RailWorks.ActivateNode("PantoBsparkB", frontcontact and isspark)
  RailWorks.ActivateNode("PantoBsparkC", frontcontact and isspark)
  RailWorks.ActivateNode("PantoBsparkD", frontcontact and isspark)
  RailWorks.ActivateNode("PantoBsparkE", frontcontact and isspark)
  RailWorks.ActivateNode("PantoBsparkF", frontcontact and isspark)
  Call("Spark1:Activate", Misc.intbool(frontcontact and isspark))

  RailWorks.ActivateNode("PantoAsparkA", rearcontact and isspark)
  RailWorks.ActivateNode("PantoAsparkB", rearcontact and isspark)
  RailWorks.ActivateNode("PantoAsparkC", rearcontact and isspark)
  RailWorks.ActivateNode("PantoAsparkD", rearcontact and isspark)
  RailWorks.ActivateNode("PantoAsparkE", rearcontact and isspark)
  RailWorks.ActivateNode("PantoAsparkF", rearcontact and isspark)
  Call("Spark2:Activate", Misc.intbool(rearcontact and isspark))
end

local function setscreen()
  tracteffort:sample(RailWorks.GetTractiveEffort() * 71 * 71 / 80.5)
  local effort_klbs = math.abs(tracteffort:get())
  local reffort_klbs = math.floor(effort_klbs + 0.5)
  RailWorks.SetControlValue("effort_tens", 0, Misc.getdigit(reffort_klbs, 1))
  RailWorks.SetControlValue("effort_units", 0, Misc.getdigit(reffort_klbs, 0))
  RailWorks.SetControlValue("effort_guide", 0, Misc.getdigitguide(reffort_klbs))
  RailWorks.SetControlValue("AbsTractiveEffort", 0, effort_klbs * 365 / 80)

  local speed_mph = Misc.round(state.speed_mps * Units.mps.tomph)
  RailWorks.SetControlValue("SpeedDigit_hundreds", 0,
                            Misc.getdigit(speed_mph, 2))
  RailWorks.SetControlValue("SpeedDigit_tens", 0, Misc.getdigit(speed_mph, 1))
  RailWorks.SetControlValue("SpeedDigit_units", 0, Misc.getdigit(speed_mph, 0))
  RailWorks.SetControlValue("SpeedDigit_guide", 0, Misc.getdigitguide(speed_mph))

  acceleration:sample(state.acceleration_mps2)
  local accel_mphmin = math.abs(acceleration:get() * 134.2162)
  local raccel_mphmin = math.floor(accel_mphmin + 0.5)
  RailWorks.SetControlValue("accel_hundreds", 0, Misc.getdigit(raccel_mphmin, 2))
  RailWorks.SetControlValue("accel_tens", 0, Misc.getdigit(raccel_mphmin, 1))
  RailWorks.SetControlValue("accel_units", 0, Misc.getdigit(raccel_mphmin, 0))
  RailWorks.SetControlValue("accel_guide", 0, Misc.getdigitguide(raccel_mphmin))
  RailWorks.SetControlValue("AccelerationMPHPM", 0, accel_mphmin)

  RailWorks.SetControlValue("ScreenSuppression", 0,
                            Misc.intbool(atc:issuppression()))
  RailWorks.SetControlValue("ScreenAlerter", 0, Misc.intbool(alerter:isalarm()))
  RailWorks.SetControlValue("ScreenWheelslip", 0, Misc.intbool(
                              RailWorks.GetControlValue("Wheelslip", 0) > 1))
  RailWorks.SetControlValue("ScreenParkingBrake", 0,
                            RailWorks.GetControlValue("HandBrake", 0))
end

local function setcutin()
  if not playersched:isstartup() then
    atc:setrunstate(RailWorks.GetControlValue("ATCCutIn", 0) == 1)
    acses:setrunstate(RailWorks.GetControlValue("ACSESCutIn", 0) == 1)
  end
end

local function setadu()
  local aspect = adu:getaspect()
  local mnrr = Misc.intbool(adu:getmnrrilluminated())
  local tg, ty, tr, bg, bw
  local text
  local s, r, m, l, cs60, cs80, n
  if aspect == AmtrakCombinedAdu.aspect.stop then
    tg, ty, tr, bg, bw = 0, 0, 1, 0, 0
    text = 12
    s, r, m, l, cs60, cs80, n = mnrr, 0, 0, 0, 0, 0, 0
  elseif aspect == AmtrakCombinedAdu.aspect.restrict then
    tg, ty, tr, bg, bw = 0, 0, 1, 0, 1
    text = 11
    s, r, m, l, cs60, cs80, n = 0, mnrr, 0, 0, 0, 0, 0
  elseif aspect == AmtrakCombinedAdu.aspect.approach then
    tg, ty, tr, bg, bw = 0, 1, 0, 0, 0
    text = 8
    s, r, m, l, cs60, cs80, n = 0, 0, mnrr, 0, 0, 0, 0
  elseif aspect == AmtrakCombinedAdu.aspect.approachmed30 or aspect ==
    AmtrakCombinedAdu.aspect.approachmed45 then
    tg, ty, tr, bg, bw = 0, 1, 0, 1, 0
    text = 13
    s, r, m, l, cs60, cs80, n = 0, 0, 0, mnrr, 0, 0, 0
  elseif aspect == AmtrakCombinedAdu.aspect.cabspeed60 then
    tg, ty, tr, bg, bw = 1, 0, 0, 0, 0
    text = 2
    s, r, m, l, cs60, cs80, n = 0, 0, 0, 0, mnrr, 0, 0
  elseif aspect == AmtrakCombinedAdu.aspect.cabspeed60off then
    tg, ty, tr, bg, bw = 0, 0, 0, 0, 0
    text = 2
    s, r, m, l, cs60, cs80, n = 0, 0, 0, 0, mnrr, 0, 0
  elseif aspect == AmtrakCombinedAdu.aspect.cabspeed80 then
    tg, ty, tr, bg, bw = 1, 0, 0, 0, 0
    text = 2
    s, r, m, l, cs60, cs80, n = 0, 0, 0, 0, 0, mnrr, 0
  elseif aspect == AmtrakCombinedAdu.aspect.cabspeed80off then
    tg, ty, tr, bg, bw = 0, 0, 0, 0, 0
    text = 2
    s, r, m, l, cs60, cs80, n = 0, 0, 0, 0, 0, mnrr, 0
  elseif aspect == AmtrakCombinedAdu.aspect.clear100 or aspect ==
    AmtrakCombinedAdu.aspect.clear125 or aspect ==
    AmtrakCombinedAdu.aspect.clear150 then
    tg, ty, tr, bg, bw = 1, 0, 0, 0, 0
    text = 1
    s, r, m, l, cs60, cs80, n = 0, 0, 0, 0, 0, 0, mnrr
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

  local speed_mph = adu:getspeedlimit_mph()
  if speed_mph == nil then
    RailWorks.SetControlValue("SpeedLimit_hundreds", 0, 0)
    RailWorks.SetControlValue("SpeedLimit_tens", 0, -1)
    RailWorks.SetControlValue("SpeedLimit_units", 0, -1)
  else
    RailWorks.SetControlValue("SpeedLimit_hundreds", 0,
                              Misc.getdigit(speed_mph, 2))
    RailWorks.SetControlValue("SpeedLimit_tens", 0, Misc.getdigit(speed_mph, 1))
    RailWorks.SetControlValue("SpeedLimit_units", 0, Misc.getdigit(speed_mph, 0))
  end
  RailWorks.SetControlValue("SigModeATC", 0, Misc.intbool(adu:getatcindicator()))
  RailWorks.SetControlValue("SigModeACSES", 0,
                            Misc.intbool(adu:getacsesindicator()))

  local ttp_s = adu:gettimetopenalty_s()
  if ttp_s == nil then
    RailWorks.SetControlValue("Penalty_hundreds", 0, 0)
    RailWorks.SetControlValue("Penalty_tens", 0, -1)
    RailWorks.SetControlValue("Penalty_units", 0, -1)
  else
    RailWorks.SetControlValue("Penalty_hundreds", 0, Misc.getdigit(ttp_s, 2))
    RailWorks.SetControlValue("Penalty_tens", 0, Misc.getdigit(ttp_s, 1))
    RailWorks.SetControlValue("Penalty_units", 0, Misc.getdigit(ttp_s, 0))
  end

  local atccutin = adu:atccutin()
  RailWorks.SetControlValue("SigATCCutIn", 0, Misc.intbool(atccutin))
  RailWorks.SetControlValue("SigATCCutOut", 0, Misc.intbool(not atccutin))

  local acsescutin = adu:acsescutin()
  RailWorks.SetControlValue("SigACSESCutIn", 0, Misc.intbool(acsescutin))
  RailWorks.SetControlValue("SigACSESCutOut", 0, Misc.intbool(not acsescutin))
end

local function setcablights()
  local dome = RailWorks.GetControlValue("CabLight", 0)
  Call("FrontCabLight:Activate", dome)
  Call("RearCabLight:Activate", dome)

  local control = RailWorks.GetControlValue("DeskConsoleLight", 0)
  local desk = Misc.intbool(control >= 1 and control < 3)
  Call("Front_DeskLight_01:Activate", desk)
  Call("Rear_DeskLight_01:Activate", desk)
  local console = Misc.intbool(control >= 2)
  Call("Front_ConsoleLight_01:Activate", console)
  Call("Front_ConsoleLight_02:Activate", console)
  Call("Front_ConsoleLight_03:Activate", console)
  Call("Rear_ConsoleLight_01:Activate", console)
  Call("Rear_ConsoleLight_02:Activate", console)
  Call("Rear_ConsoleLight_03:Activate", console)
end

local function setditchlights()
  local horntime_s = 30
  local horn = state.lasthorntime_s ~= nil and playersched:clock() <=
                 state.lasthorntime_s + horntime_s
  local fixed = state.headlights == 1 and state.ditchlights == 1
  local flash = (state.headlights == 1 and state.ditchlights == 2) or horn
  ditchflasher:setflashstate(flash)
  local flashleft = ditchflasher:ison()

  local showleft = fixed or (flash and flashleft)
  RailWorks.ActivateNode("ditch_fwd_l", showleft)
  Call("FrontDitchLightL:Activate", Misc.intbool(showleft))

  local showright = fixed or (flash and not flashleft)
  RailWorks.ActivateNode("ditch_fwd_r", showright)
  Call("FrontDitchLightR:Activate", Misc.intbool(showright))

  RailWorks.ActivateNode("ditch_rev_l", false)
  Call("RearDitchLightL:Activate", Misc.intbool(false))
  RailWorks.ActivateNode("ditch_rev_r", false)
  Call("RearDitchLightR:Activate", Misc.intbool(false))
end

local function updateplayer()
  readcontrols()
  readlocostate()

  playersched:update()
  anysched:update()
  power:update()
  blight:playerupdate()

  writelocostate()
  setpantosparks()
  setscreen()
  setcutin()
  setadu()
  setcablights()
  setditchlights()
end

local function updateai()
  anysched:update()

  setpantosparks()
  setcablights()
  setditchlights()
end

Update = Misc.wraperrors(function(_)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer()
  else
    updateai()
  end
end)

OnControlValueChange = Misc.wraperrors(function(name, index, value)
  -- pantograph up/down control
  if name == "PantographDownButton" and value == 1 then
    RailWorks.SetControlValue("PantographDownButton", 0, 0)
    RailWorks.SetControlValue("PantographControl", 0, 0)
  elseif name == "PantographUpButton" and value == 1 then
    RailWorks.SetControlValue("PantographUpButton", 0, 0)
    RailWorks.SetControlValue("PantographControl", 0, 1)
  end

  -- Shift+' suppression hotkey
  if name == "AutoSuppression" and value > 0 then
    RailWorks.SetControlValue("AutoSuppression", 0, 0)
    RailWorks.SetControlValue("VirtualBrake", 0, 0.75)
  end

  RailWorks.SetControlValue(name, index, value)
end)

OnCustomSignalMessage = Misc.wraperrors(function(message)
  power:receivemessage(message)
  cabsig:receivemessage(message)
end)

OnConsistMessage = Misc.wraperrors(function(message, argument, direction)
  blight:receivemessage(message, argument, direction)

  RailWorks.Engine_SendConsistMessage(message, argument, direction)
end)
