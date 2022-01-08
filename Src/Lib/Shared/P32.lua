-- Engine script for the P32AC-DM operated by Amtrak and Metro-North.
--
-- @include RollingStock/PowerSupply/Electrification.lua
-- @include RollingStock/PowerSupply/PowerSupply.lua
-- @include RollingStock/BrakeLight.lua
-- @include SafetySystems/AspectDisplay/Genesis.lua
-- @include SafetySystems/Alerter.lua
-- @include Flash.lua
-- @include Iterator.lua
-- @include Misc.lua
-- @include RailWorks.lua
-- @include Scheduler.lua
-- @include Units.lua
local powermode = {thirdrail = 0, diesel = 1}

local playersched, anysched
local adu
local alerter
local power
local blight
local ditchflasher
local state = {
  throttle = 0,
  train_brake = 0,
  acknowledge = false,

  speed_mps = 0,
  acceleration_mps2 = 0,
  trackspeed_mps = 0,
  consistlength_m = 0,
  speedlimits = {},
  restrictsignals = {},

  lastchangetime_s = nil,
  lasthorntime_s = nil
}

Initialise = Misc.wraperrors(function()
  playersched = Scheduler:new{}
  anysched = Scheduler:new{}

  adu = GenesisAdu:new{
    isamtrak = isamtrak,
    getbrakesuppression = function() return state.train_brake >= 0.4 end,
    getacknowledge = function() return state.acknowledge end,
    getspeed_mps = function() return state.speed_mps end,
    gettrackspeed_mps = function() return state.trackspeed_mps end,
    getconsistlength_m = function() return state.consistlength_m end,
    iterspeedlimits = function() return pairs(state.speedlimits) end,
    iterrestrictsignals = function() return pairs(state.restrictsignals) end
  }

  alerter = Alerter:new{}
  alerter:start()

  local iselectric = string.sub(RailWorks.GetRVNumber(), 1, 1) == "T"
  power = PowerSupply:new{
    modecontrol = "PowerMode",
    -- The power mode control is reversed in DTG's cab car; compensate for this
    -- (while sacrificing P32-to-P32 MU capability).
    modereadfn = function(v)
      local ishelper = not RailWorks.GetIsEngineWithKey() and
                         RailWorks.GetIsPlayer()
      local mode = ishelper and 1 - v or v
      -- AI locos require some extra safeguards. Control values may be raw.
      return math.max(Misc.round(mode), 0)
    end,
    transition_s = 20,
    getcantransition = function() return state.throttle <= 0 end,
    modes = {
      [powermode.thirdrail] = function(elec)
        return elec:isavailable(Electrification.type.thirdrail)
      end,
      [powermode.diesel] = function(elec) return true end
    },
    getautomode = function(cp)
      if cp == Electrification.autochangepoint.ai_to_thirdrail then
        return powermode.thirdrail
      elseif cp == Electrification.autochangepoint.ai_to_diesel then
        return powermode.diesel
      else
        return nil
      end
    end
  }
  power:setavailable(Electrification.type.thirdrail, iselectric)

  blight = BrakeLight:new{}

  local ditchflash_s = 0.65
  ditchflasher = Flash:new{
    scheduler = playersched,
    off_s = ditchflash_s,
    on_s = ditchflash_s
  }

  RailWorks.BeginUpdate()
end)

