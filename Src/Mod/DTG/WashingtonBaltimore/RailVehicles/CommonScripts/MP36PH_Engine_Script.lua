-- Engine script for the MPI MP36PH operated by MARC.
-- @include SafetySystems/Acses/Acses.lua
-- @include SafetySystems/AspectDisplay/AmtrakTwoSpeed.lua
-- @include SafetySystems/Alerter.lua
-- @include SafetySystems/Atc.lua
-- @include Signals/CabSignal.lua
-- @include Flash.lua
-- @include Iterator.lua
-- @include Misc.lua
-- @include RailWorks.lua
-- @include Scheduler.lua
-- @include Units.lua
local sched
local cabsig
local atc
local acses
local adu
local alerter
local ditchflasher
local state = {
  throttle = 0,
  train_brake = 0,
  indep_brake = 0,
  acknowledge = false,
  headlights = 0,
  rearlights = 0,
  pulselights = 0,

  speed_mps = 0,
  acceleration_mps2 = 0,
  trackspeed_mps = 0,
  consistlength_m = 0,
  speedlimits = {},
  restrictsignals = {},

  lasthorntime_s = nil
}

Initialise = Misc.wraperrors(function()
  sched = Scheduler:new{}

  cabsig = CabSignal:new{scheduler = sched}

  atc = Atc:new{
    scheduler = sched,
    cabsignal = cabsig,
    getspeed_mps = function() return state.speed_mps end,
    getacceleration_mps2 = function() return state.acceleration_mps2 end,
    getacknowledge = function() return state.acknowledge end,
    doalert = function() adu:doatcalert() end,
    getbrakesuppression = function() return state.train_brake >= 0.75 end
  }

  acses = Acses:new{
    scheduler = sched,
    cabsignal = cabsig,
    getspeed_mps = function() return state.speed_mps end,
    gettrackspeed_mps = function() return state.trackspeed_mps end,
    getconsistlength_m = function() return state.consistlength_m end,
    iterspeedlimits = function() return pairs(state.speedlimits) end,
    iterrestrictsignals = function() return pairs(state.restrictsignals) end,
    getacknowledge = function() return state.acknowledge end,
    doalert = function() adu:doacsesalert() end,
    consistspeed_mps = 125 * Units.mph.tomps
  }

  local onebeep_s = 1
  adu = AmtrakTwoSpeedAdu:new{
    scheduler = sched,
    cabsignal = cabsig,
    atc = atc,
    atcalert_s = onebeep_s,
    acses = acses,
    acsesalert_s = onebeep_s
  }

  atc:start()
  acses:start()

  alerter = Alerter:new{
    scheduler = sched,
    getspeed_mps = function() return state.speed_mps end
  }
  alerter:start()

  local ditchflash_s = 1
  ditchflasher = Flash:new{
    scheduler = sched,
    off_s = ditchflash_s,
    on_s = ditchflash_s
  }

  RailWorks.BeginUpdate()
end)

local function readcontrols()
  local throttle = RailWorks.GetControlValue("ThrottleAndBrake", 0)
  local vbrake = RailWorks.GetControlValue("VirtualBrake", 0)
  local change = throttle ~= state.throttle or vbrake ~= state.train_brake
  state.throttle = throttle
  state.train_brake = vbrake
  state.indep_brake = RailWorks.GetControlValue("VirtualEngineBrakeControl", 0)
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) == 1
  if state.acknowledge or change then alerter:acknowledge() end

  if RailWorks.GetControlValue("Horn", 0) > 0 then
    state.lasthorntime_s = sched:clock()
  end

  state.headlights = RailWorks.GetControlValue("Headlights", 0)
  state.rearlights = RailWorks.GetControlValue("Rearlights", 0)
  state.pulselights = RailWorks.GetControlValue("DitchLights", 0)
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
  do
    local throttle, dynbrake
    if penalty then
      throttle = 0
      dynbrake = 0
    else
      throttle = math.max(state.throttle, 0)
      dynbrake = math.max(-state.throttle, 0)
    end
    RailWorks.SetControlValue("Regulator", 0, throttle)
    RailWorks.SetControlValue("DynamicBrake", 0, dynbrake)
  end
  do
    local v
    if penalty then
      v = 0.85
    else
      v = state.train_brake
    end
    RailWorks.SetControlValue("TrainBrakeControl", 0, v)
  end
  RailWorks.SetControlValue("EngineBrakeControl", 0, state.indep_brake)
  do
    local alert = adu:isatcalert() or adu:isacsesalert()
    local alarm = atc:isalarm() or acses:isalarm() or alerter:isalarm()
    RailWorks.SetControlValue("TMS", 0, Misc.intbool(alert or alarm))
    RailWorks.SetControlValue("AWSWarnCount", 0, Misc.intbool(alarm))
  end
