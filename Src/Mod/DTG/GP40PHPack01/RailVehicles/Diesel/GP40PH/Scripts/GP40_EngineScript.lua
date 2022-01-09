-- Engine script for the GP40PH operated by New Jersey Transit.
--
-- @include RollingStock/BrakeLight.lua
-- @include RollingStock/Doors.lua
-- @include RollingStock/Hep.lua
-- @include SafetySystems/AspectDisplay/NjTransit.lua
-- @include SafetySystems/Alerter.lua
-- @include Flash.lua
-- @include Misc.lua
-- @include RailWorks.lua
-- @include Units.lua
local messageid = {destination = 10100}

local adu
local alerter
local hep
local blight
local doors
local ditchflasher
local decreaseonoff

local initdestination = nil
local strobetime_s = nil

local function readrvnumber()
  local _, _, deststr = string.find(RailWorks.GetRVNumber(), "(%a)")
  local dest
  if deststr ~= nil then
    dest = string.byte(string.upper(deststr)) - string.byte("A") + 1
  else
    dest = nil
  end
  initdestination = dest
end

local function isstarted()
  return RailWorks.GetControlValue("VirtualStartup", 0) >= 0
end

Initialise = Misc.wraperrors(function()
  adu = NjTransitAdu:new{
    getbrakesuppression = function()
      return RailWorks.GetControlValue("VirtualBrake", 0) >= 0.5
    end,
    getacknowledge = function()
      return RailWorks.GetControlValue("AWSReset", 0) > 0
    end,
    consistspeed_mps = 100 * Units.mph.tomps
  }

  alerter = Alerter:new{}
  alerter:start()

  hep = Hep:new{getrun = isstarted}

  blight = BrakeLight:new{
    getbrakeson = function()
      -- Match the brake indicator light logic in the carriage script.
      return RailWorks.GetControlValue("TrainBrakeControl", 0) > 0
    end
  }

  doors = Doors:new{}

  local ditchflash_s = 1
  ditchflasher = Flash:new{off_s = ditchflash_s, on_s = ditchflash_s}

  -- Modulate the speed reduction alert sound, which normally plays just once.
  decreaseonoff = Flash:new{off_s = 0.1, on_s = 0.5}

  readrvnumber()
  RailWorks.BeginUpdate()
end)

local function readcontrols()
  if RailWorks.GetControlValue("VirtualBell", 0) > 0 then
    if strobetime_s == nil then
      -- Randomize the starting point of the flash sequence.
      strobetime_s = RailWorks.GetSimulationTime() - math.random() * 60
    end
  else
    strobetime_s = nil
  end
end

local function writelocostate()
  local penalty = adu:ispenalty() or alerter:ispenalty()
  RailWorks.SetControlValue("Regulator", 0,
                            RailWorks.GetControlValue("VirtualThrottle", 0))
  RailWorks.SetControlValue("TrainBrakeControl", 0, penalty and 0.5 or
                              RailWorks.GetControlValue("VirtualBrake", 0))

  local psi = RailWorks.GetControlValue("AirBrakePipePressurePSI", 0)
  RailWorks.SetControlValue("DynamicBrake", 0, math.min((89 - psi) / 16, 1))

  local vigilalarm = alerter:isalarm()
  local safetyalarm = adu:isalarm()
  local safetyalert = adu:isalertplaying()
  RailWorks.SetControlValue("AWSWarnCount", 0,
                            Misc.intbool(vigilalarm or safetyalarm))
  RailWorks.SetControlValue("ACSES_Alert", 0, Misc.intbool(vigilalarm))
  decreaseonoff:setflashstate(safetyalarm)
  RailWorks.SetControlValue("ACSES_AlertDecrease", 0,
                            Misc.intbool(decreaseonoff:ison()))
  RailWorks.SetControlValue("ACSES_AlertIncrease", 0, Misc.intbool(safetyalert))

  RailWorks.SetControlValue("Reverser", 0,
                            RailWorks.GetControlValue("UserVirtualReverser", 0))
  RailWorks.SetControlValue("EngineBrakeControl", 0, RailWorks.GetControlValue(
                              "VirtualEngineBrakeControl", 0))
  RailWorks.SetControlValue("Startup", 0, isstarted() and 1 or -1)
  RailWorks.SetControlValue("Sander", 0,
                            RailWorks.GetControlValue("VirtualSander", 0))
  RailWorks.SetControlValue("Bell", 0,
                            RailWorks.GetControlValue("VirtualBell", 0))
  RailWorks.SetControlValue("Horn", 0,
                            RailWorks.GetControlValue("VirtualHorn", 0))
  RailWorks.SetControlValue("Wipers", 0,
                            RailWorks.GetControlValue("VirtualWipers", 0))
  RailWorks.SetControlValue("ApplicationPipe", 0, RailWorks.GetControlValue(
                              "AirBrakePipePressurePSI", 0))
  RailWorks.SetControlValue("SuppressionPipe", 0, RailWorks.GetControlValue(
                              "MainReservoirPressurePSI", 0))
  RailWorks.SetControlValue("HEP_State", 0, Misc.intbool(hep:haspower()))
