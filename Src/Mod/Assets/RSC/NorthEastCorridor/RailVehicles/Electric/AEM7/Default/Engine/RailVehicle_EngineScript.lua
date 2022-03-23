-- Engine script for the EMD AEM-7 operated by Amtrak.
--
-- @include RollingStock/PowerSupply/Electrification.lua
-- @include RollingStock/PowerSupply/PowerSupply.lua
-- @include RollingStock/BrakeLight.lua
-- @include RollingStock/CruiseControl.lua
-- @include SafetySystems/AspectDisplay/AmtrakTwoSpeed.lua
-- @include SafetySystems/Alerter.lua
-- @include Flash.lua
-- @include Iterator.lua
-- @include Misc.lua
-- @include RailWorks.lua
-- @include Units.lua
local adu
local cruise
local alerter
local power
local blight

Initialise = Misc.wraperrors(function()
  local onebeep_s = 0.3
  adu = AmtrakTwoSpeedAdu:new{
    alerttone_s = onebeep_s,
    getbrakesuppression = function()
      return RailWorks.GetControlValue("VirtualBrake", 0) >= 0.5
    end,
    getacknowledge = function()
      return RailWorks.GetControlValue("AWSReset", 0) > 0
    end,
    consistspeed_mps = 125 * Units.mph.tomps
  }

  cruise = Cruise:new{
    getplayerthrottle = function()
      return RailWorks.GetControlValue("VirtualThrottle", 0)
    end,
    gettargetspeed_mps = function()
      return RailWorks.GetControlValue("CruiseSet", 0) * Units.mph.tomps
    end,
    getenabled = function()
      return RailWorks.GetControlValue("CruiseSet", 0) > 10
    end
  }

  alerter = Alerter:new{
    getacknowledge = function()
      return RailWorks.GetControlValue("AWSReset", 0) > 0
    end
  }
  alerter:start()

  power = PowerSupply:new{
    modes = {
      [0] = function(elec)
        local pantoup = RailWorks.GetControlValue("PantographControl", 0) == 1
        return pantoup and elec:isavailable(Electrification.type.overhead)
      end
    }
  }
  power:setavailable(Electrification.type.overhead, true)

  blight = BrakeLight:new{}

  RailWorks.BeginUpdate()
end)

local function setplayercontrols()
  local penalty = alerter:ispenalty() or adu:ispenalty()

  local nopower = penalty or not power:haspower()
  RailWorks.SetControlValue("Regulator", 0, nopower and 0 or cruise:getpower())

  local airbrake
  if RailWorks.GetControlValue("CutIn", 0) < 1 then
    airbrake = 1
  elseif penalty then
    airbrake = 0.99
  else
    airbrake = RailWorks.GetControlValue("VirtualBrake", 0)
  end
  RailWorks.SetControlValue("TrainBrakeControl", 0, airbrake)

  -- DTG's "blended braking" algorithm
  local dynbrake = penalty and 0.5 or
                     RailWorks.GetControlValue("VirtualBrake", 0) / 2
  RailWorks.SetControlValue("DynamicBrake", 0, dynbrake)

  -- Used for the dynamic brake sound?
  RailWorks.SetControlValue("DynamicCurrent", 0,
                            math.abs(RailWorks.GetControlValue("Ammeter", 0)))

  local alerteralarm = alerter:isalarm()
  local safetyalarm = adu:isalarm()
  RailWorks.SetControlValue("AWS", 0, Misc.intbool(alerteralarm or safetyalarm))
  RailWorks.SetControlValue("AWSWarnCount", 0, Misc.intbool(alerteralarm))
  RailWorks.SetControlValue("OverSpeedAlert", 0,
                            Misc.intbool(adu:isalertplaying() or safetyalarm))
end

local function setadu()
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

  local trackspeed_mph = adu:getcivilspeed_mph()
  if trackspeed_mph == nil then
    RailWorks.SetControlValue("TrackSpeed", 0, 14.5) -- blank
  else
    RailWorks.SetControlValue("TrackSpeed", 0, trackspeed_mph)
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
  adu:setatcstate(speedcontrol)
  adu:setacsesstate(speedcontrol)
end

Update = Misc.wraperrors(function(dt)
  if not RailWorks.GetIsEngineWithKey() then
    RailWorks.EndUpdate()
    return
  end

  adu:update(dt)
  cruise:update(dt)
  alerter:update(dt)
  power:update(dt)
  blight:playerupdate(dt)

  setplayercontrols()
  setadu()
  setcablight()
  setcutin()
end)

OnControlValueChange = Misc.wraperrors(function(name, index, value)
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

  RailWorks.Engine_SendConsistMessage(message, argument, direction)
end)