end

local function setspeedometer()
  local speed_mph = Misc.round(state.speed_mps * Units.mps.tomph)
  RailWorks.SetControlValue("SpeedoDots", 0, math.floor(speed_mph / 2))
  RailWorks.SetControlValue("SpeedoHundreds", 0, Misc.getdigit(speed_mph, 2))
  RailWorks.SetControlValue("SpeedoTens", 0, Misc.getdigit(speed_mph, 1))
  RailWorks.SetControlValue("SpeedoUnits", 0, Misc.getdigit(speed_mph, 0))
end

local function setcutin()
  -- Reverse the polarities so that safety systems are on by default.
  local atcon = RailWorks.GetControlValue("ATCCutIn", 0) == 0
  local acseson = RailWorks.GetControlValue("ACSESCutIn", 0) == 0
  atc:setrunstate(atcon)
  acses:setrunstate(acseson)
  alerter:setrunstate(atcon or acseson)
end

local function setadu()
  do
    local aspect = adu:getaspect()
    local n, l, s, m, r
    if aspect == AmtrakTwoSpeedAdu.aspect.stop then
      n, l, s, m, r = 0, 0, 1, 0, 0
    elseif aspect == AmtrakTwoSpeedAdu.aspect.restrict then
      n, l, s, m, r = 0, 0, 1, 0, 1
    elseif aspect == AmtrakTwoSpeedAdu.aspect.approach then
      n, l, s, m, r = 0, 1, 0, 0, 0
    elseif aspect == AmtrakTwoSpeedAdu.aspect.approachmed then
      n, l, s, m, r = 0, 1, 0, 1, 0
    elseif aspect == AmtrakTwoSpeedAdu.aspect.cabspeed then
      n, l, s, m, r = 1, 0, 0, 0, 0
    elseif aspect == AmtrakTwoSpeedAdu.aspect.cabspeedoff then
      n, l, s, m, r = 0, 0, 0, 0, 0
    elseif aspect == AmtrakTwoSpeedAdu.aspect.clear then
      n, l, s, m, r = 1, 0, 0, 0, 0
    end
    RailWorks.SetControlValue("SigN", 0, n)
    RailWorks.SetControlValue("SigL", 0, l)
    RailWorks.SetControlValue("SigS", 0, s)
    RailWorks.SetControlValue("SigM", 0, m)
    RailWorks.SetControlValue("SigR", 0, r)
  end
  if not sched:isstartup() then -- Stop the digits from flashing.
    local signalspeed_mph = adu:getsignalspeed_mph()
    if signalspeed_mph == nil then
      RailWorks.SetControlValue("SignalSpeed", 0, 0) -- blank
    else
      RailWorks.SetControlValue("SignalSpeed", 0, signalspeed_mph)
    end
  end
  do
    local civilspeed_mph = adu:getcivilspeed_mph()
    if civilspeed_mph == nil then
      RailWorks.SetControlValue("TSHundreds", 0, 0)
      RailWorks.SetControlValue("TSTens", 0, 0)
      RailWorks.SetControlValue("TSUnits", 0, -1)
    else
      RailWorks.SetControlValue("TSHundreds", 0,
                                Misc.getdigit(civilspeed_mph, 2))
      RailWorks.SetControlValue("TSTens", 0, Misc.getdigit(civilspeed_mph, 1))
      RailWorks.SetControlValue("TSUnits", 0, Misc.getdigit(civilspeed_mph, 0))
    end
  end
  RailWorks.SetControlValue("MaximumSpeedLimitIndicator", 0,
                            adu:getsquareindicator())
