-- Engine script for the Bombardier HHP-8 operated by Amtrak.
--
-- @include RollingStock/PowerSupply/Electrification.lua
-- @include RollingStock/PowerSupply/PowerSupply.lua
-- @include RollingStock/BrakeLight.lua
-- @include RollingStock/CruiseControl.lua
-- @include RollingStock/Spark.lua
-- @include SafetySystems/AspectDisplay/AmtrakTwoSpeed.lua
-- @include SafetySystems/Alerter.lua
-- @include Animation.lua
-- @include Flash.lua
-- @include Iterator.lua
-- @include Misc.lua
-- @include MovingAverage.lua
-- @include RailWorks.lua
-- @include Scheduler.lua
-- @include Units.lua
local playersched, anysched
local adu
local alerter
local cruise
local power
local blight
local frontpantoanim, rearpantoanim
local tracteffort
local groundflasher
local spark
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
  restrictsignals = {},

  raisefrontpantomsg = nil,
  raiserearpantomsg = nil
}

local messageid = {
  -- ID's must be reused from the DTG engine script so coaches will pass them down.
  raisefrontpanto = 1207,
  raiserearpanto = 1208
}

Initialise = Misc.wraperrors(function()
  playersched = Scheduler:new{}
  anysched = Scheduler:new{}

  adu = AmtrakTwoSpeedAdu:new{
    getbrakesuppression = function() return state.train_brake > 0.3 end,
    getacknowledge = function() return state.acknowledge end,
    getspeed_mps = function() return state.speed_mps end,
    gettrackspeed_mps = function() return state.trackspeed_mps end,
    getconsistlength_m = function() return state.consistlength_m end,
    iterspeedlimits = function() return pairs(state.speedlimits) end,
    iterrestrictsignals = function() return pairs(state.restrictsignals) end,
    consistspeed_mps = 125 * Units.mph.tomps
  }

  alerter = Alerter:new{
    scheduler = playersched,
    getspeed_mps = function() return state.speed_mps end
  }
  alerter:start()

  cruise = Cruise:new{
    scheduler = playersched,
    getspeed_mps = function() return state.speed_mps end,
    gettargetspeed_mps = function() return state.cruisespeed_mps end,
    getenabled = function() return state.cruiseenabled end
  }

  power = PowerSupply:new{
    scheduler = anysched,
    modes = {
      [0] = function(elec)
        local pantoup = frontpantoanim:getposition() == 1 or
                          rearpantoanim:getposition() == 1
        return pantoup and elec:isavailable(Electrification.type.overhead)
      end
    }
  }
  power:setavailable(Electrification.type.overhead, true)

  blight = BrakeLight:new{}

  frontpantoanim = Animation:new{
    scheduler = anysched,
    animation = "frontPanto",
    duration_s = 2
  }
  rearpantoanim = Animation:new{
    scheduler = anysched,
    animation = "rearPanto",
    duration_s = 2
  }

  tracteffort = Average:new{nsamples = 30}

  local groundflash_s = 0.65
  groundflasher = Flash:new{
    scheduler = playersched,
    off_s = groundflash_s,
    on_s = groundflash_s
  }

  spark = PantoSpark:new{scheduler = anysched}

  RailWorks.BeginUpdate()
end)

