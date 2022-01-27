-- Engine script for the dual-power ALP-45DP operated by New Jersey Transit.
--
-- @include RollingStock/PowerSupply/Electrification.lua
-- @include RollingStock/PowerSupply/PowerSupply.lua
-- @include RollingStock/BrakeLight.lua
-- @include RollingStock/Doors.lua
-- @include RollingStock/Hep.lua
-- @include SafetySystems/AspectDisplay/NjTransitAnalog.lua
-- @include SafetySystems/Alerter.lua
-- @include Animation.lua
-- @include Flash.lua
-- @include Misc.lua
-- @include RailWorks.lua
-- @include Units.lua
local adu
local alerter
local power
local hep
local blight
local pantoanim
local doors
local decreaseonoff

local initdestination = nil
local lastwipertime_s = nil

local powermode = {diesel = 0, overhead = 1}
local messageid = {destination = 10100}
local dieselpower = 3600 / 5900

local function readrvnumber()
  local _, _, deststr, unitstr = string.find(RailWorks.GetRVNumber(),
                                             "(%a)(%d+)")
  local dest, unit
  if deststr ~= nil then
    dest = string.byte(string.upper(deststr)) - string.byte("A") + 1
    unit = tonumber(unitstr)
  else
    dest = nil
    unit = 4500
  end
  initdestination = dest
  RailWorks.SetControlValue("UnitT", 0, Misc.getdigit(unit, 1))
  RailWorks.SetControlValue("UnitU", 0, Misc.getdigit(unit, 0))
end

local function isstopped()
  local speed_mps = RailWorks.GetControlValue("SpeedometerMPH", 0) *
                      Units.mph.tomps
  return math.abs(speed_mps) < Misc.stopped_mps
end

Initialise = Misc.wraperrors(function()
  adu = NjTransitAnalogAdu:new{
    getbrakesuppression = function()
      return RailWorks.GetControlValue("VirtualBrake", 0) > 0.5
    end,
    getacknowledge = function()
      return RailWorks.GetControlValue("AWSReset", 0) > 0
    end,
    consistspeed_mps = 100 * Units.mph.tomps
  }

  alerter = Alerter:new{
    getacknowledge = function()
      return RailWorks.GetControlValue("AWSReset", 0) > 0
    end
  }
  alerter:start()

  power = PowerSupply:new{
    modecontrol = "PowerMode",
    eleccontrolmap = {[Electrification.type.overhead] = "PowerState"},
    transition_s = 100,
    getcantransition = function() return true end,
    modes = {
      [powermode.diesel] = function(elec) return true end,
      [powermode.overhead] = function(elec)
        local pantoup = pantoanim:getposition() == 1
        return pantoup and elec:isavailable(Electrification.type.overhead)
      end
    },
    getautomode = function(cp)
      if cp == Electrification.autochangepoint.ai_to_overhead then
        return powermode.electric
      elseif cp == Electrification.autochangepoint.ai_to_diesel then
        return powermode.diesel
      else
        return nil
      end
    end,
    oninit = function()
      local iselectric = power:getmode() == powermode.overhead
      power:setavailable(Electrification.type.overhead, iselectric)
    end
  }

  hep = Hep:new{
    getrun = function() return RailWorks.GetControlValue("HEP", 0) == 1 end
  }

  blight = BrakeLight:new{
    getbrakeson = function()
      -- Match the brake indicator light logic in the carriage script.
      return RailWorks.GetControlValue("TrainBrakeControl", 0) > 0
    end
  }

  pantoanim = Animation:new{animation = "Pantograph", duration_s = 2}

  doors = Doors:new{}

  -- Modulate the speed reduction alert sound, which normally plays just once.
  decreaseonoff = Flash:new{off_s = 0.1, on_s = 0.5}

  readrvnumber()
  RailWorks.BeginUpdate()
end)

