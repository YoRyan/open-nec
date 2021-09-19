-- Engine script for the Kawasaki M8 operated by Metro-North.
--
-- @include RollingStock/PowerSupply/Electrification.lua
-- @include RollingStock/PowerSupply/PowerSupply.lua
-- @include RollingStock/Spark.lua
-- @include SafetySystems/Acses/Acses.lua
-- @include SafetySystems/AspectDisplay/MetroNorth.lua
-- @include SafetySystems/Alerter.lua
-- @include SafetySystems/Atc.lua
-- @include Signals/CabSignal.lua
-- @include Animation.lua
-- @include Flash.lua
-- @include Iterator.lua
-- @include Misc.lua
-- @include RailWorks.lua
-- @include Scheduler.lua
-- @include Units.lua
local powermode = {overhead = 1, thirdrail = 2}

local playersched, anysched
local cabsig
local atc
local acses
local adu
local alerter
local power
local pantoanim
local alarmonoff
local spark
local state = {
  mcontroller = 0,
  acknowledge = false,
  headlights = 0,
  energyon = false,

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

  cabsig = CabSignal:new{scheduler = playersched}

  atc = Atc:new{
    scheduler = playersched,
    cabsignal = cabsig,
    getspeed_mps = function() return state.speed_mps end,
    getacceleration_mps2 = function() return state.acceleration_mps2 end,
    getacknowledge = function() return state.acknowledge end,
    doalert = function() adu:doatcalert() end,
    getbrakesuppression = function() return state.throttle <= -0.4 end
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
    restrictingspeed_mps = 15 * Units.mph.tomps
  }

  local alert_s = 1
  adu = MetroNorthAdu:new{
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

  local isthirdrail = string.sub(RailWorks.GetRVNumber(), 1, 1) == "T"
  power = PowerSupply:new{
    scheduler = anysched,
    modecontrol = "Panto",
    -- Combine AC panto down/up into a single mode.
    modereadfn = function(v) return math.max(v, 1) end,
    getcantransition = function() return state.mcontroller <= 0 end,
    modes = {
      [powermode.overhead] = function(elec)
        return state.energyon and pantoanim:getposition() == 1 and
                 elec:isavailable(Electrification.type.overhead)
      end,
      [powermode.thirdrail] = function(elec)
        return state.energyon and
                 elec:isavailable(Electrification.type.thirdrail)
      end
    },
    getautomode = function(cp)
      if cp == Electrification.autochangepoint.ai_to_overhead then
        return powermode.overhead
      elseif cp == Electrification.autochangepoint.ai_to_thirdrail then
        return powermode.thirdrail
      end
    end,
    oninit = function()
      if power:getmode() == powermode.overhead then
        -- Raise the pantograph if initializing in AC mode.
        RailWorks.SetControlValue("Panto", 0, 1)
        pantoanim:setposition(1)
      end
    end
  }
  power:setavailable(Electrification.type.overhead, not isthirdrail)
  power:setavailable(Electrification.type.thirdrail, isthirdrail)

  pantoanim = Animation:new{
    scheduler = anysched,
    animation = "panto",
    duration_s = 2
  }

  -- Modulate the speed reduction alert sound, which normally plays just once.
  alarmonoff = Flash:new{scheduler = playersched, off_s = 0.1, on_s = 0.5}

  spark = PantoSpark:new{scheduler = anysched}

  RailWorks.BeginUpdate()
end)

local function readcontrols()
  local mcontroller = RailWorks.GetControlValue("ThrottleAndBrake", 0)
  local change = mcontroller ~= state.mcontroller
  state.mcontroller = mcontroller
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) > 0
  if state.acknowledge or change then alerter:acknowledge() end

  state.headlights = RailWorks.GetControlValue("Headlights", 0)
  state.energyon = RailWorks.GetControlValue("PantographControl", 0) == 1
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
  local haspower = power:haspower()
  local penalty = alerter:ispenalty() or atc:ispenalty() or acses:ispenalty()
  local throttle, brake
  if penalty then
    throttle, brake = 0, 0.85
  else
    throttle = haspower and math.max(state.mcontroller, 0) or 0
    brake = math.max(-state.mcontroller, 0)
  end
  RailWorks.SetControlValue("Regulator", 0, throttle)
  RailWorks.SetControlValue("TrainBrakeControl", 0, brake)
  -- TODO: Also set DynamicBrake using DTG's algorithm.

  alarmonoff:setflashstate(atc:isalarm() or acses:isalarm())
  RailWorks.SetControlValue("SpeedReductionAlert", 0,
                            Misc.intbool(alarmonoff:ison()))
  RailWorks.SetControlValue("SpeedIncreaseAlert", 0, Misc.intbool(
                              adu:isatcalert() or adu:isacsesalert()))
  RailWorks.SetControlValue("AWS", 0, Misc.intbool(alerter:isalarm()))
end