local function readcontrols()
  local vthrottle
  if RailWorks.ControlExists("NewVirtualThrottle", 0) then
    -- For compatibility with Fan Railer's HHP-8 mod.
    vthrottle = RailWorks.GetControlValue("NewVirtualThrottle", 0)
  else
    vthrottle = RailWorks.GetControlValue("VirtualThrottle", 0)
  end
  local brake = RailWorks.GetControlValue("TrainBrakeControl", 0)
  local change = vthrottle ~= state.throttle or brake ~= state.train_brake
  state.throttle = vthrottle
  state.train_brake = brake
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) > 0
  if state.acknowledge or change then alerter:acknowledge() end

  state.cruisespeed_mps = RailWorks.GetControlValue("SpeedSetControl", 0) * 10 *
                            Units.mph.tomps
  state.cruiseenabled = RailWorks.GetControlValue("CruiseControl", 0) == 1
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

  local throttle
  if not power:haspower() then
    throttle = 0
  elseif penalty then
    throttle = 0
  elseif state.cruiseenabled then
    throttle = math.min(state.throttle, cruise:getthrottle())
  else
    throttle = state.throttle
  end
  RailWorks.SetControlValue("Regulator", 0, throttle)

  -- There's no virtual train brake, so just move the braking handle.
  local penaltybrake = 0.6
  if penalty then
    RailWorks.SetControlValue("TrainBrakeControl", 0, penaltybrake)
  end

  -- DTG's "blended braking" algorithm
  local airbrake = penalty and penaltybrake or state.train_brake
  local dynbrake = state.speed_mps >= 10 * Units.mph.tomps and airbrake * 0.3 or
                     0
  RailWorks.SetControlValue("DynamicBrake", 0, dynbrake)

  RailWorks.SetControlValue("AWSWarnCount", 0, Misc.intbool(adu:isalarm()))
  RailWorks.SetControlValue("SpeedIncreaseAlert", 0,
                            Misc.intbool(adu:isalertplaying()))
end

local function setplayerpantos()
  local pantoup = RailWorks.GetControlValue("PantographControl", 0) == 1
  local pantosel = RailWorks.GetControlValue("SelPanto", 0)

  local frontup = pantoup and pantosel < 1.5
  local rearup = pantoup and pantosel > 0.5
  frontpantoanim:setanimatedstate(frontup)
  rearpantoanim:setanimatedstate(rearup)
  RailWorks.Engine_SendConsistMessage(messageid.raisefrontpanto, frontup, 0)
  RailWorks.Engine_SendConsistMessage(messageid.raisefrontpanto, frontup, 1)
  RailWorks.Engine_SendConsistMessage(messageid.raiserearpanto, rearup, 0)
  RailWorks.Engine_SendConsistMessage(messageid.raiserearpanto, rearup, 1)
end

local function setaipantos()
  local frontup = true
  local rearup = false
  frontpantoanim:setanimatedstate(frontup)
  rearpantoanim:setanimatedstate(rearup)
  RailWorks.Engine_SendConsistMessage(messageid.raisefrontpanto, frontup, 0)
  RailWorks.Engine_SendConsistMessage(messageid.raisefrontpanto, frontup, 1)
  RailWorks.Engine_SendConsistMessage(messageid.raiserearpanto, rearup, 0)
  RailWorks.Engine_SendConsistMessage(messageid.raiserearpanto, rearup, 1)
end

local function setslavepantos()
  if state.raisefrontpantomsg ~= nil then
    frontpantoanim:setanimatedstate(state.raisefrontpantomsg)
  end
  if state.raiserearpantomsg ~= nil then
    rearpantoanim:setanimatedstate(state.raiserearpantomsg)
  end
end

local function setpantosparks()
  local frontcontact = frontpantoanim:getposition() == 1
  local rearcontact = rearpantoanim:getposition() == 1
  local isspark = spark:isspark()

  RailWorks.ActivateNode("front_spark01", frontcontact and isspark)
  RailWorks.ActivateNode("front_spark02", frontcontact and isspark)
  Call("Spark:Activate", Misc.intbool(frontcontact and isspark))

  RailWorks.ActivateNode("rear_spark01", rearcontact and isspark)
  RailWorks.ActivateNode("rear_spark02", rearcontact and isspark)
  Call("Spark2:Activate", Misc.intbool(rearcontact and isspark))
end

