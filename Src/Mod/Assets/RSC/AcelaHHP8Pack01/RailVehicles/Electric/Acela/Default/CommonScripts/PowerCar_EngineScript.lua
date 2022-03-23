-- Engine script for the Bombardier HHP-8 operated by Amtrak.
--
-- @include YoRyan/LibRailWorks/RollingStock/PowerSupply/Electrification.lua
-- @include YoRyan/LibRailWorks/RollingStock/PowerSupply/PowerSupply.lua
-- @include YoRyan/LibRailWorks/RollingStock/BrakeLight.lua
-- @include YoRyan/LibRailWorks/RollingStock/CruiseControl.lua
-- @include YoRyan/LibRailWorks/RollingStock/Spark.lua
-- @include SafetySystems/AspectDisplay/AmtrakTwoSpeed.lua
-- @include SafetySystems/Alerter.lua
-- @include YoRyan/LibRailWorks/Animation.lua
-- @include YoRyan/LibRailWorks/Flash.lua
-- @include YoRyan/LibRailWorks/Iterator.lua
-- @include YoRyan/LibRailWorks/Misc.lua
-- @include YoRyan/LibRailWorks/MovingAverage.lua
-- @include YoRyan/LibRailWorks/RailWorks.lua
-- @include YoRyan/LibRailWorks/Units.lua
local adu
local alerter
local cruise
local power
local blight
local frontpantoanim, rearpantoanim
local tracteffort
local groundflasher
local spark

local raisefrontpantomsg = nil
local raiserearpantomsg = nil

local messageid = {
  -- ID's must be reused from the DTG engine script so coaches will pass them down.
  raisefrontpanto = 1207,
  raiserearpanto = 1208
}

local function getplayerthrottle()
  -- For compatibility with Fan Railer's HHP-8 mod.
  local isfanrailer = RailWorks.ControlExists("NewVirtualThrottle", 0)
  return RailWorks.GetControlValue(isfanrailer and "NewVirtualThrottle" or
                                     "VirtualThrottle", 0)
end

Initialise = Misc.wraperrors(function()
  adu = AmtrakTwoSpeedAdu:new{
    getbrakesuppression = function()
      return RailWorks.GetControlValue("TrainBrakeControl", 0) > 0.3
    end,
    getacknowledge = function()
      return RailWorks.GetControlValue("AWSReset", 0) > 0
    end,
    consistspeed_mps = 125 * Units.mph.tomps
  }

  alerter = Alerter:new{
    getacknowledge = function()
      return RailWorks.GetControlValue("AWSReset", 0) > 0
    end
  }
  alerter:start()

  cruise = Cruise:new{
    getplayerthrottle = getplayerthrottle,
    gettargetspeed_mps = function()
      return RailWorks.GetControlValue("SpeedSetControl", 0) * 10 *
               Units.mph.tomps
    end,
    getenabled = function()
      return RailWorks.GetControlValue("CruiseControl", 0) == 1
    end
  }

  power = PowerSupply:new{
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

  frontpantoanim = Animation:new{animation = "frontPanto", duration_s = 2}
  rearpantoanim = Animation:new{animation = "rearPanto", duration_s = 2}

  tracteffort = Average:new{nsamples = 30}

  local groundflash_s = 0.65
  groundflasher = Flash:new{off_s = groundflash_s, on_s = groundflash_s}

  spark = PantoSpark:new{}

  RailWorks.BeginUpdate()
end)

local function setplayercontrols()
  local penalty = alerter:ispenalty() or adu:ispenalty()

  local throttle
  if not power:haspower() then
    throttle = 0
  elseif penalty then
    throttle = 0
  else
    throttle = cruise:getpower()
  end
  RailWorks.SetControlValue("Regulator", 0, throttle)

  -- There's no virtual train brake, so just move the braking handle.
  local penaltybrake = 0.6
  if penalty then
    RailWorks.SetControlValue("TrainBrakeControl", 0, penaltybrake)
  end

  -- DTG's "blended braking" algorithm
  local speed_mph = RailWorks.GetControlValue("SpeedometerMPH", 0)
  local airbrake = penalty and penaltybrake or
                     RailWorks.GetControlValue("TrainBrakeControl", 0)
  local dynbrake = speed_mph >= 10 and airbrake * 0.3 or 0
  RailWorks.SetControlValue("DynamicBrake", 0, dynbrake)

  RailWorks.SetControlValue("AWSWarnCount", 0,
                            Misc.intbool(alerter:isalarm() or adu:isalarm()))
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
  if raisefrontpantomsg ~= nil then
    frontpantoanim:setanimatedstate(raisefrontpantomsg)
  end
  if raiserearpantomsg ~= nil then
    rearpantoanim:setanimatedstate(raiserearpantomsg)
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

  local speed_mph = Misc.round(RailWorks.GetControlValue("SpeedometerMPH", 0))
  RailWorks.SetControlValue("SPHundreds", 0, Misc.getdigit(speed_mph, 2))
  RailWorks.SetControlValue("SPTens", 0, Misc.getdigit(speed_mph, 1))
  RailWorks.SetControlValue("SPUnits", 0, Misc.getdigit(speed_mph, 0))
  RailWorks.SetControlValue("SpeedoGuide", 0, Misc.getdigitguide(speed_mph))

  local cruiseon = RailWorks.GetControlValue("CruiseControl", 0) == 1
  local pstate = cruiseon and 8 or math.floor(getplayerthrottle() * 6 + 0.5)
  RailWorks.SetControlValue("PowerState", 0, pstate)
end

local function setcutin()
  if Misc.isinitialized() then
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
  adu:update(dt)
  alerter:update(dt)
  cruise:update(dt)
  power:update(dt)
  blight:playerupdate(dt)
  frontpantoanim:update(dt)
  rearpantoanim:update(dt)

  setplayercontrols()
  setplayerpantos()
  setpantosparks()
  setstatusscreen()
  setdrivescreen()
  setcutin()
  setadu()
  setcablight()
  setgroundlights()
end

local function updatehelper(dt)
  frontpantoanim:update(dt)
  rearpantoanim:update(dt)

  setslavepantos()
  setpantosparks()
  setcablight()
  setgroundlights()
end

local function updateai(dt)
  frontpantoanim:update(dt)
  rearpantoanim:update(dt)

  setaipantos()
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
    updatehelper(dt)
  else
    updateai(dt)
  end
end)

OnControlValueChange = Misc.wraperrors(function(name, index, value)
  -- Fix Xbox and Raildriver controls for Fan Railer's mod.
  if name == "VirtualThrottle" and
    RailWorks.ControlExists("NewVirtualThrottle", 0) then
    RailWorks.SetControlValue("NewVirtualThrottle", 0, value)
  end

  if name == "NewVirtualThrottle" or name == "VirtualThrottle" or name ==
    "TrainBrakeControl" then alerter:acknowledge() end

  RailWorks.SetControlValue(name, index, value)
end)

OnCustomSignalMessage = Misc.wraperrors(function(message)
  power:receivemessage(message)
  adu:receivemessage(message)
end)

OnConsistMessage = Misc.wraperrors(function(message, argument, direction)
  blight:receivemessage(message, argument, direction)

  if message == messageid.raisefrontpanto then
    raisefrontpantomsg = argument == "true"
  elseif message == messageid.raiserearpanto then
    raiserearpantomsg = argument == "true"
  end

  RailWorks.Engine_SendConsistMessage(message, argument, direction)
end)