local function writelocostate()
  local penalty = alerter:ispenalty() or adu:ispenalty()
  local haspower = power:haspower()
  local throttle, proportion
  if penalty or not haspower then
    throttle = 0
  else
    throttle = math.max(RailWorks.GetControlValue("ThrottleAndBrake", 0), 0)
  end
  if not haspower then
    proportion = 0
  elseif power:getmode() == powermode.diesel then
    proportion = dieselpower
  else
    proportion = 1
  end
  RailWorks.SetControlValue("Regulator", 0, throttle)
  RailWorks.SetControlValue("TrainBrakeControl", 0, penalty and 0.6 or
                              RailWorks.GetControlValue("VirtualBrake", 0))
  RailWorks.SetPowerProportion(-1, proportion)

  local psi = RailWorks.GetControlValue("AirBrakePipePressurePSI", 0)
  local dynbrake = math.min((110 - psi) / 16, 1)
  local dynthrottle = -math.min(
                        RailWorks.GetControlValue("ThrottleAndBrake", 0), 0)
  RailWorks.SetControlValue("DynamicBrake", 0, math.max(dynbrake, dynthrottle))

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

  local windowopen = RailWorks.GetControlValue("WindowLeft", 0) > 0.5 or
                       RailWorks.GetControlValue("WindowRight", 0) > 0.5
  RailWorks.SetControlValue("ExteriorSounds", 0, Misc.intbool(windowopen))

  RailWorks.SetControlValue("Horn", 0,
                            RailWorks.GetControlValue("VirtualHorn", 0))
  RailWorks.SetControlValue("Startup", 0,
                            RailWorks.GetControlValue("VirtualStartup", 0))
  RailWorks.SetControlValue("Sander", 0,
                            RailWorks.GetControlValue("VirtualSander", 0))
  RailWorks.SetControlValue("Bell", 0,
                            RailWorks.GetControlValue("VirtualBell", 0))
  RailWorks.SetControlValue("HEP_State", 0, Misc.intbool(hep:haspower()))
end

local function sethelperstate()
  local proportion
  if not power:haspower() then
    proportion = 0
  elseif power:getmode() == powermode.diesel then
    proportion = dieselpower
  else
    proportion = 1
  end
  RailWorks.SetPowerProportion(-1, proportion)
end

local function setplayerpanto()
  local before, after, remaining_s = power:gettransition()
  if before == powermode.overhead and after == powermode.diesel then
    -- Lower the pantograph at the end of the power transition sequence.
    if remaining_s <= 2 then
      RailWorks.SetControlValue("PantographControl", 0, 0)
    end
  end
end

local function setaipanto()
  -- Sync pantograph with power mode.
  local pmode = power:getmode()
  RailWorks.SetControlValue("PantographControl", 0,
                            Misc.intbool(pmode == powermode.overhead))
end

local function setpowerfx(dt)
  local exhaust, dieselrpm
  local rpm = RailWorks.GetControlValue("RPM", 0)
  local pmode = power:getmode()
  local before, after, remaining_s = power:gettransition()
  if before == powermode.overhead and after == powermode.diesel then
    exhaust = remaining_s <= 30
    dieselrpm = remaining_s <= 60 and rpm or 0
  elseif before == powermode.diesel and after == powermode.overhead then
    exhaust = remaining_s > 60
    dieselrpm = remaining_s > 30 and rpm or 0
  elseif pmode == nil then
    -- at startup
    exhaust = false
    dieselrpm = 0
  else
    -- normal operation
    local iselectric = pmode == powermode.overhead
    exhaust = not iselectric
    dieselrpm = iselectric and 0 or rpm
  end
  -- exhaust algorithm copied from that of the GP40PH
  local effort = (RailWorks.GetControlValue("RPM", 0) - 600) / (1500 - 600)
  local rate, alpha
  if effort < 0.05 then
    rate, alpha = 0.05, 0.2
  elseif effort <= 0.25 then
    rate, alpha = 0.01, 0.75
  else
    rate, alpha = 0.005, 1
  end
  for i = 1, 4 do
    Call("Exhaust" .. i .. ":SetEmitterActive", Misc.intbool(exhaust))
    Call("Exhaust" .. i .. ":SetEmitterRate", rate)
    Call("Exhaust" .. i .. ":SetEmitterColour", 0, 0, 0, alpha)
  end
  RailWorks.SetControlValue("VirtualRPM", 0, dieselrpm)
  pantoanim:setanimatedstate(
    RailWorks.GetControlValue("PantographControl", 0) == 1)

  local fansmove = math.min(1, math.max(0, dieselrpm - 300) / 300)
  local fansleft = RailWorks.AddTime("Fans", dt * fansmove)
  if fansleft > 0 then RailWorks.SetTime("Fans", fansleft) end