end

local function setadu()
  local isclear = adu:isclearsignal()
  local rspeed_mph = Misc.round(math.abs(
                                  RailWorks.GetControlValue("SpeedometerMPH", 0)))
  local h = Misc.getdigit(rspeed_mph, 2)
  local t = Misc.getdigit(rspeed_mph, 1)
  local u = Misc.getdigit(rspeed_mph, 0)
  RailWorks.SetControlValue("SpeedH", 0, isclear and h or -1)
  RailWorks.SetControlValue("SpeedT", 0, isclear and t or -1)
  RailWorks.SetControlValue("SpeedU", 0, isclear and u or -1)
  RailWorks.SetControlValue("Speed2H", 0, isclear and -1 or h)
  RailWorks.SetControlValue("Speed2T", 0, isclear and -1 or t)
  RailWorks.SetControlValue("Speed2U", 0, isclear and -1 or u)
  RailWorks.SetControlValue("SpeedP", 0, Misc.getdigitguide(rspeed_mph))

  RailWorks.SetControlValue("ACSES_SpeedGreen", 0, adu:getgreenzone_mph())
  RailWorks.SetControlValue("ACSES_SpeedRed", 0, adu:getredzone_mph())

  RailWorks.SetControlValue("ATC_Node", 0, Misc.intbool(adu:getatcenforcing()))
  RailWorks.SetControlValue("ACSES_Node", 0,
                            Misc.intbool(adu:getacsesenforcing()))
end

local function setcutin()
  -- Reverse the polarities so that safety systems are on by default.
  -- ACSES and ATC shortcuts are reversed on NJT stock.
  adu:setatcstate(RailWorks.GetControlValue("ACSES", 0) == 0)
  adu:setacsesstate(RailWorks.GetControlValue("ATC", 0) == 0)
end

local function setexhaust(dt)
  local rpm = RailWorks.GetControlValue("RPM", 0)
  local fansleft = RailWorks.AddTime("Fans", dt * math.min(1, rpm / 200))
  if fansleft > 0 then RailWorks.SetTime("Fans", fansleft) end

  local running = RailWorks.GetControlValue("Startup", 0) == 1
  local rate, alpha
  local effort = math.max(0, (rpm - 300) / (900 - 300))
  if effort < 0.05 then
    rate, alpha = 0.05, 0.2
  elseif effort <= 0.25 then
    rate, alpha = 0.01, 0.75
  else
    rate, alpha = 0.005, 1
  end
  for _, emitter in ipairs({"Exhaust", "Exhaust2", "Exhaust3"}) do
    Call(emitter .. ":SetEmitterActive", Misc.intbool(running))
    Call(emitter .. ":SetEmitterRate", rate)
    Call(emitter .. ":SetEmitterColour", 0, 0, 0, alpha)
  end
end

local function setlights()
  local cablight = RailWorks.GetControlValue("CabLight", 0) == 1
  RailWorks.ActivateNode("lamp_on_left", cablight)
  RailWorks.ActivateNode("lamp_on_right", cablight)
  Call("CabLight:Activate", Misc.intbool(cablight))

  local numlights = RailWorks.GetControlValue("NumberLights", 0) == 1
  RailWorks.ActivateNode("numbers_lit", numlights)

  local steplights = RailWorks.GetControlValue("StepsLight", 0) == 1
  Call("Steplight_FL:Activate", Misc.intbool(steplights))
  Call("Steplight_FR:Activate", Misc.intbool(steplights))
  Call("Steplight_RL:Activate", Misc.intbool(steplights))
  Call("Steplight_RR:Activate", Misc.intbool(steplights))

  local brake = blight:isapplied()
  RailWorks.ActivateNode("status_green", not brake)
  RailWorks.ActivateNode("status_yellow", brake)
  -- NOTE: This doesn't actually work, because door status isn't reported for
  -- locomotives.
  RailWorks.ActivateNode("status_red",
                         doors:isleftdooropen() or doors:isrightdooropen())
