-- Engine script for the Arrow III operated by New Jersey Transit.
--
-- @include RollingStock/PowerSupply/Electrification.lua
-- @include RollingStock/PowerSupply/PowerSupply.lua
-- @include RollingStock/BrakeLight.lua
-- @include SafetySystems/AspectDisplay/NjTransit.lua
-- @include SafetySystems/Alerter.lua
-- @include Animation.lua
-- @include Flash.lua
-- @include Misc.lua
-- @include RailWorks.lua
-- @include Scheduler.lua
-- @include Units.lua
local messageid = {locationprobe = 10100}

local playersched, anysched
local adu
local alerter
local power
local blight
local pantoanim
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
  restrictsignals = {}
}

Initialise = Misc.wraperrors(function()
  playersched = Scheduler:new{}
  anysched = Scheduler:new{}

  adu = NjTransitAdu:new{
    getbrakesuppression = function() return state.train_brake >= 0.5 end,
    getacknowledge = function() return state.acknowledge end,
    getspeed_mps = function() return state.speed_mps end,
    gettrackspeed_mps = function() return state.trackspeed_mps end,
    getconsistlength_m = function() return state.consistlength_m end,
    iterspeedlimits = function() return pairs(state.speedlimits) end,
    iterrestrictsignals = function() return pairs(state.restrictsignals) end,
    consistspeed_mps = 80 * Units.mph.tomps
  }

  alerter = Alerter:new{}
  alerter:start()

  power = PowerSupply:new{
    modes = {
      [0] = function(elec)
        local contact = pantoanim:getposition() == 1
        return contact and elec:isavailable(Electrification.type.overhead)
      end
    }
  }
  power:setavailable(Electrification.type.overhead, true)

  blight = BrakeLight:new{}

  pantoanim = Animation:new{animation = "panto", duration_s = 0.5}

  -- Modulate the speed reduction alert sound, which normally plays just once.
  decreaseonoff = Flash:new{scheduler = playersched, off_s = 0.1, on_s = 0.5}

  RailWorks.BeginUpdate()
end)

local function readcontrols()
  state.mcontroller = RailWorks.GetControlValue("VirtualThrottle", 0)
  state.train_brake = RailWorks.GetControlValue("VirtualBrake", 0)
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) > 0
  if state.acknowledge then alerter:acknowledge() end
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
  local safetyalarm = adu:isalarm()
  local safetyalert = adu:isalertplaying()
  RailWorks.SetControlValue("AWSWarnCount", 0,
                            Misc.intbool(vigilalarm or safetyalarm))
  RailWorks.SetControlValue("ACSES_Alert", 0, Misc.intbool(vigilalarm))
  decreaseonoff:setflashstate(safetyalarm)
  RailWorks.SetControlValue("ACSES_AlertDecrease", 0,
                            Misc.intbool(decreaseonoff:ison()))
  RailWorks.SetControlValue("ACSES_AlertIncrease", 0, Misc.intbool(safetyalert))
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

  local brakesapplied = blight:isapplied()
  RailWorks.ActivateNode("st_red", false) -- unknown function
  RailWorks.ActivateNode("st_green", not brakesapplied)
  RailWorks.ActivateNode("st_yellow", brakesapplied)

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

  local ditchlights = lightscmd > 1.5 and ishead
  RailWorks.ActivateNode("ditch", ditchlights)
  Call("Ditch_L:Activate", Misc.intbool(ditchlights))
  Call("Ditch_R:Activate", Misc.intbool(ditchlights))
end

local function updateplayer(dt)
  readcontrols()
  readlocostate()

  playersched:update()
  anysched:update()
  adu:update(dt)
  alerter:update(dt)
  power:update(dt)
  blight:playerupdate()
  pantoanim:update(dt)

  writelocostate()
  setpanto()
  setadu()
  setcutin()
  setcabfx()
  setlights()
end

local function updatenonplayer(dt)
  anysched:update()
  power:update(dt)
  pantoanim:update(dt)

  setpanto()
  setcabfx()
  setlights()
end

Update = Misc.wraperrors(function(dt)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer(dt)
  else
    updatenonplayer(dt)
  end
end)

OnControlValueChange = Misc.wraperrors(function(name, index, value)
  if name == "PantoOn" and value == 1 then
    RailWorks.SetControlValue("PantographControl", 0, 1)
    RailWorks.SetControlValue("PantoOn", 0, 0)
    return
  end

  if name == "VirtualThrottle" or name == "VirtualBrake" then
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

  if message == messageid.locationprobe then return end

  RailWorks.Engine_SendConsistMessage(message, argument, direction)
end)