local function readcontrols()
  state.throttle = RailWorks.GetControlValue("VirtualThrottle", 0)
  state.train_brake = RailWorks.GetControlValue("TrainBrakeControl", 0)
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) > 0
  if state.acknowledge then alerter:acknowledge() end

  if RailWorks.GetControlValue("Horn", 0) > 0 then
    state.lasthorntime_s = playersched:clock()
  end
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
  local haspower = power:haspower()
  local throttle = (penalty or not haspower) and 0 or state.throttle
  RailWorks.SetControlValue("Regulator", 0, throttle)
  RailWorks.SetPowerProportion(-1, Misc.intbool(haspower))
  -- There's no virtual train brake, so just move the braking handle.
  if penalty then RailWorks.SetControlValue("TrainBrakeControl", 0, 0.85) end

  -- DTG's "blended braking" algorithm
  local dynbrake
  local pipepress_psi = 70 -
                          RailWorks.GetControlValue("AirBrakePipePressurePSI", 0)
  if power:getmode() == powermode.thirdrail then
    dynbrake = 0
  elseif pipepress_psi > 0 then
    dynbrake = pipepress_psi * 0.01428
  else
    dynbrake = 0
  end
  RailWorks.SetControlValue("DynamicBrake", 0, dynbrake)

  local alarm = alerter:isalarm() or adu:isalarm()
  local alert = adu:isalertplaying()
  RailWorks.SetControlValue("AWS", 0, Misc.intbool(alarm or alert))
  RailWorks.SetControlValue("AWSWarnCount", 0, Misc.intbool(alarm))
end

local function setnonplayerstate()
  -- Read throttle and power mode from the lead locomotive.
  state.throttle = RailWorks.GetControlValue("Regulator", 0)
  RailWorks.SetPowerProportion(-1, Misc.intbool(power:haspower()))
end

local function setcutin()
  if not playersched:isstartup() then
    adu:setatcstate(RailWorks.GetControlValue("ATCCutIn", 0) == 1)
    adu:setacsesstate(RailWorks.GetControlValue("ACSESCutIn", 0) == 1)
  end
end

local function setadu()
  local aspect = adu:getaspect()
  local n, l, m, r
  if aspect == GenesisAdu.aspect.restrict then
    n, l, m, r = 0, 0, 0, 1
  elseif aspect == GenesisAdu.aspect.medium then
    n, l, m, r = 0, 0, 1, 0
  elseif aspect == GenesisAdu.aspect.limited then
    n, l, m, r = 0, 1, 0, 0
  elseif aspect == GenesisAdu.aspect.clear then
    n, l, m, r = 1, 0, 0, 0
  end
  RailWorks.SetControlValue("SigN", 0, n)
  RailWorks.SetControlValue("SigL", 0, l)
  RailWorks.SetControlValue("SigM", 0, m)
  RailWorks.SetControlValue("SigR", 0, r)

  local sigspeed_mph = adu:getsignalspeed_mph()
  if sigspeed_mph == nil then
    RailWorks.SetControlValue("SignalSpeed", 0, 1) -- hide
  else
    RailWorks.SetControlValue("SignalSpeed", 0, sigspeed_mph)
  end
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

local function setditchlights()
  local horntime_s = 30
  local horn = state.lasthorntime_s ~= nil and playersched:clock() <=
                 state.lasthorntime_s + horntime_s
  local flash = isamtrak and horn
  local headlights = RailWorks.GetControlValue("Headlights", 0)
  local crosslights = RailWorks.GetControlValue("CrossingLight", 0) == 1
  local fixed = headlights > 0.5 and headlights < 1.5 and crosslights and
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

local function setcablights()
  local function activate(v) return Misc.intbool(v > 0.8) end
  -- engineer's side task light
  Call("CabLight_R:Activate", activate(RailWorks.GetControlValue("CabLight", 0)))
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
  if power:getmode() == powermode.thirdrail or
    RailWorks.GetControlValue("RPM", 0) < minrpm then
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
  readlocostate()

  playersched:update()
  anysched:update()
  adu:update(dt)
  alerter:update(dt)
  power:update(dt)
  blight:playerupdate()

  writelocostate()
  setcutin()
  setadu()
  setdisplay()
  setditchlights()
  setcablights()
  setexhaust()
end

local function updatenonplayer(dt)
  anysched:update()
  power:update(dt)

  setnonplayerstate()
  setditchlights()
  setcablights()
  setexhaust()
end

Update = Misc.wraperrors(function(dt)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer(dt)
  else
    updatenonplayer(dt)
  end
end)

OnControlValueChange = Misc.wraperrors(function(name, index, value)
  if name == "ExpertPowerMode" and RailWorks.GetIsEngineWithKey() and
    not anysched:isstartup() and (value == 0 or value == 1) then
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
