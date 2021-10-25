-- Engine script for the ALP-46 operated by New Jersey Transit.
--
-- @include RollingStock/PowerSupply/Electrification.lua
-- @include RollingStock/PowerSupply/PowerSupply.lua
-- @include RollingStock/BrakeLight.lua
-- @include RollingStock/Doors.lua
-- @include SafetySystems/Acses/NjtAses.lua
-- @include SafetySystems/AspectDisplay/NjTransit.lua
-- @include SafetySystems/Alerter.lua
-- @include SafetySystems/Atc.lua
-- @include Signals/CabSignal.lua
-- @include Animation.lua
-- @include Flash.lua
-- @include Misc.lua
-- @include RailWorks.lua
-- @include Scheduler.lua
-- @include Units.lua
local messageid = {destination = 10100}

local playersched, anysched
local cabsig
local atc
local acses
local adu
local alerter
local power
local blight
local frontpantoanim, rearpantoanim
local doors
local decreaseonoff
local state = {
  throttle = 0,
  train_brake = 0,
  acknowledge = false,
  rv_destination = nil,

  speed_mps = 0,
  acceleration_mps2 = 0,
  trackspeed_mps = 0,
  consistlength_m = 0,
  speedlimits = {},
  restrictsignals = {}
}

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
  state.rv_destination = dest
  RailWorks.SetControlValue("UnitT", 0, Misc.getdigit(unit, 1))
  RailWorks.SetControlValue("UnitU", 0, Misc.getdigit(unit, 0))
end

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
    getbrakesuppression = function() return state.train_brake > 0.5 end
  }

  acses = NjtAses:new{
    scheduler = playersched,
    cabsignal = cabsig,
    getspeed_mps = function() return state.speed_mps end,
    gettrackspeed_mps = function() return state.trackspeed_mps end,
    getconsistlength_m = function() return state.consistlength_m end,
    iterspeedlimits = function() return pairs(state.speedlimits) end,
    iterrestrictsignals = function() return pairs(state.restrictsignals) end,
    getacknowledge = function() return state.acknowledge end,
    consistspeed_mps = 100 * Units.mph.tomps
  }

  local onebeep_s = 1
  adu = NjTransitAdu:new{
    scheduler = playersched,
    cabsignal = cabsig,
    atc = atc,
    acses = acses,
    alert_s = onebeep_s
  }

  atc:start()
  acses:start()

  alerter = Alerter:new{
    scheduler = playersched,
    getspeed_mps = function() return state.speed_mps end
  }
  alerter:start()

  blight = BrakeLight:new{
    getbrakeson = function()
      -- Match the brake indicator light logic in the carriage script.
      return RailWorks.GetControlValue("TrainBrakeControl", 0) > 0
    end
  }

  power = PowerSupply:new{
    scheduler = anysched,
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
    scheduler = anysched,
    animation = "Pantograph1",
    duration_s = raisepanto_s
  }
  rearpantoanim = Animation:new{
    scheduler = anysched,
    animation = "Pantograph2",
    duration_s = raisepanto_s
  }

  doors = Doors:new{scheduler = playersched}

  -- Modulate the speed reduction alert sound, which normally plays just once.
  decreaseonoff = Flash:new{scheduler = playersched, off_s = 0.1, on_s = 0.5}

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
  local haspower = power:haspower()
  local throttle = (penalty or not haspower) and 0 or
                     math.max(state.throttle, 0)
  RailWorks.SetControlValue("Regulator", 0, throttle)
  RailWorks.SetControlValue("TrainBrakeControl", 0,
                            penalty and 0.6 or state.train_brake)

  local psi = RailWorks.GetControlValue("AirBrakePipePressurePSI", 0)
  local dynbrake = math.min((110 - psi) / 16, 1)
  local dynthrottle = -math.min(state.throttle, 0)
  RailWorks.SetControlValue("DynamicBrake", 0, math.max(dynbrake, dynthrottle))

  RailWorks.SetControlValue("Sander", 0,
                            RailWorks.GetControlValue("VirtualSander", 0))
  RailWorks.SetControlValue("Bell", 0,
                            RailWorks.GetControlValue("VirtualBell", 0))

  local vigilalarm = alerter:isalarm()
  local safetyalarm = atc:isalarm() or acses:isalarm()
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

  RailWorks.SetControlValue("ATC_Node", 0, Misc.intbool(atc:isalarm()))
  RailWorks.SetControlValue("ACSES_Node", 0, Misc.intbool(acses:isalarm()))
end

local function setcutin()
  -- Reverse the polarities so that safety systems are on by default.
  -- ACSES and ATC shortcuts are reversed on NJT stock.
  atc:setrunstate(RailWorks.GetControlValue("ACSES", 0) == 0)
  acses:setrunstate(RailWorks.GetControlValue("ATC", 0) == 0)
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

  local now = playersched:clock()
  if RailWorks.GetControlValue("VirtualWipers", 0) == 1 then
    local wiperint = RailWorks.GetControlValue("WipersInt", 0) == 1
    local nextwipe_s = wiperint and intwipetime_s or wipetime_s
    if state.lastwipertime_s == nil or now - state.lastwipertime_s >= nextwipe_s then
      state.lastwipertime_s = now
    end
  end

  local since_s =
    state.lastwipertime_s ~= nil and now - state.lastwipertime_s or 0
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
  if RailWorks.GetControlValue("VirtualEmergencyBrake", 0) == 1 then
    RailWorks.SetControlValue("EmergencyBrake", 0, 1)
  elseif math.abs(state.speed_mps) < Misc.stopped_mps then
    RailWorks.SetControlValue("EmergencyBrake", 0, 0)
  end
end

local function setdestination()
  -- Broadcast the rail vehicle-derived destination, if any.
  if state.rv_destination ~= nil and anysched:isstartup() then
    RailWorks.Engine_SendConsistMessage(messageid.destination,
                                        state.rv_destination, 0)
    RailWorks.Engine_SendConsistMessage(messageid.destination,
                                        state.rv_destination, 1)
  end
end

local function updateplayer()
  readcontrols()
  readlocostate()

  playersched:update()
  anysched:update()
  power:update()
  blight:playerupdate()
  frontpantoanim:update()
  rearpantoanim:update()
  doors:update()

  writelocostate()
  setpanto()
  setspeedometer()
  setcutin()
  setcablights()
  setditchlights()
  setwipers()
  setebrake()
  setdestination()
end

local function updatenonplayer()
  anysched:update()
  power:update()
  frontpantoanim:update()
  rearpantoanim:update()

  setpanto()
  setcablights()
  setditchlights()
  setebrake()
  setdestination()
end

Update = Misc.wraperrors(function(_)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer()
  else
    updatenonplayer()
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
  if name == "Destination" and not anysched:isstartup() then
    RailWorks.Engine_SendConsistMessage(messageid.destination, value, 0)
    RailWorks.Engine_SendConsistMessage(messageid.destination, value, 1)
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