local function setstatusscreen()
  RailWorks.SetControlValue("ControlScreenIzq", 0,
                            Misc.intbool(not power:haspower()))

  local frontpantoup = frontpantoanim:getposition() == 1
  local rearpantoup = rearpantoanim:getposition() == 1
  local panto
  if not frontpantoup and not rearpantoup then
    panto = -1
  elseif not frontpantoup and rearpantoup then
    panto = 2
  elseif frontpantoup and not rearpantoup then
    panto = 0
  elseif frontpantoup and rearpantoup then
    panto = 1
  end
  RailWorks.SetControlValue("PantoIndicator", 0, panto)

  local lights
  local headlights = RailWorks.GetControlValue("Headlights", 0)
  if headlights == 1 then
    local groundlights = RailWorks.GetControlValue("GroundLights", 0)
    if groundlights == 1 then
      lights = 1
    elseif groundlights == 2 then
      lights = 2
    else
      lights = 0
    end
  else
    lights = -1
  end
  RailWorks.SetControlValue("SelectLights", 0, lights)

  tracteffort:sample(RailWorks.GetTractiveEffort() * 71)
  RailWorks.SetControlValue("Effort", 0, tracteffort:get())
end

local function setdrivescreen()
  RailWorks.SetControlValue("ControlScreenDer", 0,
                            Misc.intbool(not power:haspower()))

  local speed_mph = Misc.round(state.speed_mps * Units.mps.tomph)
  RailWorks.SetControlValue("SPHundreds", 0, Misc.getdigit(speed_mph, 2))
  RailWorks.SetControlValue("SPTens", 0, Misc.getdigit(speed_mph, 1))
  RailWorks.SetControlValue("SPUnits", 0, Misc.getdigit(speed_mph, 0))
  RailWorks.SetControlValue("SpeedoGuide", 0, Misc.getdigitguide(speed_mph))

  local pstate = state.cruiseenabled and 8 or
                   math.floor(state.throttle * 6 + 0.5)
  RailWorks.SetControlValue("PowerState", 0, pstate)
end

local function setcutin()
  if not playersched:isstartup() then
    adu:setatcstate(RailWorks.GetControlValue("ATCCutIn", 0) == 1)
    adu:setacsesstate(RailWorks.GetControlValue("ACSESCutIn", 0) == 1)
  end
end

local function setadu()
  local aspect = adu:getaspect()
  local g, y, r, lg, lw
  if aspect == AmtrakTwoSpeedAdu.aspect.stop then
    g, y, r, lg, lw = 0, 0, 1, 0, 0
  elseif aspect == AmtrakTwoSpeedAdu.aspect.restrict then
    g, y, r, lg, lw = 0, 0, 1, 0, 1
  elseif aspect == AmtrakTwoSpeedAdu.aspect.approach then
    g, y, r, lg, lw = 0, 1, 0, 0, 0
  elseif aspect == AmtrakTwoSpeedAdu.aspect.approachmed then
    g, y, r, lg, lw = 0, 1, 0, 1, 0
  elseif aspect == AmtrakTwoSpeedAdu.aspect.cabspeed then
    g, y, r, lg, lw = 1, 0, 0, 0, 0
  elseif aspect == AmtrakTwoSpeedAdu.aspect.cabspeedoff then
    g, y, r, lg, lw = 0, 0, 0, 0, 0
  elseif aspect == AmtrakTwoSpeedAdu.aspect.clear then
    g, y, r, lg, lw = 1, 0, 0, 0, 0
  end
  RailWorks.SetControlValue("SigGreen", 0, g)
  RailWorks.SetControlValue("SigYellow", 0, y)
  RailWorks.SetControlValue("SigRed", 0, r)
  RailWorks.SetControlValue("SigLowerGreen", 0, lg)
  RailWorks.SetControlValue("SigLowerGrey", 0, lw)

  local signalspeed_mph = adu:getsignalspeed_mph()
  if signalspeed_mph == nil then
    RailWorks.SetControlValue("CabSpeed", 0, 0) -- blank
  else
    RailWorks.SetControlValue("CabSpeed", 0, signalspeed_mph)
  end

  local civilspeed_mph = adu:getcivilspeed_mph()
  if civilspeed_mph == nil then
    RailWorks.SetControlValue("TSHundreds", 0, -1)
    RailWorks.SetControlValue("TSTens", 0, -1)
    RailWorks.SetControlValue("TSUnits", 0, -1)
  else
    RailWorks.SetControlValue("TSHundreds", 0, Misc.getdigit(civilspeed_mph, 2))
    RailWorks.SetControlValue("TSTens", 0, Misc.getdigit(civilspeed_mph, 1))
    RailWorks.SetControlValue("TSUnits", 0, Misc.getdigit(civilspeed_mph, 0))
  end

  RailWorks.SetControlValue("MinimumSpeed", 0, adu:getsquareindicator())