end

local function setspeedometer()
  local rspeed_mph = Misc.round(math.abs(
                                  RailWorks.GetControlValue("SpeedometerMPH", 0)))
  RailWorks.SetControlValue("SpeedH", 0, Misc.getdigit(rspeed_mph, 2))
  RailWorks.SetControlValue("SpeedT", 0, Misc.getdigit(rspeed_mph, 1))
  RailWorks.SetControlValue("SpeedU", 0, Misc.getdigit(rspeed_mph, 0))

  local acses_mph = adu:getcivilspeed_mph()
  if acses_mph ~= nil then
    RailWorks.SetControlValue("ACSES_SpeedH", 0, Misc.getdigit(acses_mph, 2))
    RailWorks.SetControlValue("ACSES_SpeedT", 0, Misc.getdigit(acses_mph, 1))
    RailWorks.SetControlValue("ACSES_SpeedU", 0, Misc.getdigit(acses_mph, 0))
  else
    RailWorks.SetControlValue("ACSES_SpeedH", 0, -1)
    RailWorks.SetControlValue("ACSES_SpeedT", 0, -1)
    RailWorks.SetControlValue("ACSES_SpeedU", 0, -1)
  end

  local aspect = adu:getaspect()
  local sigspeed_mph = adu:getsignalspeed_mph()
  local sig
  if aspect == NjTransitAnalogAdu.aspect.stop then
    sig = 8
  elseif aspect == NjTransitAnalogAdu.aspect.restrict then
    sig = 7
  elseif aspect == NjTransitAnalogAdu.aspect.approach then
    sig = 6
  elseif aspect == NjTransitAnalogAdu.aspect.approachmed then
    sig = sigspeed_mph == 45 and 4 or 5
  elseif aspect == NjTransitAnalogAdu.aspect.cabspeed or aspect ==
    NjTransitAnalogAdu.aspect.cabspeedoff then
    sig = sigspeed_mph == 60 and 3 or 2
  elseif aspect == NjTransitAnalogAdu.aspect.clear then
    sig = 1
  else
    sig = 0
  end
  RailWorks.SetControlValue("ACSES_SignalDisplay", 0, sig)

  RailWorks.SetControlValue("ATC_Node", 0, Misc.intbool(adu:getatcenforcing()))
  RailWorks.SetControlValue("ATC_CutOut", 0, Misc.intbool(not adu:getatcstate()))
  RailWorks.SetControlValue("ACSES_Node", 0,
                            Misc.intbool(adu:getacsesenforcing()))
  local acseson = adu:getacsesstate()
  RailWorks.SetControlValue("ACSES_CutIn", 0, Misc.intbool(acseson))
  RailWorks.SetControlValue("ACSES_CutOut", 0, Misc.intbool(not acseson))
end

local function setcutin()
  -- Reverse the polarities so that safety systems are on by default.
  -- ACSES and ATC shortcuts are reversed on NJT stock.
  adu:setatcstate(RailWorks.GetControlValue("ACSES", 0) == 0)
  adu:setacsesstate(RailWorks.GetControlValue("ATC", 0) == 0)
end

local function setcablights()
  Call("CabLight:Activate", RailWorks.GetControlValue("CabLight", 0))
  Call("DeskLight:Activate", RailWorks.GetControlValue("DeskLight", 0))
end

