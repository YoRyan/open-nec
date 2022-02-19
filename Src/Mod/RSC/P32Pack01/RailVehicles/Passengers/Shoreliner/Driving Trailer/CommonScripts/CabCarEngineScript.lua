-- Engine script for the Shoreliner operated by Metro-North.
--
-- @include RollingStock/PowerSupply/Electrification.lua
-- @include RollingStock/PowerSupply/PowerSupply.lua
-- @include RollingStock/AiDirection.lua
-- @include RollingStock/BrakeLight.lua
-- @include SafetySystems/AspectDisplay/MetroNorth.lua
-- @include SafetySystems/Alerter.lua
-- @include Animation.lua
-- @include Misc.lua
-- @include RailWorks.lua
-- @include Units.lua
local adu
local alerter
local blight
local power
local aidirection
local leftwindowanim, rightwindowanim

-- Note that these are reversed compared to the P32.
local powermode = {diesel = 0, thirdrail = 1}
local messageid = {locationprobe = 10110}

Initialise = Misc.wraperrors(function()
  adu = MetroNorthAdu:new{
    getbrakesuppression = function()
      return RailWorks.GetControlValue("TrainBrakeControl", 0) >= 0.4
    end,
    getacknowledge = function()
      return RailWorks.GetControlValue("AWSReset", 0) > 0
    end,
    consistspeed_mps = 80 * Units.mph.tomps
  }

  alerter = Alerter:new{
    getacknowledge = function()
      return RailWorks.GetControlValue("AWSReset", 0) > 0
    end
  }
  alerter:start()

  blight = BrakeLight:new{}

  power = PowerSupply:new{
    modecontrol = "PowerMode",
    transition_s = 20,
    getcantransition = function() return true end,
    modes = {
      [powermode.diesel] = function(elec) return true end,
      [powermode.thirdrail] = function(elec) return true end
    },
    getautomode = function(cp)
      if cp == Electrification.autochangepoint.ai_to_thirdrail then
        return powermode.thirdrail
      elseif cp == Electrification.autochangepoint.ai_to_diesel then
        return powermode.diesel
      else
        return nil
      end
    end,
    oninit = function()
      local iselectric = power:getmode() == powermode.thirdrail
      power:setavailable(Electrification.type.thirdrail, iselectric)
    end
  }

  aidirection = AiDirection:new{}

  local doors_s = 2
  leftwindowanim = Animation:new{animation = "LeftWindow", duration_s = doors_s}
  rightwindowanim = Animation:new{
    animation = "RightWindow",
    duration_s = doors_s
  }

  RailWorks.BeginUpdate()
end)

local function setplayercontrols()
  local penalty = alerter:ispenalty() or adu:ispenalty()

  local throttle = penalty and 0 or
                     RailWorks.GetControlValue("VirtualThrottle", 0)
  RailWorks.SetControlValue("Regulator", 0, throttle)

  -- There's no virtual train brake, so just move the braking handle.
  if penalty then RailWorks.SetControlValue("TrainBrakeControl", 0, 0.6) end

  local alarm = alerter:isalarm() or adu:isalarm()
  RailWorks.SetControlValue("AWS", 0, Misc.intbool(alarm))
  RailWorks.SetControlValue("AWSWarnCount", 0, Misc.intbool(alarm))
  local alert = adu:isalertplaying()
  RailWorks.SetControlValue("SpeedIncreaseAlert", 0, Misc.intbool(alert))

  -- Match DTG's blended braking "algorithm."
  local pipepress_psi = 70 -
                          RailWorks.GetControlValue("AirBrakePipePressurePSI", 0)
  local dynbrake = math.max(pipepress_psi * 0.01428, 0)
  RailWorks.SetControlValue("DynamicBrake", 0, dynbrake)
end

