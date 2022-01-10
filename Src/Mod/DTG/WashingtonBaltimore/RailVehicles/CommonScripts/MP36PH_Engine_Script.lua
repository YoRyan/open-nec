-- Engine script for the MPI MP36PH operated by MARC.
--
-- @include RollingStock/BrakeLight.lua
-- @include RollingStock/Hep.lua
-- @include SafetySystems/AspectDisplay/AmtrakTwoSpeed.lua
-- @include SafetySystems/Alerter.lua
-- @include Flash.lua
-- @include Iterator.lua
-- @include Misc.lua
-- @include RailWorks.lua
-- @include Units.lua
local adu
local alerter
local hep
local blight
local ditchflasher

Initialise = Misc.wraperrors(function()
  adu = AmtrakTwoSpeedAdu:new{
    getbrakesuppression = function()
      return RailWorks.GetControlValue("VirtualBrake", 0) >= 0.6
    end,
    getacknowledge = function()
      return RailWorks.GetControlValue("AWSReset", 0) > 0
    end,
    consistspeed_mps = 100 * Units.mph.tomps
  }

  alerter = Alerter:new{
    getacknowledge = function()
      return RailWorks.GetControlValue("AWSReset", 0) > 0
    end
  }
  alerter:start()

  hep = Hep:new{
    getrun = function() return RailWorks.GetControlValue("HEP", 0) == 1 end
  }

  blight = BrakeLight:new{}

  local ditchflash_s = 1
  ditchflasher = Flash:new{off_s = ditchflash_s, on_s = ditchflash_s}

  RailWorks.BeginUpdate()
end)

local function writelocostate()
  local penalty = alerter:ispenalty() or adu:ispenalty()

  local throttle, dynbrake
  if penalty then
    throttle, dynbrake = 0, 0
  else
    local controller = RailWorks.GetControlValue("ThrottleAndBrake", 0)
    throttle = math.max(controller, 0)
    dynbrake = math.max(-controller, 0)
  end
  RailWorks.SetControlValue("Regulator", 0, throttle)
  RailWorks.SetControlValue("DynamicBrake", 0, dynbrake)

  local airbrake = penalty and 0.85 or
                     RailWorks.GetControlValue("VirtualBrake", 0)
  RailWorks.SetControlValue("TrainBrakeControl", 0, airbrake)

  RailWorks.SetControlValue("EngineBrakeControl", 0, RailWorks.GetControlValue(
                              "VirtualEngineBrakeControl", 0))
  RailWorks.SetControlValue("HEP_State", 0, Misc.intbool(hep:haspower()))

  local alert = adu:isalertplaying()
  local alarm = adu:isalarm() or alerter:isalarm()
  RailWorks.SetControlValue("TMS", 0, Misc.intbool(alert or alarm))
  RailWorks.SetControlValue("AWSWarnCount", 0, Misc.intbool(alarm))
end

local function setspeedometer()
  local speed_mph = Misc.round(RailWorks.GetControlValue("SpeedometerMPH", 0))
  RailWorks.SetControlValue("SpeedoDots", 0, math.floor(speed_mph / 2))
  RailWorks.SetControlValue("SpeedoHundreds", 0, Misc.getdigit(speed_mph, 2))
  RailWorks.SetControlValue("SpeedoTens", 0, Misc.getdigit(speed_mph, 1))
  RailWorks.SetControlValue("SpeedoUnits", 0, Misc.getdigit(speed_mph, 0))
end

local function setcutin()
  -- Reverse the polarities so that safety systems are on by default.
  local atcon = RailWorks.GetControlValue("ATCCutIn", 0) == 0
  local acseson = RailWorks.GetControlValue("ACSESCutIn", 0) == 0
  adu:setatcstate(atcon)
  adu:setacsesstate(acseson)
  alerter:setrunstate(atcon or acseson)
end

