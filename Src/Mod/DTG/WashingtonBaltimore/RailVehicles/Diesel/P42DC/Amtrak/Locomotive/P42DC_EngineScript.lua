-- Engine script for the P42DC operated by Amtrak.
--
-- @include RollingStock/BrakeLight.lua
-- @include SafetySystems/AspectDisplay/Genesis.lua
-- @include SafetySystems/Alerter.lua
-- @include Flash.lua
-- @include Iterator.lua
-- @include Misc.lua
-- @include RailWorks.lua
-- @include Units.lua
local adu
local alerter
local blight
local ditchflasher

local lasthorntime_s = nil
local lastthrottletime_s = nil

local function setenginenumber()
  local number = tonumber(RailWorks.GetRVNumber()) or 0
  RailWorks.SetControlValue("LocoHundreds", 0, Misc.getdigit(number, 2))
  RailWorks.SetControlValue("LocoTens", 0, Misc.getdigit(number, 1))
  RailWorks.SetControlValue("LocoUnits", 0, Misc.getdigit(number, 0))
end

Initialise = Misc.wraperrors(function()
  setenginenumber()

  local onebeep_s = 0.25
  adu = GenesisAdu:new{
    isamtrak = true,
    alerttone_s = onebeep_s,
    getbrakesuppression = function()
      return RailWorks.GetControlValue("TrainBrakeControl", 0) >= 0.4
    end,
    getacknowledge = function()
      return RailWorks.GetControlValue("AWSReset", 0) > 0
    end
  }

  alerter = Alerter:new{
    getacknowledge = function()
      return RailWorks.GetControlValue("AWSReset", 0) > 0
    end
  }
  alerter:start()

  blight = BrakeLight:new{}

  local ditchflash_s = 0.65
  ditchflasher = Flash:new{off_s = ditchflash_s, on_s = ditchflash_s}

  RailWorks.BeginUpdate()
end)

local function readcontrols()
  if RailWorks.GetControlValue("Horn", 0) > 0 then
    lasthorntime_s = RailWorks.GetSimulationTime()
  end
end

local function writelocostate()
  local penalty = alerter:ispenalty() or adu:ispenalty()
  -- There's no virtual throttle, so just move the combined power handle.
  if penalty then RailWorks.SetControlValue("ThrottleAndBrake", 0, 0.5) end
  -- There's no virtual train brake, so just move the braking handle.
  if penalty then RailWorks.SetControlValue("TrainBrakeControl", 0, 0.85) end

  local alarm = alerter:isalarm() or adu:isalarm()
  local alert = adu:isalertplaying()
  RailWorks.SetControlValue("AlerterAudible", 0, Misc.intbool(alarm or alert))
end

local function setcutin()
  if Misc.isinitialized() then
    local atcon = RailWorks.GetControlValue("ATCCutIn", 0) == 1
    local acseson = RailWorks.GetControlValue("ACSESCutIn", 0) == 1
    adu:setatcstate(atcon)
    adu:setacsesstate(acseson)
    alerter:setrunstate(atcon or acseson)
  end
end

local function setdynamicbraketab()
  local setuptime_s = 7
  local setuppos = 0.444444
  local insetup = RailWorks.GetControlValue("ThrottleAndBrake", 0) < setuppos
  local clock_s = RailWorks.GetSimulationTime()
  if RailWorks.GetControlValue("ThrottleAndBrake", 0) >= 0.5 then
    lastthrottletime_s = clock_s
  end
  if lastthrottletime_s ~= nil and clock_s < lastthrottletime_s + setuptime_s and
    insetup then
    RailWorks.SetControlValue("ThrottleAndBrake", 0, setuppos)
    RailWorks.SetControlValue("Buzzer", 0, 1)
  else
    RailWorks.SetControlValue("Buzzer", 0, 0)
  end
end

local function setadu()
  local aspect = adu:getaspect()
  local c, l, m, r
  if aspect == GenesisAdu.aspect.restrict then
    c, l, m, r = 0, 0, 0, 1
  elseif aspect == GenesisAdu.aspect.medium then
    c, l, m, r = 0, 0, 1, 0
  elseif aspect == GenesisAdu.aspect.limited then
    c, l, m, r = 0, 1, 0, 0
  elseif aspect == GenesisAdu.aspect.clear then
    c, l, m, r = 1, 0, 0, 0
  end
  RailWorks.SetControlValue("ADU00", 0, c)
  RailWorks.SetControlValue("ADU01", 0, l)
  RailWorks.SetControlValue("ADU02", 0, l)
  RailWorks.SetControlValue("ADU03", 0, m)
  RailWorks.SetControlValue("ADU04", 0, r)
end