local function setspeedometer()
  local speed_mph = RailWorks.GetControlValue("SpeedometerMPH", 0)
  RailWorks.SetControlValue("SpeedoHundreds", 0, Misc.getdigit(speed_mph, 2))
  RailWorks.SetControlValue("SpeedoTens", 0, Misc.getdigit(speed_mph, 1))
  RailWorks.SetControlValue("SpeedoUnits", 0, Misc.getdigit(speed_mph, 0))

  local aspect = adu:getaspect()
  local n, l, m, r
  if aspect == MetroNorthAdu.aspect.restrict then
    n, l, m, r = 0, 0, 0, 1
  elseif aspect == MetroNorthAdu.aspect.medium then
    n, l, m, r = 0, 0, 1, 0
  elseif aspect == MetroNorthAdu.aspect.limited then
    n, l, m, r = 0, 1, 0, 0
  elseif aspect == MetroNorthAdu.aspect.normal then
    n, l, m, r = 1, 0, 0, 0
  end
  RailWorks.SetControlValue("SigN", 0, n)
  RailWorks.SetControlValue("SigL", 0, l)
  RailWorks.SetControlValue("SigM", 0, m)
  RailWorks.SetControlValue("SigR", 0, r)
end

local function setcutin()
  adu:setatcstate(RailWorks.GetControlValue("ATCCutIn", 0) == 1)
  alerter:setrunstate(RailWorks.GetControlValue("ACSESCutIn", 0) == 1)
  adu:setacsesstate(false)
end

local function setcabwindows()
  RailWorks.SetTime("LeftWindow",
                    RailWorks.GetControlValue("Window Left", 0) * 2)
  RailWorks.SetTime("RightWindow",
                    RailWorks.GetControlValue("Window Right", 0) * 2)
end

local function setplayerlights()
  local headlights = RailWorks.GetControlValue("Headlights", 0)
  local showditch = headlights > 0.5 and headlights < 1.5
  RailWorks.ActivateNode("ditch_left", showditch)
  RailWorks.ActivateNode("ditch_right", showditch)

  RailWorks.ActivateNode("brakelight", blight:isapplied())

  Call("CabLight:Activate", RailWorks.GetControlValue("CabLight", 0))
end

local function sethelperlights()
  local headlights = RailWorks.GetControlValue("Headlights", 0)
  local isend = not RailWorks.Engine_SendConsistMessage(messageid.locationprobe,
                                                        "", 0)
  local showditch = headlights > 1.5 and isend
  RailWorks.ActivateNode("ditch_left", showditch)
  RailWorks.ActivateNode("ditch_right", showditch)

  RailWorks.ActivateNode("brakelight", blight:isapplied())

  Call("CabLight:Activate", RailWorks.GetControlValue("CabLight", 0))
end

local function setailights()
  local isend = not RailWorks.Engine_SendConsistMessage(messageid.locationprobe,
                                                        "", 0)
  local showditch = isend and aidirection:getdirection() ==
                      AiDirection.direction.forward
  RailWorks.ActivateNode("ditch_left", showditch)
  RailWorks.ActivateNode("ditch_right", showditch)

  local aspeed_mps = math.abs(RailWorks.GetSpeed())
  local isslow = aspeed_mps < 20 * Units.mph.tomps
  RailWorks.ActivateNode("brakelight", isslow)

  Call("CabLight:Activate", 0)
end

local function updateplayer(dt)
  adu:update(dt)
  alerter:update(dt)
  blight:playerupdate(dt)
  power:update(dt)
  leftwindowanim:update(dt)
  rightwindowanim:update(dt)

  setplayercontrols()
  setspeedometer()
  setcutin()
  setcabwindows()
  setplayerlights()
end

local function updatehelper(dt)
  power:update(dt)
  leftwindowanim:update(dt)
  rightwindowanim:update(dt)

  setcabwindows()
  sethelperlights()
end

local function updateai(dt)
  power:update(dt)
  aidirection:aiupdate(dt)
  leftwindowanim:update(dt)
  rightwindowanim:update(dt)

  setcabwindows()
  setailights()
end

Update = Misc.wraperrors(function(dt)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer(dt)
  elseif RailWorks.GetIsPlayer() then
    updatehelper(dt)
  else
    updateai(dt)
  end
end)

OnControlValueChange = Misc.wraperrors(function(name, index, value)
  if name == "ExpertPowerMode" and RailWorks.GetIsEngineWithKey() and
    Misc.isinitialized() and (value == 0 or value == 1) then
    Misc.showalert("Not available in OpenNEC")
  end

  if name == "VirtualThrottle" or name == "TrainBrakeControl" then
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
