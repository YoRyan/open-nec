-- Engine script for the Arrow III operated by New Jersey Transit.
--
-- @include RollingStock/PowerSupply/Electrification.lua
-- @include RollingStock/PowerSupply/PowerSupply.lua
-- @include SafetySystems/Acses/Acses.lua
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
local messageid = {locationprobe = 10100, brakesapplied = 10101}

local playersched, anysched
local cabsig
local atc
local acses
local adu
local alerter
local power
local pantoanim
local ditchflasher
local decreaseonoff
local state = {
  mcontroller = 0,
  train_brake = 0,
  acknowledge = false,

  speed_mps = 0,
  acceleration_mps2 = 0,
  trackspeed_mps = 0,
  consistlength_m = 0,
  speedlimits = {},
  restrictsignals = {},

  lasthorntime_s = nil,
  brakesapplied = false
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
    consistspeed_mps = 80 * Units.mph.tomps
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

  power = PowerSupply:new{
    scheduler = anysched,
    modes = {
      [0] = function(elec)
        local contact = pantoanim:getposition() == 1
        return contact and elec:isavailable(Electrification.type.overhead)
      end
    }
  }
  power:setavailable(Electrification.type.overhead, true)

  pantoanim = Animation:new{
    scheduler = anysched,
    animation = "panto",
    duration_s = 0.5
  }

  local ditchflash_s = 1
  ditchflasher = Flash:new{
    scheduler = playersched,
    off_s = ditchflash_s,
    on_s = ditchflash_s
  }

  -- Modulate the speed reduction alert sound, which normally plays just once.
  decreaseonoff = Flash:new{scheduler = playersched, off_s = 0.1, on_s = 0.5}

  RailWorks.BeginUpdate()
end)

local function readcontrols()
  local mcontroller = RailWorks.GetControlValue("VirtualThrottle", 0)
  local vbrake = RailWorks.GetControlValue("VirtualBrake", 0)
  local change = mcontroller ~= state.mcontroller or vbrake ~= state.train_brake
  state.mcontroller = mcontroller
  state.train_brake = vbrake
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) == 1
  if state.acknowledge or change then alerter:acknowledge() end

  if RailWorks.GetControlValue("Horn", 0) > 0 then
    state.lasthorntime_s = playersched:clock()
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
  local penalty = alerter:ispenalty() or atc:ispenalty() or acses:ispenalty()
  local throttle, reverser
  if not power:haspower() then
    throttle, reverser = 0, 0
  elseif state.mcontroller > -1.5 and state.mcontroller < 1.5 then
    throttle, reverser = 0, 0
  elseif state.mcontroller > 0 then
    throttle, reverser = (state.mcontroller - 1) / 5, 1
  else
    throttle, reverser = (-state.mcontroller - 1) / 5, -1
  end
  RailWorks.SetControlValue("Regulator", 0, throttle)
  RailWorks.SetControlValue("Reverser", 0, reverser)
  RailWorks.SetControlValue("TrainBrakeControl", 0,
                            penalty and 0.9 or state.train_brake)

  local psi = RailWorks.GetControlValue("AirBrakePipePressurePSI", 0)
  local dynbrake = math.min((110 - psi) / 16, 1)
  RailWorks.SetControlValue("DynamicBrake", 0, dynbrake)
  RailWorks.SetControlValue("VirtualDynamicBrake", 0, dynbrake)

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

  local airbrakes = psi < 95
  state.brakesapplied = airbrakes
  RailWorks.Engine_SendConsistMessage(messageid.brakesapplied,
                                      tostring(airbrakes), 0)
  RailWorks.Engine_SendConsistMessage(messageid.brakesapplied,
                                      tostring(airbrakes), 1)
end

local function setpanto()
  pantoanim:setanimatedstate(
    RailWorks.GetControlValue("PantographControl", 0) == 1)
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

  -- The animations on this model are bugged and the green speed zone behaves
  -- like a speedometer, so use the red zone to show MAS.
  RailWorks.SetControlValue("ACSES_SpeedRed", 0,
                            adu:getgreenzone_mph(state.speed_mps))

  RailWorks.SetControlValue("ATC_Node", 0, Misc.intbool(atc:isalarm()))
  RailWorks.SetControlValue("ACSES_Node", 0, Misc.intbool(acses:isalarm()))
end

local function setcutin()
  -- Reverse the polarities so that safety systems are on by default.
  -- ACSES and ATC shortcuts are reversed on NJT stock.
  atc:setrunstate(RailWorks.GetControlValue("ACSES", 0) == 0)
  acses:setrunstate(RailWorks.GetControlValue("ATC", 0) == 0)