local function setadu()
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

  if Misc.isinitialized() then -- Stop the digits from flashing.
    local signalspeed_mph = adu:getsignalspeed_mph()
    if signalspeed_mph == nil then
      RailWorks.SetControlValue("SignalSpeed", 0, 0) -- blank
    else
      RailWorks.SetControlValue("SignalSpeed", 0, signalspeed_mph)
    end
  end

  local civilspeed_mph = adu:getcivilspeed_mph()
  if civilspeed_mph == nil then
    RailWorks.SetControlValue("TSHundreds", 0, 0)
    RailWorks.SetControlValue("TSTens", 0, 0)
    RailWorks.SetControlValue("TSUnits", 0, -1)
  else
    RailWorks.SetControlValue("TSHundreds", 0, Misc.getdigit(civilspeed_mph, 2))
    RailWorks.SetControlValue("TSTens", 0, Misc.getdigit(civilspeed_mph, 1))
    RailWorks.SetControlValue("TSUnits", 0, Misc.getdigit(civilspeed_mph, 0))
  end

  RailWorks.SetControlValue("MaximumSpeedLimitIndicator", 0,
                            adu:getsquareindicator())
end

local function setcablight()
  Call("Cablight:Activate", RailWorks.GetControlValue("CabLight", 0))
end

local function setheadlight()
  local headlights = RailWorks.GetControlValue("Headlights", 0)
  local isdim = headlights >= 0.44 and headlights < 1.49 and headlights ~= 1
  local isbright = headlights >= 1.49 or headlights == 1
  Call("Headlight_01_Dim:Activate", Misc.intbool(isdim or isbright))
  Call("Headlight_02_Dim:Activate", Misc.intbool(isdim or isbright))
  Call("Headlight_01_Bright:Activate", Misc.intbool(isbright))
  Call("Headlight_02_Bright:Activate", Misc.intbool(isbright))
end

local function setditchlights()
  local headlights = RailWorks.GetControlValue("Headlights", 0)
  local pulselights = RailWorks.GetControlValue("DitchLights", 0)
  local flash = pulselights == 1
  local fixed = headlights == 3 and not flash
  ditchflasher:setflashstate(flash)
  local flashleft = ditchflasher:ison()

  local showleft = fixed or (flash and flashleft)
  RailWorks.ActivateNode("ditch_left", showleft)
  Call("Ditch_L:Activate", Misc.intbool(showleft))

  local showright = fixed or (flash and not flashleft)
  RailWorks.ActivateNode("ditch_right", showright)
  Call("Ditch_R:Activate", Misc.intbool(showright))

  RailWorks.ActivateNode("lights_dim", fixed or flash)
end

local function setrearlight()
  local rearlights = RailWorks.GetControlValue("Rearlights", 0)
  local isdim = rearlights >= 1 and rearlights < 2
  local isbright = rearlights == 2
  Call("Rearlight_01_Dim:Activate", Misc.intbool(isdim or isbright))
  Call("Rearlight_02_Dim:Activate", Misc.intbool(isdim or isbright))
  Call("Rearlight_01_Bright:Activate", Misc.intbool(isbright))
  Call("Rearlight_02_Bright:Activate", Misc.intbool(isbright))
end

local function updateplayer(dt)
  adu:update(dt)
  alerter:update(dt)
  hep:update(dt)
  blight:playerupdate(dt)

  writelocostate()
  setspeedometer()
  setcutin()
  setadu()
  setcablight()
  setheadlight()
  setditchlights()
  setrearlight()
end

local function updatenonplayer()
  setcablight()
  setheadlight()
  setditchlights()
  setrearlight()
end

Update = Misc.wraperrors(function(dt)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer(dt)
  else
    updatenonplayer()
    RailWorks.EndUpdate()
    return
  end
end)

OnControlValueChange = Misc.wraperrors(function(name, index, value)
  if name == "HEP" then
    if value == 0 then
      RailWorks.SetControlValue("HEP_Off", 0, 1)
    elseif value == 1 then
      RailWorks.SetControlValue("HEP_Off", 0, 0)
    end
  elseif name == "HEP_Off" then
    if value == 0 then
      RailWorks.SetControlValue("HEP", 0, 1)
    elseif value == 1 then
      RailWorks.SetControlValue("HEP", 0, 0)
    end
  end

  if name == "ThrottleAndBrake" or name == "VirtualBrake" then
    alerter:acknowledge()
  end

  RailWorks.SetControlValue(name, index, value)
end)

OnCustomSignalMessage = Misc.wraperrors(function(message)
  adu:receivemessage(message)
end)

OnConsistMessage = Misc.wraperrors(function(message, argument, direction)
  blight:receivemessage(message, argument, direction)

  RailWorks.Engine_SendConsistMessage(message, argument, direction)
end)

