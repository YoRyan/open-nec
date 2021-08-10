-- Engine script for the EMD AEM-7 operated by Amtrak.
-- @include RollingStock/CruiseControl.lua
-- @include RollingStock/Power.lua
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
local cruise
local alerter
local power
local state = {
  throttle = 0,
  train_brake = 0,
  acknowledge = false,
  cruisespeed_mps = 0,
  cruiseenabled = false,

  speed_mps = 0,
  acceleration_mps2 = 0,
  trackspeed_mps = 0,
  consistlength_m = 0,
  speedlimits = {},
  restrictsignals = {}
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
    getbrakesuppression = function() return state.train_brake >= 0.5 end
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

  local onebeep_s = 0.3
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

  cruise = Cruise:new{
    scheduler = sched,
    getspeed_mps = function() return state.speed_mps end,
    gettargetspeed_mps = function() return state.cruisespeed_mps end,
    getenabled = function() return state.cruiseenabled end
  }

  alerter = Alerter:new{
    scheduler = sched,
    getspeed_mps = function() return state.speed_mps end
  }
  alerter:start()

  power = Power:new{available = {Power.types.overhead}}

  RailWorks.BeginUpdate()
end)

local function readcontrols()
  local vthrottle = RailWorks.GetControlValue("VirtualThrottle", 0)
  local vbrake = RailWorks.GetControlValue("VirtualBrake", 0)
  local change = vthrottle ~= state.throttle or vbrake ~= state.train_brake
  state.throttle = vthrottle
  state.train_brake = vbrake
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) == 1
  if state.acknowledge or change then alerter:acknowledge() end
end

local function readlocostate()
  local cruise_mph = RailWorks.GetControlValue("CruiseSet", 0)
  state.cruisespeed_mps = cruise_mph * Units.mph.tomps
  state.cruiseenabled = cruise_mph > 10
  state.speed_mps = RailWorks.GetControlValue("SpeedometerMPH", 0) *
                      Units.mph.tomps
  state.acceleration_mps2 = RailWorks.GetAcceleration()
  state.trackspeed_mps = RailWorks.GetCurrentSpeedLimit(1)
  state.consistlength_m = RailWorks.GetConsistLength()
  state.speedlimits = Iterator.totable(Misc.iterspeedlimits(
                                         Acses.nlimitlookahead))
  state.restrictsignals = Iterator.totable(
                            Misc.iterrestrictsignals(Acses.nsignallookahead))
  if RailWorks.GetControlValue("PantographControl", 0) == 1 then
    power:setcollectors(Power.types.overhead)
  else
    power:setcollectors()
  end
end

local function writelocostate()
  local penalty = atc:ispenalty() or acses:ispenalty() or alerter:ispenalty()
  do
    local v
    if not power:haspower() then
      v = 0
    elseif penalty then
      v = 0
    elseif state.cruiseenabled then
      v = math.min(state.throttle, cruise:getthrottle())
    else
      v = state.throttle
    end
    RailWorks.SetControlValue("Regulator", 0, v)
  end
  do
    local v
    if penalty then
      v = 0.99
    else
      v = state.train_brake
    end
    RailWorks.SetControlValue("TrainBrakeControl", 0, v)
  end
  do
    local v
    if penalty then
      v = 0.5
    else
      v = state.train_brake / 2
    end -- "blended braking"
    RailWorks.SetControlValue("DynamicBrake", 0, v)
  end

  -- Used for the dynamic brake sound?
  RailWorks.SetControlValue("DynamicCurrent", 0,
                            math.abs(RailWorks.GetControlValue("Ammeter", 0)))

  RailWorks.SetControlValue("AWS", 0, Misc.intbool(
                              atc:isalarm() or acses:isalarm() or
                                alerter:isalarm()))
  RailWorks.SetControlValue("AWSWarnCount", 0,
                            Misc.intbool(alerter:isalarm()))
  do
    local alert = adu:isatcalert() or adu:isacsesalert()
    local alarm = atc:isalarm() or acses:isalarm()
    RailWorks.SetControlValue("OverSpeedAlert", 0,
                              Misc.intbool(alert or alarm))
  end
end

local function setadu()
  do
    local aspect = adu:getaspect()
    local signalspeed_mph = adu:getsignalspeed_mph()
    local cs, cs1, cs2
    if aspect == AmtrakTwoSpeedAdu.aspect.stop then
      -- The model has no Stop aspect, so we have to use Restricting.
      cs, cs1, cs2 = 7, 0, 0
    elseif aspect == AmtrakTwoSpeedAdu.aspect.restrict then
      cs, cs1, cs2 = 7, 0, 0
    elseif aspect == AmtrakTwoSpeedAdu.aspect.approach then
      cs, cs1, cs2 = 6, 0, 0
    elseif aspect == AmtrakTwoSpeedAdu.aspect.approachmed then
      if signalspeed_mph == 30 then
        cs, cs1, cs2 = 6, 0, 1
      elseif signalspeed_mph == 45 then
        cs, cs1, cs2 = 4, 0, 1
      end
    elseif aspect == AmtrakTwoSpeedAdu.aspect.cabspeed then
      if signalspeed_mph == 60 then
        cs, cs1, cs2 = 3, 1, 0
      elseif signalspeed_mph == 80 then
        cs, cs1, cs2 = 2, 1, 0
      end
    elseif aspect == AmtrakTwoSpeedAdu.aspect.cabspeedoff then
      if signalspeed_mph == 60 then
        cs, cs1, cs2 = 3, 0, 0
      elseif signalspeed_mph == 80 then
        cs, cs1, cs2 = 2, 0, 0
      end
    elseif aspect == AmtrakTwoSpeedAdu.aspect.clear then
      cs, cs1, cs2 = 1, 1, 0
    end
    RailWorks.SetControlValue("CabSignal", 0, cs)
    RailWorks.SetControlValue("CabSignal1", 0, cs1)
    RailWorks.SetControlValue("CabSignal2", 0, cs2)
  end
  do
    local trackspeed_mph = adu:getcivilspeed_mph()
    if trackspeed_mph == nil then
      RailWorks.SetControlValue("TrackSpeed", 0, 14.5) -- blank
    else
      RailWorks.SetControlValue("TrackSpeed", 0, trackspeed_mph)
    end
  end
end

local function setcablight()
  local light = RailWorks.GetControlValue("CabLightControl", 0)
  Call("FrontCabLight:Activate", light)
  Call("RearCabLight:Activate", light)
end

local function setcutin()
  -- Reverse the polarities of the safety systems buttons so they are activated
  -- by default. If we set them ourselves, they won't stick.
  alerter:setrunstate(RailWorks.GetControlValue("AlertControl", 0) == 0)
  local speedcontrol = RailWorks.GetControlValue("SpeedControl", 0) == 0
  atc:setrunstate(speedcontrol)
  acses:setrunstate(speedcontrol)
end

Update = Misc.wraperrors(function(_)
  if not RailWorks.GetIsEngineWithKey() then
    RailWorks.EndUpdate()
    return
  end

  readcontrols()
  readlocostate()

  sched:update()

  writelocostate()
  setadu()
  setcablight()
  setcutin()
end)

OnControlValueChange = RailWorks.SetControlValue

OnCustomSignalMessage = Misc.wraperrors(function(message)
  power:receivemessage(message)
  cabsig:receivemessage(message)
end)

OnConsistMessage = RailWorks.Engine_SendConsistMessage