local function setdrivescreen()
  local speed_mph = Misc.round(state.speed_mps * Units.mps.tomph)
  RailWorks.SetControlValue("SpeedoHundreds", 0, Misc.getdigit(speed_mph, 2))
  RailWorks.SetControlValue("SpeedoTens", 0, Misc.getdigit(speed_mph, 1))
  RailWorks.SetControlValue("SpeedoUnits", 0, Misc.getdigit(speed_mph, 0))

  local bp_psi = Misc.round(RailWorks.GetControlValue("AirBrakePipePressurePSI",
                                                      0))
  RailWorks.SetControlValue("PipeHundreds", 0, Misc.getdigit(bp_psi, 2))
  RailWorks.SetControlValue("PipeTens", 0, Misc.getdigit(bp_psi, 1))
  RailWorks.SetControlValue("PipeUnits", 0, Misc.getdigit(bp_psi, 0))

  local bc_psi = Misc.round(RailWorks.GetControlValue(
                              "TrainBrakeCylinderPressurePSI", 0))
  RailWorks.SetControlValue("CylinderHundreds", 0, Misc.getdigit(bc_psi, 2))
  RailWorks.SetControlValue("CylinderTens", 0, Misc.getdigit(bc_psi, 1))
  RailWorks.SetControlValue("CylinderUnits", 0, Misc.getdigit(bc_psi, 0))

  local _, after, _ = power:gettransition()
  local pmode = after or power:getmode()
  local haspower = power:haspower()
  if pmode == powermode.overhead then
    RailWorks.SetControlValue("PowerAC", 0, haspower and 2 or 1)
    RailWorks.SetControlValue("PowerDC", 0, 0)
  else
    RailWorks.SetControlValue("PowerAC", 0, 0)
    RailWorks.SetControlValue("PowerDC", 0, haspower and 2 or 1)
  end
end

local function setcutin()
  if not playersched:isstartup() then
    atc:setrunstate(RailWorks.GetControlValue("ATCCutIn", 0) == 1)
    acses:setrunstate(RailWorks.GetControlValue("ACSESCutIn", 0) == 1)
  end
end

local function setadu()
  local aspect = adu:getaspect()
  local n, l, m, r, s
  if aspect == MetroNorthAdu.aspect.stop then
    n, l, m, r, s = 0, 0, 0, 0, 1
  elseif aspect == MetroNorthAdu.aspect.restrict then
    n, l, m, r, s = 0, 0, 0, 1, 0
  elseif aspect == MetroNorthAdu.aspect.medium then
    n, l, m, r, s = 0, 0, 1, 0, 0
  elseif aspect == MetroNorthAdu.aspect.limited then
    n, l, m, r, s = 0, 1, 0, 0, 0
  elseif aspect == MetroNorthAdu.aspect.normal then
    n, l, m, r, s = 1, 0, 0, 0, 0
  end
  RailWorks.SetControlValue("SigN", 0, n)
  RailWorks.SetControlValue("SigL", 0, l)
  RailWorks.SetControlValue("SigM", 0, m)
  RailWorks.SetControlValue("SigR", 0, r)
  RailWorks.SetControlValue("SigS", 0, s)

  local signalspeed_mph = adu:getsignalspeed_mph()
  RailWorks.SetControlValue("SignalSpeed", 0,
                            signalspeed_mph == nil and 1 or signalspeed_mph)

  local civilspeed_mph = adu:getcivilspeed_mph()
  if civilspeed_mph == nil then
    RailWorks.SetControlValue("TrackSpeedHundreds", 0, 0)
    RailWorks.SetControlValue("TrackSpeedTens", 0, -1)
    RailWorks.SetControlValue("TrackSpeedUnits", 0, -1)
  else
    RailWorks.SetControlValue("TrackSpeedHundreds", 0,
                              Misc.getdigit(civilspeed_mph, 2))
    RailWorks.SetControlValue("TrackSpeedTens", 0,
                              Misc.getdigit(civilspeed_mph, 1))
    RailWorks.SetControlValue("TrackSpeedUnits", 0,
                              Misc.getdigit(civilspeed_mph, 0))
  end
end

local function setpanto()
  pantoanim:setanimatedstate(RailWorks.GetControlValue("Panto", 0) == 1)

  local contact = pantoanim:getposition() == 1
  local isspark = contact and spark:isspark()
  RailWorks.ActivateNode("panto_spark", isspark)
  Call("Spark:Activate", Misc.intbool(isspark))
end

local function setinteriorlights()
  local cab = RailWorks.GetControlValue("Cablight", 0)
  Call("Cablight:Activate", cab)

  local hep = power:haspower()
  RailWorks.ActivateNode("round_lights_off", not hep)
  RailWorks.ActivateNode("round_lights_on", hep)
  for i = 1, 9 do Call("PVLight_00" .. i .. ":Activate", Misc.intbool(hep)) end
  for i = 10, 12 do Call("PVLight_0" .. i .. ":Activate", Misc.intbool(hep)) end
  Call("HallLight_001:Activate", Misc.intbool(hep))
  Call("HallLight_002:Activate", Misc.intbool(hep))
end

local function setditchlights()
  local show = state.headlights > 0.5 and state.headlights < 1.5
  RailWorks.ActivateNode("left_ditch_light", show)
  RailWorks.ActivateNode("right_ditch_light", show)
  Call("Fwd_DitchLightLeft:Activate", Misc.intbool(show))
  Call("Fwd_DitchLightRight:Activate", Misc.intbool(show))
end

local function updateplayer()
  readcontrols()
  readlocostate()

  playersched:update()
  anysched:update()
  power:update()
  pantoanim:update()

  writelocostate()
  setdrivescreen()
  setcutin()
  setadu()
  setpanto()
  setinteriorlights()
  setditchlights()
end

local function updatenonplayer()
  anysched:update()
  power:update()
  pantoanim:update()

  setpanto()
  setinteriorlights()
  setditchlights()
end

Update = Misc.wraperrors(function(_)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer()
  else
    updatenonplayer()
  end
end)

OnControlValueChange = RailWorks.SetControlValue

OnCustomSignalMessage = Misc.wraperrors(function(message)
  power:receivemessage(message)
  cabsig:receivemessage(message)
end)

OnConsistMessage = RailWorks.Engine_SendConsistMessage
