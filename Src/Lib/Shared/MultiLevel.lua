-- Engine script for the Bombardier Multilevel cab car operated by NJ Transit
-- and MARC.
--
-- @include RollingStock/PowerSupply/Electrification.lua
-- @include RollingStock/PowerSupply/PowerSupply.lua
-- @include RollingStock/BrakeLight.lua
-- @include RollingStock/Doors.lua
-- @include RollingStock/Hep.lua
-- @include SafetySystems/AspectDisplay/NjTransit.lua
-- @include SafetySystems/Alerter.lua
-- @include Animation.lua
-- @include Flash.lua
-- @include Iterator.lua
-- @include Misc.lua
-- @include RailWorks.lua
-- @include Scheduler.lua
-- @include Units.lua
local powermode = {diesel = 0, overhead = 1}

local playersched
local anysched
local adu
local alerter
local power
local hep
local blight
local doors
local leftdoorsanim, rightdoorsanim
local alarmonoff
local state = {
  throttle = 0,
  train_brake = 0,
  acknowledge = false,
  hep = false,
  rv_destination = nil,

  speed_mps = 0,
  acceleration_mps2 = 0,
  trackspeed_mps = 0,
  consistlength_m = 0,
  speedlimits = {},
  restrictsignals = {}
}

local messageid = {destination = 10100}

local destinations = {
  "Dest_Trenton",
  "Dest_NewYork",
  "Dest_LongBranch",
  "Dest_Hoboken",
  "Dest_Dover",
  "Dest_BayHead"
}

local function readrvnumber()
  local _, _, deststr = string.find(RailWorks.GetRVNumber(), "(%a)")
  local dest
  if deststr ~= nil then
    dest = string.byte(string.upper(deststr)) - string.byte("A") + 1
  else
    dest = nil
  end
  state.rv_destination = dest
end