end

local function setditchlights()
  local knob = RailWorks.GetControlValue("DitchLights", 0)
  local flash = knob >= 0.5 and knob < 1.5
  local fixed = knob >= 1.5 and not flash
  ditchflasher:setflashstate(flash)
  local flashleft = ditchflasher:ison()

  local showleft = fixed or (flash and flashleft)
  RailWorks.ActivateNode("ditch_front_left", showleft)
  Call("DitchFrontLeft:Activate", Misc.intbool(showleft))

  local showright = fixed or (flash and not flashleft)
  RailWorks.ActivateNode("ditch_front_right", showright)
  Call("DitchFrontRight:Activate", Misc.intbool(showright))

  RailWorks.ActivateNode("ditch_rear_left", false)
  Call("DitchRearLeft:Activate", Misc.intbool(false))
  RailWorks.ActivateNode("ditch_rear_right", false)
  Call("DitchRearRight:Activate", Misc.intbool(false))
end

local function setstrobelights()
  local function isshowing(period)
    if strobetime_s ~= nil then
      local since_s = RailWorks.GetSimulationTime() - strobetime_s
      return math.mod(since_s, period) <= 0.1
    else
      return false
    end
  end

  local showfl = isshowing(1.9)
  RailWorks.ActivateNode("strobe_front_left", showfl)
  Call("StrobeFrontLeft:Activate", Misc.intbool(showfl))

  local showrl = isshowing(1.85)
  RailWorks.ActivateNode("strobe_rear_left", showrl)
  Call("StrobeRearLeft:Activate", Misc.intbool(showrl))

  local showfr = isshowing(1.95)
  RailWorks.ActivateNode("strobe_front_right", showfr)
  Call("StrobeFrontRight:Activate", Misc.intbool(showfr))

  local showrr = isshowing(2)
  RailWorks.ActivateNode("strobe_rear_right", showrr)
  Call("StrobeRearRight:Activate", Misc.intbool(showrr))
end

local function setdestination()
  -- Broadcast the rail vehicle-derived destination, if any.
  if initdestination ~= nil and not Misc.isinitialized() then
    RailWorks.Engine_SendConsistMessage(messageid.destination, initdestination,
                                        0)
    RailWorks.Engine_SendConsistMessage(messageid.destination, initdestination,
                                        1)
  end
end

local function updateplayer(dt)
  readcontrols()

  adu:update(dt)
  alerter:update(dt)
  hep:update(dt)
  blight:playerupdate(dt)
  doors:update()

  writelocostate()
  setadu()
  setcutin()
  setexhaust(dt)
  setlights()
  setditchlights()
  setstrobelights()
  setdestination()
end

local function updatenonplayer(dt)
  doors:update()

  setexhaust(dt)
  setlights()
  setditchlights()
  setstrobelights()
  setdestination()
end

Update = Misc.wraperrors(function(dt)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer(dt)
  else
    updatenonplayer(dt)
  end
end)

OnControlValueChange = Misc.wraperrors(function(name, index, value)
  -- engine start/stop buttons
  if name == "EngineStart" and value == 1 then
    RailWorks.SetControlValue("EngineStart", 0, 0)
    RailWorks.SetControlValue("VirtualStartup", 0, 1)
    return
  elseif name == "EngineStop" and value == 1 then
    RailWorks.SetControlValue("EngineStop", 0, 0)
    RailWorks.SetControlValue("VirtualStartup", 0, -1)
    return
  end

  -- The player has changed the destination sign.
  if name == "Destination" and Misc.isinitialized() then
    RailWorks.Engine_SendConsistMessage(messageid.destination, value, 0)
    RailWorks.Engine_SendConsistMessage(messageid.destination, value, 1)
  end

  if name == "AWSReset" or name == "VirtualThrottle" or name == "VirtualBrake" then
    alerter:acknowledge()
  end

  RailWorks.SetControlValue(name, index, value)
end)

OnCustomSignalMessage = Misc.wraperrors(function(message)
  adu:receivemessage(message)
end)

OnConsistMessage = Misc.wraperrors(function(message, argument, direction)
  blight:receivemessage(message, argument, direction)

  RailWorks.Engine_SendConsistMessage(message, argument, direction)
end)
