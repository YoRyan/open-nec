-- Engine script for the GP40PH operated by New Jersey Transit.
--
-- @include RollingStock/Doors.lua
-- @include RollingStock/Hep.lua
-- @include SafetySystems/Acses/Acses.lua
-- @include SafetySystems/AspectDisplay/NjTransit.lua
-- @include SafetySystems/Alerter.lua
-- @include SafetySystems/Atc.lua
-- @include Signals/CabSignal.lua
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
local hep
local doors
local ditchflasher
local decreaseonoff
local state = {
  throttle = 0,
  train_brake = 0,
  acknowledge = false,
  startup = false,
  rv_destination = nil,

  speed_mps = 0,
  acceleration_mps2 = 0,
  trackspeed_mps = 0,
  consistlength_m = 0,
  speedlimits = {},
  restrictsignals = {},

  lastrpmclock_s = nil,
  strobetime_s = nil
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

  cabsig = CabSignal:new{scheduler = playersched}

  atc = Atc:new{
    scheduler = playersched,
    cabsignal = cabsig,
    getspeed_mps = function() return state.speed_mps end,
    getacceleration_mps2 = function() return state.acceleration_mps2 end,
    getacknowledge = function() return state.acknowledge end,
    doalert = function() adu:doatcalert() end,
    getbrakesuppression = function() return state.train_brake >= 0.5 end
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
    consistspeed_mps = 90 * Units.mph.tomps,
    inforceafterviolation = false
  }

  local onebeep_s = 1
  adu = NjTransitAdu:new{
    scheduler = playersched,
    cabsignal = cabsig,
    atc = atc,
    atcalert_s = onebeep_s,
    acses = acses,
    acsesalert_s = onebeep_s
  }

  atc:start()
  acses:start()

  alerter = Alerter:new{
    scheduler = playersched,
    getspeed_mps = function() return state.speed_mps end
  }
  alerter:start()

  hep = Hep:new{
    scheduler = playersched,
    getrun = function() return state.startup end
  }

  doors = Doors:new{scheduler = anysched}

  local ditchflash_s = 1
  ditchflasher = Flash:new{
    scheduler = playersched,
    off_s = ditchflash_s,
    on_s = ditchflash_s
  }

  -- Modulate the speed reduction alert sound, which normally plays just once.
  decreaseonoff = Flash:new{scheduler = playersched, off_s = 0.1, on_s = 0.5}

  readrvnumber()
  RailWorks.BeginUpdate()
end)

local function readcontrols()
  local throttle = RailWorks.GetControlValue("VirtualThrottle", 0)
  local vbrake = RailWorks.GetControlValue("VirtualBrake", 0)
  local change = throttle ~= state.throttle or vbrake ~= state.train_brake
  state.throttle = throttle
  state.train_brake = vbrake
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) > 0
  if state.acknowledge or change then alerter:acknowledge() end
  state.startup = RailWorks.GetControlValue("VirtualStartup", 0) >= 0

  if RailWorks.GetControlValue("VirtualBell", 0) > 0 then
    if state.strobetime_s == nil then
      state.strobetime_s = playersched:clock()
    end
  else
    state.strobetime_s = nil
  end
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
  local penalty = atc:ispenalty() or acses:ispenalty() or alerter:ispenalty()
  RailWorks.SetControlValue("Regulator", 0, state.throttle)
  RailWorks.SetControlValue("TrainBrakeControl", 0,
                            penalty and 0.5 or state.train_brake)

  local psi = RailWorks.GetControlValue("AirBrakePipePressurePSI", 0)
  RailWorks.SetControlValue("DynamicBrake", 0, math.min((89 - psi) / 16, 1))

  local vigilalarm = alerter:isalarm()
  local safetyalarm = atc:isalarm() or acses:isalarm()
  local safetyalert = adu:isatcalert() or adu:isacsesalert()
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
  RailWorks.SetControlValue("Startup", 0, state.startup and 1 or -1)
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

local function setexhaust()
  local now = anysched:clock()
  local dt = state.lastrpmclock_s == nil and 0 or now - state.lastrpmclock_s
  state.lastrpmclock_s = now
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

  -- Match the brake indicator light logic in the carriage script.
  local brake = RailWorks.GetControlValue("TrainBrakeControl", 0) > 0
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
  local showtime_s = 0.1

  local showleft, showright
  if state.strobetime_s ~= nil then
    local since_s = playersched:clock() - state.strobetime_s
    local isince_s = math.floor(since_s)
    local show = since_s - isince_s <= showtime_s
    local isleft = math.mod(isince_s, 2) == 0
    showleft, showright = show and isleft, show and not isleft
  else
    showleft, showright = false, false
  end

  RailWorks.ActivateNode("strobe_front_left", showleft)
  Call("StrobeFrontLeft:Activate", Misc.intbool(showleft))
  RailWorks.ActivateNode("strobe_rear_left", showleft)
  Call("StrobeRearLeft:Activate", Misc.intbool(showleft))

  RailWorks.ActivateNode("strobe_front_right", showright)
  Call("StrobeFrontRight:Activate", Misc.intbool(showright))
  RailWorks.ActivateNode("strobe_rear_right", showright)
  Call("StrobeRearRight:Activate", Misc.intbool(showright))
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
  doors:update()

  writelocostate()
  setadu()
  setcutin()
  setexhaust()
  setlights()
  setditchlights()
  setstrobelights()
  setdestination()
end

local function updatenonplayer()
  anysched:update()
  doors:update()

  setexhaust()
  setlights()
  setditchlights()
  setstrobelights()
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
  if name == "Destination" and not anysched:isstartup() then
    RailWorks.Engine_SendConsistMessage(messageid.destination, value, 0)
    RailWorks.Engine_SendConsistMessage(messageid.destination, value, 1)
  end

  RailWorks.SetControlValue(name, index, value)
end)

OnCustomSignalMessage = Misc.wraperrors(function(message)
  cabsig:receivemessage(message)
end)

OnConsistMessage = RailWorks.Engine_SendConsistMessage