local function setdisplay()
  local speed_mph = RailWorks.GetControlValue("SpeedometerMPH", 0)
  RailWorks.SetControlValue("SpeedoHundreds", 0, Misc.getdigit(speed_mph, 2))
  RailWorks.SetControlValue("SpeedoTens", 0, Misc.getdigit(speed_mph, 1))
  RailWorks.SetControlValue("SpeedoUnits", 0, Misc.getdigit(speed_mph, 0))
  RailWorks.SetControlValue("SpeedoDecimal", 0, Misc.getdigit(speed_mph, -1))

  local overspeed_mph = adu:getoverspeed_mph()
  if overspeed_mph == nil then
    RailWorks.SetControlValue("TrackHundreds", 0, -1)
    RailWorks.SetControlValue("TrackTens", 0, -1)
    RailWorks.SetControlValue("TrackUnits", 0, -1)
  else
    RailWorks.SetControlValue("TrackHundreds", 0,
                              Misc.getdigit(overspeed_mph, 2))
    RailWorks.SetControlValue("TrackTens", 0, Misc.getdigit(overspeed_mph, 1))
    RailWorks.SetControlValue("TrackUnits", 0, Misc.getdigit(overspeed_mph, 0))
  end

  RailWorks.SetControlValue("AlerterVisual", 0, Misc.intbool(alerter:isalarm()))
end

local function setplayerditchlights()
  local horntime_s = 30
  local horn = lasthorntime_s ~= nil and RailWorks.GetSimulationTime() <=
                 lasthorntime_s + horntime_s
  local flash = horn
  local headlights = RailWorks.GetControlValue("Headlights", 0)
  local crosslights = RailWorks.GetControlValue("CrossingLight", 0)
  local fixed = headlights > 0.5 and headlights < 1.5 and crosslights == 1 and
                  not flash
  ditchflasher:setflashstate(flash)
  local flashleft = ditchflasher:ison()

  local showleft = fixed or (flash and flashleft)
  RailWorks.ActivateNode("ditch_left", showleft)
  Call("DitchLight_L:Activate", Misc.intbool(showleft))

  local showright = fixed or (flash and not flashleft)
  RailWorks.ActivateNode("ditch_right", showright)
  Call("DitchLight_R:Activate", Misc.intbool(showright))
end

local function sethelperditchlights()
  RailWorks.ActivateNode("ditch_left", false)
  Call("DitchLight_L:Activate", Misc.intbool(false))
  RailWorks.ActivateNode("ditch_right", false)
  Call("DitchLight_R:Activate", Misc.intbool(false))
end

local function setaiditchlights()
  local ishead = RailWorks.GetSpeed() > Misc.stopped_mps
  RailWorks.ActivateNode("ditch_left", ishead)
  Call("DitchLight_L:Activate", Misc.intbool(ishead))
  RailWorks.ActivateNode("ditch_right", ishead)
  Call("DitchLight_R:Activate", Misc.intbool(ishead))
end

local function setcablights()
  local function activate(v) return Misc.intbool(v > 0.8) end
  -- engineer's side task light
  Call("CabLight_R:Activate",
       activate(RailWorks.GetControlValue("CabLight3", 0)))
  -- engineer's forward task light
  Call("TaskLight_R:Activate",
       activate(RailWorks.GetControlValue("CabLight1", 0)))
  -- secondman's forward task light
  Call("TaskLight_L:Activate",
       activate(RailWorks.GetControlValue("CabLight2", 0)))
  -- secondman's side task light
  Call("CabLight_L:Activate",
       activate(RailWorks.GetControlValue("CabLight4", 0)))
  -- dome light
  Call("CabLight_M:Activate",
       activate(RailWorks.GetControlValue("CabLight5", 0)))
end

local function setexhaust()
  local r, g, b, rate
  local minrpm = 180
  local effort = RailWorks.GetTractiveEffort()
  if RailWorks.GetControlValue("RPM", 0) < minrpm then
    r, g, b = 0, 0, 0
    rate = 0
    -- DTG's exhaust logic
  elseif effort < 0.1 then
    r, g, b = 0.25, 0.25, 0.25
    rate = 0.01
  elseif effort >= 0.1 and effort < 0.5 then
    r, g, b = 0.1, 0.1, 0.1
    rate = 0.005
  else
    r, g, b = 0, 0, 0
    rate = 0.001
  end
  Call("DieselExhaust:SetEmitterColour", r, g, b)
  Call("DieselExhaust:SetEmitterRate", rate)
end

local function updateplayer(dt)
  readcontrols()

  adu:update(dt)
  alerter:update(dt)
  blight:playerupdate(dt)

  writelocostate()
  setcutin()
  setdynamicbraketab()
  setadu()
  setdisplay()
  setplayerditchlights()
  setcablights()
  setexhaust()
end

local function updatehelper()
  sethelperditchlights()
  setcablights()
  setexhaust()
end

local function updateai()
  setaiditchlights()
  setcablights()
  setexhaust()
end

Update = Misc.wraperrors(function(dt)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer(dt)
  elseif RailWorks.GetIsPlayer() then
    updatehelper(dt)
  else
    updateai()
  end
end)

OnControlValueChange = Misc.wraperrors(function(name, index, value)
  if name == "ThrottleAndBrake" or name == "TrainBrakeControl" then
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