end

local function setcablight()
  Call("Cablight:Activate", RailWorks.GetControlValue("CabLight", 0))
end

local function setheadlight()
  local isdim = state.headlights >= 0.44 and state.headlights < 1.49 and
                  state.headlights ~= 1 -- set by AI?
  local isbright = state.headlights >= 1.49 or state.headlights == 1 -- set by AI?
  Call("Headlight_01_Dim:Activate", Misc.intbool(isdim or isbright))
  Call("Headlight_02_Dim:Activate", Misc.intbool(isdim or isbright))
  Call("Headlight_01_Bright:Activate", Misc.intbool(isbright))
  Call("Headlight_02_Bright:Activate", Misc.intbool(isbright))
end

local function setditchlights()
  local horntime_s = 30
  local horn = state.lasthorntime_s ~= nil and sched:clock() <=
                 state.lasthorntime_s + horntime_s
  local flash = state.pulselights == 1 or horn
  local fixed = state.headlights == 3 and not flash
  ditchflasher:setflashstate(flash)
  local flashleft = ditchflasher:ison()
  do
    local showleft = fixed or (flash and flashleft)
    RailWorks.ActivateNode("ditch_left", showleft)
    Call("Ditch_L:Activate", Misc.intbool(showleft))
  end
  do
    local showright = fixed or (flash and not flashleft)
    RailWorks.ActivateNode("ditch_right", showright)
    Call("Ditch_R:Activate", Misc.intbool(showright))
  end
  RailWorks.ActivateNode("lights_dim", fixed or flash)
end

local function setrearlight()
  local isdim = state.rearlights >= 1 and state.rearlights < 2
  local isbright = state.rearlights == 2
  Call("Rearlight_01_Dim:Activate", Misc.intbool(isdim or isbright))
  Call("Rearlight_02_Dim:Activate", Misc.intbool(isdim or isbright))
  Call("Rearlight_01_Bright:Activate", Misc.intbool(isbright))
  Call("Rearlight_02_Bright:Activate", Misc.intbool(isbright))
end

local function sethep()
  -- TODO: Unlike DTG's implementation, there is no startup delay, but I doubt
  -- anybody would really notice or care.
  local run = RailWorks.GetControlValue("HEP_State", 0)
  if sched:isstartup() then
    RailWorks.SetControlValue("HEP", 0, 1)
    RailWorks.SetControlValue("HEP_Off", 0, 0)
  else
    if run > 0 and RailWorks.GetControlValue("HEP_Off", 0) == 1 then
      RailWorks.SetControlValue("HEP", 0, 0)
      run = 0
    elseif run == 0 and RailWorks.GetControlValue("HEP", 0) == 1 then
      RailWorks.SetControlValue("HEP_Off", 0, 0)
      run = 1
    end
  end
  Call("Carriage Light 1:Activate", run)
  Call("Carriage Light 2:Activate", run)
  Call("Carriage Light 3:Activate", run)
  Call("Carriage Light 4:Activate", run)
  Call("Carriage Light 5:Activate", run)
  Call("Carriage Light 6:Activate", run)
  Call("Carriage Light 7:Activate", run)
  Call("Carriage Light 8:Activate", run)
  RailWorks.ActivateNode("1_1000_LitInteriorLights", run == 1)
  RailWorks.SetControlValue("HEP_State", 0, run)
end

local function updateplayer()
  readcontrols()
  readlocostate()

  sched:update()

  writelocostate()
  setspeedometer()
  setcutin()
  setadu()
  setcablight()
  setheadlight()
  setditchlights()
  setrearlight()
  sethep()
end

local function updateai()
  setcablight()
  setheadlight()
  setditchlights()
  setrearlight()
end

Update = Misc.wraperrors(function(_)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer()
  else
    updateai()
    RailWorks.EndUpdate()
    return
  end
end)

OnControlValueChange = RailWorks.SetControlValue

OnCustomSignalMessage = Misc.wraperrors(function(message)
  cabsig:receivemessage(message)
end)

OnConsistMessage = RailWorks.Engine_SendConsistMessage
