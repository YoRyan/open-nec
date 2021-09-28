-- Engine script for the P32AC-DM operated by Amtrak and Metro-North.
--
-- @include RollingStock/PowerSupply/Electrification.lua
-- @include RollingStock/PowerSupply/PowerSupply.lua
-- @include SafetySystems/Acses/Acses.lua
-- @include SafetySystems/AspectDisplay/Genesis.lua
-- @include SafetySystems/Alerter.lua
-- @include SafetySystems/Atc.lua
-- @include Signals/CabSignal.lua
-- @include Flash.lua
-- @include Iterator.lua
-- @include Misc.lua
-- @include RailWorks.lua
-- @include Scheduler.lua
-- @include Units.lua
local powermode = {thirdrail = 0, diesel = 1}

local playersched, anysched
local cabsig
local atc
local acses
local adu
local alerter
local power
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

  cabsig = CabSignal:new{scheduler = playersched}

  atc = Atc:new{
    scheduler = playersched,
    cabsignal = cabsig,
    getspeed_mps = function() return state.speed_mps end,
    getacceleration_mps2 = function() return state.acceleration_mps2 end,
    getacknowledge = function() return state.acknowledge end,
    doalert = function() adu:doatcalert() end,
    getpulsecodespeed_mps = Atc.mtapulsecodespeed_mps,
    getbrakesuppression = function() return state.train_brake >= 0.4 end
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
    consistspeed_mps = (isamtrak and 110 or 80) * Units.mph.tomps
  }

  local onebeep_s = 1
  adu = GenesisAdu:new{
    scheduler = playersched,
    cabsignal = cabsig,
    atc = atc,
    atcalert_s = onebeep_s,
    acses = acses,
    acsesalert_s = onebeep_s
  }

  atc:start()
  acses:start()

  alerter = Alerter:new{
    scheduler = playersched,
    getspeed_mps = function() return state.speed_mps end
  }
  alerter:start()

  local iselectric = string.sub(RailWorks.GetRVNumber(), 1, 1) == "T"
  power = PowerSupply:new{
    scheduler = anysched,
    modecontrol = "PowerMode",
    -- The power mode control is reversed in DTG's cab car; compensate for this
    -- (while sacrificing P32-to-P32 MU capability).
    modereadfn = function(v)
      local ishelper = not RailWorks.GetIsEngineWithKey() and
                         RailWorks.GetIsPlayer()
      return ishelper and 1 - v or v
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

  local ditchflash_s = 0.65
  ditchflasher = Flash:new{
    scheduler = playersched,
    off_s = ditchflash_s,
    on_s = ditchflash_s
  }

  RailWorks.BeginUpdate()
end)

local function readcontrols()
  local vthrottle = RailWorks.GetControlValue("VirtualThrottle", 0)
  local brake = RailWorks.GetControlValue("TrainBrakeControl", 0)
  local change = vthrottle ~= state.throttle or brake ~= state.train_brake
  state.throttle = vthrottle
  state.train_brake = brake
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) > 0
  if state.acknowledge or change then alerter:acknowledge() end

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
  local penalty = alerter:ispenalty() or atc:ispenalty() or acses:ispenalty()
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

  local alarm = alerter:isalarm() or atc:isalarm() or acses:isalarm()
  local alert = adu:isatcalert() or adu:isacsesalert()
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
    atc:setrunstate(RailWorks.GetControlValue("ATCCutIn", 0) == 1)
    acses:setrunstate(RailWorks.GetControlValue("ACSESCutIn", 0) == 1)
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

local function updateplayer()
  readcontrols()
  readlocostate()

  playersched:update()
  anysched:update()
  power:update()

  writelocostate()
  setcutin()
  setadu()
  setdisplay()
  setditchlights()
  setcablights()
  setexhaust()
end

local function updatenonplayer()
  anysched:update()
  power:update()

  setnonplayerstate()
  setditchlights()
  setcablights()
  setexhaust()
end

Update = Misc.wraperrors(function(_)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer()
  else
    updatenonplayer()
  end
end)

OnControlValueChange = Misc.wraperrors(function(name, index, value)
  if name == "ExpertPowerMode" and not anysched:isstartup() and
    (value == 0 or value == 1) then Misc.showalert("Not available in OpenNEC") end

  RailWorks.SetControlValue(name, index, value)
end)

OnCustomSignalMessage = Misc.wraperrors(function(message)
  power:receivemessage(message)
  cabsig:receivemessage(message)
end)

OnConsistMessage = Misc.wraperrors(function(message, argument, direction)
  RailWorks.Engine_SendConsistMessage(message, argument, direction)
end)
