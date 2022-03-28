-- Engine script for the Siemens ACS-64 operated by Amtrak.
--
-- @include SafetySystems/Alerter.lua
-- @include SafetySystems/AspectDisplay/AmtrakCombined.lua
-- @include YoRyan/LibRailWorks/Flash.lua
-- @include YoRyan/LibRailWorks/Iterator.lua
-- @include YoRyan/LibRailWorks/Misc.lua
-- @include YoRyan/LibRailWorks/MovingAverage.lua
-- @include YoRyan/LibRailWorks/RailWorks.lua
-- @include YoRyan/LibRailWorks/RollingStock/BrakeLight.lua
-- @include YoRyan/LibRailWorks/RollingStock/PowerSupply/Electrification.lua
-- @include YoRyan/LibRailWorks/RollingStock/PowerSupply/PowerSupply.lua
-- @include YoRyan/LibRailWorks/RollingStock/Spark.lua
-- @include YoRyan/LibRailWorks/Units.lua
local adu
local alerter
local power
local blight
local tracteffort, acceleration
local alarmonoff
local ditchflasher
local spark

local lasthorntime_s = nil

local function isenhancedpack() return RailWorks.ControlExists("TAPRBYL", 0) end

local function issuppression()
  return RailWorks.GetControlValue("VirtualBrake", 0) >=
           (isenhancedpack() and 0.4 or 0.6)
end