end

local function setcablight()
  local on = RailWorks.GetControlValue("CabLight", 0)
  Call("CabLight:Activate", on)
end

local function setgroundlights()
  local headlights = RailWorks.GetControlValue("Headlights", 0)
  local groundlights = RailWorks.GetControlValue("GroundLights", 0)
  local fixed = headlights == 1 and groundlights == 1
  local flash = headlights == 1 and groundlights == 2
  groundflasher:setflashstate(flash)
  local flashleft = groundflasher:ison()

  local showleft = fixed or (flash and flashleft)
  RailWorks.ActivateNode("ditch_fwd_l", showleft)
  Call("Fwd_DitchLightLeft:Activate", Misc.intbool(showleft))

  local showright = fixed or (flash and not flashleft)
  RailWorks.ActivateNode("ditch_fwd_r", showright)
  Call("Fwd_DitchLightRight:Activate", Misc.intbool(showright))

  RailWorks.ActivateNode("ditch_bwd_l", false)
  RailWorks.ActivateNode("ditch_bwd_r", false)
  Call("Bwd_DitchLightLeft:Activate", Misc.intbool(false))
  Call("Bwd_DitchLightRight:Activate", Misc.intbool(false))
end

local function updateplayer(dt)
  readcontrols()
  readlocostate()

  playersched:update()
  anysched:update()
  adu:update(dt)
  power:update()
  blight:playerupdate()
  frontpantoanim:update()
  rearpantoanim:update()

  writelocostate()
  setplayerpantos()
  setpantosparks()
  setstatusscreen()
  setdrivescreen()
  setcutin()
  setadu()
  setcablight()
  setgroundlights()
end

local function updateai()
  anysched:update()
  frontpantoanim:update()
  rearpantoanim:update()

  setaipantos()
  setpantosparks()
  setcablight()
  setgroundlights()
end

local function updatehelper()
  anysched:update()
  frontpantoanim:update()
  rearpantoanim:update()

  setslavepantos()
  setpantosparks()
  setcablight()
  setgroundlights()
end

Update = Misc.wraperrors(function(dt)
  -- -> [helper][coach]...[coach][player] ->
  -- -> [ai    ][coach]...[coach][ai    ] ->
  if RailWorks.GetIsEngineWithKey() then
    updateplayer(dt)
  elseif RailWorks.GetIsPlayer() then
    updatehelper()
  else
    updateai()
  end
end)

OnControlValueChange = Misc.wraperrors(function(name, index, value)
  -- Fix Xbox and Raildriver controls for Fan Railer's mod.
  if name == "VirtualThrottle" and
    RailWorks.ControlExists("NewVirtualThrottle", 0) then
    RailWorks.SetControlValue("NewVirtualThrottle", 0, value)
  end

  RailWorks.SetControlValue(name, index, value)
end)

OnCustomSignalMessage = Misc.wraperrors(function(message)
  power:receivemessage(message)
  adu:receivemessage(message)
end)

OnConsistMessage = Misc.wraperrors(function(message, argument, direction)
  blight:receivemessage(message, argument, direction)

  if message == messageid.raisefrontpanto then
    state.raisefrontpantomsg = argument == "true"
  elseif message == messageid.raiserearpanto then
    state.raiserearpantomsg = argument == "true"
  end

  RailWorks.Engine_SendConsistMessage(message, argument, direction)
end)
