-- Engine script for the ALP-46 operated by New Jersey Transit.
--
-- @include SafetySystems/Alerter.lua
-- @include SafetySystems/AspectDisplay/NjTransit.lua
-- @include YoRyan/LibRailWorks/Animation.lua
-- @include YoRyan/LibRailWorks/Flash.lua
-- @include YoRyan/LibRailWorks/Misc.lua
-- @include YoRyan/LibRailWorks/RailWorks.lua
-- @include YoRyan/LibRailWorks/RollingStock/BrakeLight.lua
-- @include YoRyan/LibRailWorks/RollingStock/Doors.lua
-- @include YoRyan/LibRailWorks/RollingStock/PowerSupply/Electrification.lua
-- @include YoRyan/LibRailWorks/RollingStock/PowerSupply/PowerSupply.lua
-- @include YoRyan/LibRailWorks/Units.lua
local adu
local alerter
local power
local blight
local frontpantoanim, rearpantoanim
local doors
local decreaseonoff

local initdestination = nil
local lastwipertime_s = nil

local messageid = {destination = 10100}

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

Initialise = Misc.wraperrors(function()
  adu = NjTransitAdu:new{
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

  blight = BrakeLight:new{
    getbrakeson = function()
      -- Match the brake indicator light logic in the carriage script.
      return RailWorks.GetControlValue("TrainBrakeControl", 0) > 0
    end
  }

  power = PowerSupply:new{
    modes = {
      [0] = function(elec)
        local contact = frontpantoanim:getposition() == 1 or
                          rearpantoanim:getposition() == 1
        return contact and elec:isavailable(Electrification.type.overhead)
      end
    }
  }
  power:setavailable(Electrification.type.overhead, true)

  local raisepanto_s = 2
  frontpantoanim = Animation:new{
    animation = "Pantograph1",
    duration_s = raisepanto_s
  }
  rearpantoanim = Animation:new{
    animation = "Pantograph2",
    duration_s = raisepanto_s
  }

  doors = Doors:new{}

  -- Modulate the speed reduction alert sound, which normally plays just once.
  decreaseonoff = Flash:new{off_s = 0.1, on_s = 0.5}

  readrvnumber()
  RailWorks.BeginUpdate()
end)

local function setplayercontrols()
  local penalty = alerter:ispenalty() or adu:ispenalty()
  local haspower = power:haspower()
  local throttle = (penalty or not haspower) and 0 or
                     math.max(RailWorks.GetControlValue("ThrottleAndBrake", 0),
                              0)
  RailWorks.SetControlValue("Regulator", 0, throttle)
  RailWorks.SetControlValue("TrainBrakeControl", 0, penalty and 0.6 or
                              RailWorks.GetControlValue("VirtualBrake", 0))

  local psi = RailWorks.GetControlValue("AirBrakePipePressurePSI", 0)
  local dynbrake = math.min((110 - psi) / 16, 1)
  local dynthrottle = -math.min(
                        RailWorks.GetControlValue("ThrottleAndBrake", 0), 0)
  RailWorks.SetControlValue("DynamicBrake", 0, math.max(dynbrake, dynthrottle))

  RailWorks.SetControlValue("Sander", 0,
                            RailWorks.GetControlValue("VirtualSander", 0))
  RailWorks.SetControlValue("Bell", 0,
                            RailWorks.GetControlValue("VirtualBell", 0))

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
  RailWorks.SetControlValue("EngineBrakeControl", 0, RailWorks.GetControlValue(
                              "VirtualEngineBrakeControl", 0))
  RailWorks.SetControlValue("Startup", 0,
                            RailWorks.GetControlValue("VirtualStartup", 0))
  RailWorks.SetControlValue("PantographControl", 0, RailWorks.GetControlValue(
                              "VirtualPantographControl", 0))
  RailWorks.SetControlValue("HEP_State", 0, Misc.intbool(haspower))
end

local function setpanto()
  frontpantoanim:setanimatedstate(false)
  rearpantoanim:setanimatedstate(RailWorks.GetControlValue("PantographControl",
                                                           0) == 1)
end

local function setspeedometer()
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

local function setcablights()
  local dome = RailWorks.GetControlValue("CabLight", 0)
  Call("CabLight1:Activate", dome)
  Call("CabLight2:Activate", dome)
  Call("CabLight3:Activate", dome)
  Call("CabLight4:Activate", dome)

  local gauge = RailWorks.GetControlValue("InstrumentLights", 0)
  Call("FDialLight01:Activate", gauge)
  Call("FDialLight02:Activate", gauge)
  Call("FDialLight03:Activate", gauge)
  Call("FDialLight04:Activate", gauge)
  Call("FBDialLight01:Activate", gauge)
  Call("FBDialLight02:Activate", gauge)
  Call("FBDialLight03:Activate", gauge)
  Call("FBDialLight04:Activate", gauge)
  Call("RDialLight01:Activate", gauge)
  Call("RDialLight02:Activate", gauge)
  Call("RDialLight03:Activate", gauge)
  Call("RDialLight04:Activate", gauge)
  Call("RBDialLight01:Activate", gauge)
  Call("RBDialLight02:Activate", gauge)
  Call("RBDialLight03:Activate", gauge)
  Call("RBDialLight04:Activate", gauge)
end

local function setditchlights()
  local lightson = RailWorks.GetControlValue("DitchLights", 0) == 1
  RailWorks.ActivateNode("FrontDitchLights", lightson)
  Call("ForwardDitch2:Activate", Misc.intbool(lightson))
  Call("ForwardDitch1:Activate", Misc.intbool(lightson))

  RailWorks.ActivateNode("RearDitchLights", false)
  Call("BackwardDitch2:Activate", 0)
  Call("BackwardDitch1:Activate", 0)
end

local function setwipers()
  local wipetime_s = 1.5
  local intwipetime_s = 3

  local now = RailWorks.GetSimulationTime()
  if RailWorks.GetControlValue("VirtualWipers", 0) == 1 then
    local wiperint = RailWorks.GetControlValue("WipersInt", 0) == 1
    local nextwipe_s = wiperint and intwipetime_s or wipetime_s
    if lastwipertime_s == nil or now - lastwipertime_s >= nextwipe_s then
      lastwipertime_s = now
    end
  end

  local since_s = lastwipertime_s ~= nil and now - lastwipertime_s or 0
  local pos
  if since_s <= wipetime_s / 2 then
    pos = since_s / (wipetime_s / 2)
  elseif since_s <= wipetime_s then
    pos = 2 - since_s / (wipetime_s / 2)
  else
    pos = 0
  end
  RailWorks.SetControlValue("WipersInterior", 0, pos)
  RailWorks.SetTime("WipersFront", pos / 2)
end

local function setebrake()
  local speed_mps = RailWorks.GetControlValue("SpeedometerMPH", 0) *
                      Units.mph.tomps
  if RailWorks.GetControlValue("VirtualEmergencyBrake", 0) == 1 then
    RailWorks.SetControlValue("EmergencyBrake", 0, 1)
  elseif math.abs(speed_mps) < Misc.stopped_mps then
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
  blight:playerupdate(dt)
  frontpantoanim:update(dt)
  rearpantoanim:update(dt)
  doors:update(dt)

  setplayercontrols()
  setpanto()
  setspeedometer()
  setcutin()
  setcablights()
  setditchlights()
  setwipers()
  setebrake()
  setdestination()
end

local function updatenonplayer(dt)
  power:update(dt)
  frontpantoanim:update(dt)
  rearpantoanim:update(dt)

  setpanto()
  setcablights()
  setditchlights()
  setebrake()
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

  -- pantograph up/down switch
  if name == "PantographSwitch" then
    if value == -1 then
      RailWorks.SetControlValue("PantographControl", 0, 0)
    elseif value == 1 then
      RailWorks.SetControlValue("PantographControl", 0, 1)
    end
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