end

local function setcabfx()
  Call("CabLight:Activate", RailWorks.GetControlValue("CabLight", 0))
  RailWorks.SetTime("left_cabdoor",
                    RailWorks.GetControlValue("Left_CabDoor", 0) * 2)
  RailWorks.SetTime("right_cabdoor",
                    RailWorks.GetControlValue("Right_CabDoor", 0))
  RailWorks.SetTime("cabwindow", RailWorks.GetControlValue("CabWindow", 0) * 2)
end

local function setlights()
  local stepslight = RailWorks.GetControlValue("StepsLight", 0)
  for i = 1, 4 do Call("StepLight_0" .. i .. ":Activate", stepslight) end

  RailWorks.ActivateNode("st_red", false) -- unknown function
  RailWorks.ActivateNode("st_green", not state.brakesapplied)
  RailWorks.ActivateNode("st_yellow", state.brakesapplied)

  RailWorks.ActivateNode("left_door_light", RailWorks.GetControlValue(
                           "DoorsOpenCloseLeft", 0) == 1)
  RailWorks.ActivateNode("right_door_light", RailWorks.GetControlValue(
                           "DoorsOpenCloseRight", 0) == 1)

  local lightscmd = RailWorks.GetControlValue("Headlights", 0)
  RailWorks.ActivateNode("numbers_lit", lightscmd > 0.5)

  local hasdriver = RailWorks.GetControlValue("Driver", 0) == 1
  local isend = not RailWorks.Engine_SendConsistMessage(messageid.locationprobe,
                                                        "", 0)
  local ishead = isend and hasdriver
  local istail = isend and not hasdriver
  RailWorks.ActivateNode("lighthead", lightscmd > 0.5 and ishead)
  local showdim = lightscmd > 0.5 and lightscmd < 1.5 and ishead
  Call("Headlight_Dim_1:Activate", Misc.intbool(showdim))
  Call("Headlight_Dim_2:Activate", Misc.intbool(showdim))
  local showbright = lightscmd > 1.5 and ishead
  Call("Headlight_Bright_1:Activate", Misc.intbool(showbright))
  Call("Headlight_Bright_2:Activate", Misc.intbool(showbright))

  local showrear = lightscmd > 0.5 and istail
  RailWorks.ActivateNode("lighttail", showrear)
  for i = 1, 3 do
    Call("MarkerLight_" .. i .. ":Activate", Misc.intbool(showrear))
  end

  local horntime_s = 30
  local ditchflash = state.lasthorntime_s ~= nil and playersched:clock() <=
                       state.lasthorntime_s + horntime_s and ishead
  local ditchfixed = lightscmd > 1.5 and not ditchflash and ishead
  ditchflasher:setflashstate(ditchflash)
  RailWorks.ActivateNode("ditch", ditchflash or ditchfixed)
  local ditchleft = ditchflasher:ison()
  local showleft = ditchfixed or (ditchflash and ditchleft)
  local showright = ditchfixed or (ditchflash and not ditchleft)
  Call("Ditch_L:Activate", Misc.intbool(showleft))
  Call("Ditch_R:Activate", Misc.intbool(showright))
end

local function updateplayer()
  readcontrols()
  readlocostate()

  playersched:update()
  anysched:update()
  power:update()
  pantoanim:update()

  writelocostate()
  setpanto()
  setadu()
  setcutin()
  setcabfx()
  setlights()
end

local function updatenonplayer()
  anysched:update()
  power:update()
  pantoanim:update()

  setpanto()
  setcabfx()
  setlights()
end

Update = Misc.wraperrors(function(_)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer()
  else
    updatenonplayer()
  end
end)

OnControlValueChange = Misc.wraperrors(function(name, index, value)
  if name == "PantoOn" and value == 1 then
    RailWorks.SetControlValue("PantographControl", 0, 1)
    RailWorks.SetControlValue("PantoOn", 0, 0)
    return
  end

  RailWorks.SetControlValue(name, index, value)
end)

OnCustomSignalMessage = Misc.wraperrors(function(message)
  power:receivemessage(message)
  cabsig:receivemessage(message)
end)

OnConsistMessage = Misc.wraperrors(function(message, argument, direction)
  if message == messageid.locationprobe then
    return
  elseif message == messageid.brakesapplied then
    state.brakesapplied = argument == "true"
  end

  RailWorks.Engine_SendConsistMessage(message, argument, direction)
end)