Initialise = Misc.wraperrors(function()
  playersched = Scheduler:new{}
  anysched = Scheduler:new{}

  adu = NjTransitAdu:new{
    getbrakesuppression = function() return state.train_brake > 0.5 end,
    getacknowledge = function() return state.acknowledge end,
    getspeed_mps = function() return state.speed_mps end,
    gettrackspeed_mps = function() return state.trackspeed_mps end,
    getconsistlength_m = function() return state.consistlength_m end,
    iterspeedlimits = function() return pairs(state.speedlimits) end,
    iterrestrictsignals = function() return pairs(state.restrictsignals) end,
    consistspeed_mps = (ismarc and 125 or 100) * Units.mph.tomps
  }

  power = PowerSupply:new{
    scheduler = anysched,
    modecontrol = "PowerMode",
    eleccontrolmap = {[Electrification.type.overhead] = "PowerState"},
    transition_s = 100,
    getcantransition = function() return true end,
    modes = {
      [powermode.diesel] = function(elec) return true end,
      [powermode.overhead] = function(elec) return true end
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
    scheduler = playersched,
    getrun = function() return state.hep end
  }

  blight = BrakeLight:new{
    getbrakeson = function()
      -- Match the brake indicator light logic in the carriage script.
      return RailWorks.GetControlValue("TrainBrakeControl", 0) > 0
    end
  }

  local doors_s = 1
  leftdoorsanim = Animation:new{
    scheduler = anysched,
    animation = "Doors_L",
    duration_s = doors_s
  }
  rightdoorsanim = Animation:new{
    scheduler = anysched,
    animation = "Doors_R",
    duration_s = doors_s
  }
  doors = Doors:new{
    scheduler = anysched,
    leftanimation = leftdoorsanim,
    rightanimation = rightdoorsanim
  }

  alerter = Alerter:new{
    scheduler = playersched,
    getspeed_mps = function() return state.speed_mps end
  }
  alerter:start()

  -- Modulate the speed reduction alert sound, which normally plays just once.
  alarmonoff = Flash:new{scheduler = playersched, off_s = 0.1, on_s = 0.5}

  readrvnumber()
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
  state.hep = RailWorks.GetControlValue("HEP", 0) == 1
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
  local penalty = alerter:ispenalty() or adu:ispenalty()

  local throttle = penalty and 0 or math.max(state.throttle, 0)
  RailWorks.SetControlValue("Regulator", 0, throttle)

  local airbrake = penalty and 0.6 or state.train_brake
  RailWorks.SetControlValue("TrainBrakeControl", 0, airbrake)

  local psi = RailWorks.GetControlValue("AirBrakePipePressurePSI", 0)
  RailWorks.SetControlValue("DynamicBrake", 0, math.min((110 - psi) / 16, 1))

  RailWorks.SetControlValue("Reverser", 0,
                            RailWorks.GetControlValue("UserVirtualReverser", 0))
  RailWorks.SetControlValue("Horn", 0,
                            RailWorks.GetControlValue("VirtualHorn", 0))
  RailWorks.SetControlValue("Bell", 0,
                            RailWorks.GetControlValue("VirtualBell", 0))
  RailWorks.SetControlValue("Wipers", 0,
                            RailWorks.GetControlValue("VirtualWipers", 0))
  RailWorks.SetControlValue("Sander", 0,
                            RailWorks.GetControlValue("VirtualSander", 0))
  RailWorks.SetControlValue("HEP_State", 0, Misc.intbool(hep:haspower()))

  local atcalarm = adu:getatcenforcing()
  local acsesalarm = adu:getacsesenforcing()
  local alertalarm = alerter:isalarm()
  local alert = adu:isalertplaying()
  if isnjcl then
    RailWorks.SetControlValue("AWS", 0, Misc.intbool(
                                atcalarm or acsesalarm or alertalarm or alert))
  else
    RailWorks.SetControlValue("ACSES_Alert", 0, Misc.intbool(alertalarm))
    RailWorks.SetControlValue("ACSES_AlertIncrease", 0, Misc.intbool(alert))
    alarmonoff:setflashstate(atcalarm or acsesalarm)
    RailWorks.SetControlValue("ACSES_AlertDecrease", 0,
                              Misc.intbool(alarmonoff:ison()))
  end
  RailWorks.SetControlValue("AWSWarnCount", 0,
                            Misc.intbool(atcalarm or acsesalarm or alertalarm))
end

local function setspeedometer()
  local isclear = adu:isclearsignal()
  local rspeed_mph = Misc.round(math.abs(state.speed_mps) * Units.mps.tomph)
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

  RailWorks.SetControlValue("ACSES_SpeedGreen", 0,
                            adu:getgreenzone_mph(state.speed_mps))
  RailWorks.SetControlValue("ACSES_SpeedRed", 0,
                            adu:getredzone_mph(state.speed_mps))
end

local function setcutin()
  -- Reverse the polarities so that safety systems are on by default.
  -- ACSES and ATC shortcuts are reversed on NJT stock.
  adu:setatcstate(RailWorks.GetControlValue("ACSES", 0) == 0)
  adu:setacsesstate(RailWorks.GetControlValue("ATC", 0) == 0)
end

local function setcablight()
  local dome = RailWorks.GetControlValue("CabLight", 0)
  RailWorks.ActivateNode("cablights", dome == 1)
  Call("CabLight:Activate", dome)
  Call("CabLight2:Activate", dome)
end

local function setditchlights()
  local lightson = RailWorks.GetControlValue("HeadlightSwitch", 0) >= 1 and
                     RailWorks.GetControlValue("DitchLights", 0) == 1
  RailWorks.ActivateNode("ditch_left", lightson)
  RailWorks.ActivateNode("ditch_right", lightson)
  Call("Ditch_L:Activate", Misc.intbool(lightson))
  Call("Ditch_R:Activate", Misc.intbool(lightson))
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

local function setcoachlights()
  local lightson = RailWorks.GetControlValue("HEP_State", 0) == 1
  for i = 1, 8 do
    Call("Carriage Light " .. i .. ":Activate", Misc.intbool(lightson))
  end
  RailWorks.ActivateNode("1_1000_LitInteriorLights", lightson)
end

local function showdestination(idx)
  local valid = idx >= 1 and idx <= table.getn(destinations)
  for i, node in ipairs(destinations) do
    RailWorks.ActivateNode(node, i == (valid and idx or 1))
  end
end

local function setdestination()
  -- Broadcast the rail vehicle-derived destination, if any.
  if state.rv_destination ~= nil and anysched:isstartup() then
    RailWorks.Engine_SendConsistMessage(messageid.destination,
                                        state.rv_destination, 0)
    RailWorks.Engine_SendConsistMessage(messageid.destination,
                                        state.rv_destination, 1)
    showdestination(state.rv_destination)
  end
end

local function updateplayer(dt)
  readcontrols()
  readlocostate()

  playersched:update()
  anysched:update()
  adu:update(dt)
  power:update()
  blight:playerupdate()
  leftdoorsanim:update()
  rightdoorsanim:update()
  doors:update()

  writelocostate()
  setspeedometer()
  setcutin()
  setcablight()
  setditchlights()
  setstatuslights()
  setcoachlights()
  setdestination()
end

local function updatenonplayer()
  anysched:update()
  power:update()
  leftdoorsanim:update()
  rightdoorsanim:update()
  doors:update()

  setcablight()
  setditchlights()
  setstatuslights()
  setcoachlights()
  setdestination()
end

Update = Misc.wraperrors(function(dt)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer(dt)
  else
    updatenonplayer()
  end
end)

OnControlValueChange = Misc.wraperrors(function(name, index, value)
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

  -- The player has changed the destination sign.
  if name == "Destination" and not anysched:isstartup() then
    RailWorks.Engine_SendConsistMessage(messageid.destination, value, 0)
    RailWorks.Engine_SendConsistMessage(messageid.destination, value, 1)
    showdestination(value)
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
  -- The Fault Reset button does not work in DTG's model, so just use the
  -- pantograph control to switch power modes.
  if RailWorks.GetIsEngineWithKey() and not anysched:isstartup() then
    if name == "PowerSwitchAuto" and (value == 0 or value == 1) then
      Misc.showalert("Not available in OpenNEC")
    elseif state.throttle <= 0 and state.speed_mps < Misc.stopped_mps then
      local pmode = power:getmode()
      if name == "PowerSwitch" and value == 1 then
        local nextmode = pmode == powermode.diesel and powermode.overhead or
                           powermode.diesel
        RailWorks.SetControlValue("PowerMode", 0, nextmode)
      elseif pmode == powermode.diesel and pantocmdup == true then
        RailWorks.SetControlValue("PowerMode", 0, powermode.overhead)
      elseif pmode == powermode.overhead and pantocmdup == false then
        RailWorks.SetControlValue("PowerMode", 0, powermode.diesel)
      end
    end
  end

  RailWorks.SetControlValue(name, index, value)
end)

OnCustomSignalMessage = Misc.wraperrors(function(message)
  power:receivemessage(message)
  adu:receivemessage(message)
end)

OnConsistMessage = Misc.wraperrors(function(message, argument, direction)
  blight:receivemessage(message, argument, direction)

  -- Render the received destination sign.
  if message == messageid.destination then showdestination(tonumber(argument)) end

  RailWorks.Engine_SendConsistMessage(message, argument, direction)
end)