local function setditchlights()
  local lightson = RailWorks.GetControlValue("DitchLights", 0) == 1
  RailWorks.ActivateNode("ditch_left", lightson)
  RailWorks.ActivateNode("ditch_right", lightson)
  Call("DitchLight_Left:Activate", Misc.intbool(lightson))
  Call("DitchLight_Right:Activate", Misc.intbool(lightson))
end

local function setstatuslights()
  RailWorks.ActivateNode("LightsBlue",
                         RailWorks.GetControlValue("HandBrake", 0) == 1)
  RailWorks.ActivateNode("LightsRed",
                         doors:isleftdooropen() or doors:isrightdooropen())

  local brake = blight:isapplied()
  RailWorks.ActivateNode("LightsYellow", brake)
  RailWorks.ActivateNode("LightsGreen", not brake)
end

local function setwipers()
  local intwipetime_s = 3
  local wiperon = RailWorks.GetControlValue("VirtualWipers", 0) == 1
  local wipe
  if RailWorks.GetControlValue("WipersInt", 0) == 1 then
    if wiperon then
      local now = RailWorks.GetSimulationTime()
      if lastwipertime_s == nil or now - lastwipertime_s >= intwipetime_s then
        wipe = true
        lastwipertime_s = now
      else
        wipe = false
      end
    else
      wipe = false
      lastwipertime_s = nil
    end
  else
    wipe = wiperon
  end
  RailWorks.SetControlValue("Wipers", 0, Misc.intbool(wipe))
end

local function setebrake()
  if RailWorks.GetControlValue("VirtualEmergencyBrake", 0) == 1 then
    RailWorks.SetControlValue("EmergencyBrake", 0, 1)
  elseif isstopped() then
    RailWorks.SetControlValue("EmergencyBrake", 0, 0)
  end
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
  adu:update(dt)
  alerter:update(dt)
  power:update(dt)
  hep:update(dt)
  blight:playerupdate(dt)
  pantoanim:update(dt)
  doors:update(dt)

  setplayerpanto()
  writelocostate()
  setpowerfx(dt)
  setspeedometer()
  setcutin()
  setcablights()
  setditchlights()
  setstatuslights()
  setwipers()
  setebrake()
  setdestination()
end

local function updatehelper(dt)
  power:update(dt)
  pantoanim:update(dt)

  sethelperstate()
  setplayerpanto()
  setpowerfx(dt)
  setcablights()
  setditchlights()
  setstatuslights()
  setdestination()
end

local function updateai(dt)
  power:update(dt)
  pantoanim:update(dt)

  setaipanto()
  setpowerfx(dt)
  setcablights()
  setditchlights()
  setstatuslights()
  setdestination()
end

Update = Misc.wraperrors(function(dt)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer(dt)
  elseif RailWorks.GetIsPlayer() then
    updatehelper(dt)
  else
    updateai(dt)
  end
end)