Initialise = Misc.wraperrors(function()
  adu = AmtrakCombinedAdu:new{
    getbrakesuppression = issuppression,
    getacknowledge = function()
      return RailWorks.GetControlValue("AWSReset", 0) > 0
    end,
    consistspeed_mps = 125 * Units.mph.tomps
  }

  alerter = Alerter:new{
    getacknowledge = function()
      return RailWorks.GetControlValue("AWSReset", 0) > 0
    end
  }
  alerter:start()

  power = PowerSupply:new{
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
  alarmonoff = Flash:new{off_s = 0.1, on_s = 0.5}

  local ditchflash_s = 0.65
  ditchflasher = Flash:new{off_s = ditchflash_s, on_s = ditchflash_s}

  spark = PantoSpark:new{}

  RailWorks.BeginUpdate()
end)

local function readcontrols()
  -- For Fan Railer and CTSL Railfan's mods, the quill should also turn on the
  -- ditch lights.
  local quill = RailWorks.GetControlValue("HornSequencer", 0)
  if RailWorks.GetControlValue("Horn", 0) > 0 or (quill ~= nil and quill > 0) then
    lasthorntime_s = RailWorks.GetSimulationTime()
  end
end

local function setplayercontrols()
  local penalty = alerter:ispenalty() or adu:ispenalty()

  local throttle, dynbrake
  if not power:haspower() then
    throttle, dynbrake = 0, 0
  elseif penalty then
    throttle, dynbrake = 0, 0
  else
    local value = RailWorks.GetControlValue("ThrottleAndBrake", 0)
    local min = RailWorks.GetControlMinimum("ThrottleAndBrake", 0)
    local max = RailWorks.GetControlMaximum("ThrottleAndBrake", 0)
    local mid = (max + min) / 2
    throttle = math.max(value - mid, 0) / (max - mid)
    dynbrake = math.max(mid - value, 0) / (mid - min)
  end
  RailWorks.SetControlValue("Regulator", 0, throttle)
  RailWorks.SetControlValue("DynamicBrake", 0, dynbrake)

  local cmdbrake = penalty and 0.85 or
                     RailWorks.GetControlValue("VirtualBrake", 0)
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

  local alarm = adu:isalarm()
  RailWorks.SetControlValue("AWSWarnCount", 0, Misc.intbool(alarm))
  local sralert
  if isenhancedpack() then
    -- There's no need to modulate CTSL's improved sound.
    sralert = alarm
  else
    alarmonoff:setflashstate(alarm)
    sralert = alarmonoff:ison()
  end
  RailWorks.SetControlValue("SpeedReductionAlert", 0, Misc.intbool(sralert))
  RailWorks.SetControlValue("SpeedIncreaseAlert", 0,
                            Misc.intbool(adu:isalertplaying()))
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

  local speed_mph = Misc.round(RailWorks.GetControlValue("SpeedometerMPH", 0))
  RailWorks.SetControlValue("SpeedDigit_hundreds", 0,
                            Misc.getdigit(speed_mph, 2))
  RailWorks.SetControlValue("SpeedDigit_tens", 0, Misc.getdigit(speed_mph, 1))
  RailWorks.SetControlValue("SpeedDigit_units", 0, Misc.getdigit(speed_mph, 0))
  RailWorks.SetControlValue("SpeedDigit_guide", 0, Misc.getdigitguide(speed_mph))

  acceleration:sample(RailWorks.GetAcceleration())
  local accel_mphmin = math.abs(acceleration:get() * 134.2162)
  local raccel_mphmin = math.floor(accel_mphmin + 0.5)
  RailWorks.SetControlValue("accel_hundreds", 0, Misc.getdigit(raccel_mphmin, 2))
  RailWorks.SetControlValue("accel_tens", 0, Misc.getdigit(raccel_mphmin, 1))
  RailWorks.SetControlValue("accel_units", 0, Misc.getdigit(raccel_mphmin, 0))
  RailWorks.SetControlValue("accel_guide", 0, Misc.getdigitguide(raccel_mphmin))
  RailWorks.SetControlValue("AccelerationMPHPM", 0, accel_mphmin)

  RailWorks.SetControlValue("ScreenSuppression", 0,
                            Misc.intbool(issuppression()))
  RailWorks.SetControlValue("ScreenAlerter", 0, Misc.intbool(alerter:isalarm()))
  RailWorks.SetControlValue("ScreenWheelslip", 0, Misc.intbool(
                              RailWorks.GetControlValue("Wheelslip", 0) > 1))
  RailWorks.SetControlValue("ScreenParkingBrake", 0,
                            RailWorks.GetControlValue("HandBrake", 0))
end

local function setcutin()
  adu:setatcstate(RailWorks.GetControlValue("ATCCutIn", 0) == 1)
  adu:setacsesstate(RailWorks.GetControlValue("ACSESCutIn", 0) == 1)
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
  local horn = lasthorntime_s ~= nil and RailWorks.GetSimulationTime() <=
                 lasthorntime_s + horntime_s
  local headlights = RailWorks.GetControlValue("Headlights", 0)
  local ditchlights = RailWorks.GetControlValue("DitchLight", 0)
  local fixed = headlights == 1 and ditchlights == 1
  local flash = (headlights == 1 and ditchlights == 2) or horn
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

local function updateplayer(dt)
  readcontrols()

  adu:update(dt)
  alerter:update(dt)
  power:update(dt)
  blight:playerupdate(dt)

  setplayercontrols()
  setpantosparks()
  setscreen()
  setcutin()
  setadu()
  setcablights()
  setditchlights()
end

local function updatenonplayer()
  setpantosparks()
  setcablights()
  setditchlights()
end

Update = Misc.wraperrors(function(dt)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer(dt)
  else
    updatenonplayer()
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
    RailWorks.SetControlValue("VirtualBrake", 0,
                              isenhancedpack() and 0.5 or 0.75)
  end

  if name == "ThrottleAndBrake" or name == "VirtualBrake" then
    alerter:acknowledge()
  end

  RailWorks.SetControlValue(name, index, value)
end)

OnCustomSignalMessage = Misc.wraperrors(function(message)
  power:receivemessage(message)
  adu:receivemessage(message)
end)

OnConsistMessage = Misc.wraperrors(function(message, argument, direction)
  blight:receivemessage(message, argument, direction)

  RailWorks.Engine_SendConsistMessage(message, argument, direction)
end)