OnControlValueChange = Misc.wraperrors(function(name, index, value)
  -- Synchronize headlight controls.
  if name == "HeadlightSwitch" then
    if value == -1 then
      RailWorks.SetControlValue("Headlights", 0, 2)
    elseif value == 0 then
      RailWorks.SetControlValue("Headlights", 0, 0)
    elseif value == 1 then
      RailWorks.SetControlValue("Headlights", 0, 1)
    end
  elseif name == "Headlights" then
    if value == 0 then
      RailWorks.SetControlValue("HeadlightSwitch", 0, 0)
    elseif value == 1 then
      RailWorks.SetControlValue("HeadlightSwitch", 0, 1)
    elseif value == 2 then
      RailWorks.SetControlValue("HeadlightSwitch", 0, -1)
    end
  end

  -- Synchronize wiper controls.
  if name == "VirtualWipers" then
    if value == 1 then
      if RailWorks.GetControlValue("WipersInt", 0) == 1 then
        RailWorks.SetControlValue("WipersSwitch", 0, -1)
      else
        RailWorks.SetControlValue("WipersSwitch", 0, 1)
      end
    elseif value == 0 then
      RailWorks.SetControlValue("WipersSwitch", 0, 0)
    end
  elseif name == "WipersInt" then
    if RailWorks.GetControlValue("VirtualWipers", 0) == 1 then
      if value == 1 then
        RailWorks.SetControlValue("WipersSwitch", 0, -1)
      elseif value == 0 then
        RailWorks.SetControlValue("WipersSwitch", 0, 1)
      end
    end
  end

  -- sander switch
  if name == "VirtualSander" then
    RailWorks.SetControlValue("SanderSwitch", 0, value)
  elseif name == "SanderSwitch" then
    RailWorks.SetControlValue("VirtualSander", 0, value)
  end

  -- bell switch
  if name == "VirtualBell" then
    RailWorks.SetControlValue("BellSwitch", 0, value)
  elseif name == "BellSwitch" then
    RailWorks.SetControlValue("VirtualBell", 0, value)
  end

  -- handbrake apply/release switch
  if name == "HandBrakeSwitch" then
    if value == 1 then
      RailWorks.SetControlValue("HandBrake", 0, 1)
    elseif value == -1 then
      RailWorks.SetControlValue("HandBrake", 0, 0)
    end
  end

  -- cab light switch
  if name == "CabLight" then
    RailWorks.SetControlValue("CabLightSwitch", 0, value)
  elseif name == "CabLightSwitch" then
    RailWorks.SetControlValue("CabLight", 0, value)
  end

  -- desk light switch
  if name == "DeskLight" then
    RailWorks.SetControlValue("DeskLightSwitch", 0, value)
  elseif name == "DeskLightSwitch" then
    RailWorks.SetControlValue("DeskLight", 0, value)
  end

  -- instrument lights switch
  if name == "InstrumentLights" then
    RailWorks.SetControlValue("InstrumentLightsSwitch", 0, value)
  elseif name == "InstrumentLightsSwitch" then
    RailWorks.SetControlValue("InstrumentLights", 0, value)
  end

  -- ditch lights switch
  if name == "DitchLights" then
    RailWorks.SetControlValue("DitchLightsSwitch", 0, value)
  elseif name == "DitchLightsSwitch" then
    RailWorks.SetControlValue("DitchLights", 0, value)
  end

  -- The player has changed the destination sign.
  if name == "Destination" and Misc.isinitialized() then
    RailWorks.Engine_SendConsistMessage(messageid.destination, value, 0)
    RailWorks.Engine_SendConsistMessage(messageid.destination, value, 1)
  end

  -- pantograph up/down switch and keyboard control
  local pantocmdup = nil
  if name == "PantographSwitch" then
    if value == -1 then
      RailWorks.SetControlValue("PantographControl", 0, 0)
      RailWorks.SetControlValue("VirtualPantographControl", 0, 0)
      pantocmdup = false
    elseif value == 1 then
      RailWorks.SetControlValue("PantographControl", 0, 1)
      RailWorks.SetControlValue("VirtualPantographControl", 0, 1)
      pantocmdup = true
    end
  elseif name == "VirtualPantographControl" then
    RailWorks.SetControlValue("PantographControl", 0, value)
    pantocmdup = value == 1
  end

  -- power switch controls
  if RailWorks.GetIsEngineWithKey() and Misc.isinitialized() then
    if name == "PowerSwitchAuto" and (value == 0 or value == 1) then
      Misc.showalert("Not available in OpenNEC")
    elseif RailWorks.GetControlValue("ThrottleAndBrake", 0) <= 0 and isstopped() then
      local pmode = power:getmode()
      if name == "PowerSwitch" and value == 1 then
        local nextmode = pmode == powermode.diesel and powermode.overhead or
                           powermode.diesel
        RailWorks.SetControlValue("PowerMode", 0, nextmode)
      elseif pmode == powermode.diesel and pantocmdup == true then
        RailWorks.SetControlValue("PowerMode", 0, powermode.overhead)
      elseif pmode == powermode.overhead and name == "FaultReset" and value == 1 then
        RailWorks.SetControlValue("PowerMode", 0, powermode.diesel)
      end
    end
  end
  if name == "FaultReset" and value == 1 then
    RailWorks.SetControlValue("FaultReset", 0, 0)
    return
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
