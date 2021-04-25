-- Engine script for the P32AC-DM operated by Amtrak and Metro-North.

local sched
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
  headlights = 0,
  crosslights = false,

  speed_mps = 0,
  acceleration_mps2 = 0,
  trackspeed_mps = 0,
  consistlength_m = 0,
  speedlimits = {},
  restrictsignals = {},

  powermode = nil,
  lastchangetime_s = nil,
  lasthorntime_s = nil
}

local powermode = {diesel=0, thirdrail=1}

Initialise = RailWorks.wraperrors(function ()
  sched = Scheduler:new{}

  atc = Atc:new{
    scheduler = sched,
    getspeed_mps = function () return state.speed_mps end,
    getacceleration_mps2 = function () return state.acceleration_mps2 end,
    getacknowledge = function () return state.acknowledge end,
    doalert = function () adu:doatcalert() end,
    getpulsecodespeed_mps = Atc.mtapulsecodespeed_mps,
    getbrakesuppression = function () return state.train_brake >= 0.4 end
  }

  acses = Acses:new{
    scheduler = sched,
    getspeed_mps = function () return state.speed_mps end,
    gettrackspeed_mps = function () return state.trackspeed_mps end,
    getconsistlength_m = function () return state.consistlength_m end,
    iterspeedlimits = function () return pairs(state.speedlimits) end,
    iterrestrictsignals = function () return pairs(state.restrictsignals) end,
    getacknowledge = function () return state.acknowledge end,
    doalert = function () adu:doacsesalert() end,
    consistspeed_mps = 80*Units.mph.tomps
  }

  local onebeep_s = 1
  adu = GenesisAdu:new{
    scheduler = sched,
    atc = atc,
    atcalert_s = onebeep_s,
    acses = acses,
    acsesalert_s = onebeep_s
  }

  atc:start()
  acses:start()

  alerter = Alerter:new{
    scheduler = sched,
    getspeed_mps = function () return state.speed_mps end
  }
  alerter:start()

  if string.sub(RailWorks.GetRVNumber(), 1, 1) == "T" then
    power = Power:new{available={Power.types.thirdrail}}
    state.powermode = powermode.electric
  else
    power = Power:new{available={}}
    state.powermode = powermode.diesel
  end
  power:setcollectors(Power.types.thirdrail)

  local ditchflash_s = 1
  ditchflasher = Flash:new{
    scheduler = sched,
    off_s = ditchflash_s,
    on_s = ditchflash_s
  }

  RailWorks.BeginUpdate()
end)

local function readcontrols ()
  local vthrottle = RailWorks.GetControlValue("VirtualThrottle", 0)
  local brake = RailWorks.GetControlValue("TrainBrakeControl", 0)
  local change = vthrottle ~= state.throttle or brake ~= state.train_brake
  state.throttle = vthrottle
  state.train_brake = brake
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) == 1
  if state.acknowledge or change then
    alerter:acknowledge()
  end

  if RailWorks.GetControlValue("Horn", 0) > 0 then
    state.lasthorntime_s = sched:clock()
  end

  state.headlights = RailWorks.GetControlValue("Headlights", 0)
  state.crosslights = RailWorks.GetControlValue("CrossingLight", 0) == 1
end

local function readlocostate ()
  state.speed_mps =
    RailWorks.GetControlValue("SpeedometerMPH", 0)*Units.mph.tomps
  state.acceleration_mps2 =
    RailWorks.GetAcceleration()
  state.trackspeed_mps =
    RailWorks.GetCurrentSpeedLimit(1)
  state.consistlength_m =
    RailWorks.GetConsistLength()
  state.speedlimits =
    Iterator.totable(RailWorks.iterspeedlimits(Acses.nlimitlookahead))
  state.restrictsignals =
    Iterator.totable(RailWorks.iterrestrictsignals(Acses.nsignallookahead))
end

local function writelocostate ()
  local penalty = alerter:ispenalty() or atc:ispenalty() or acses:ispenalty()
  local penaltybrake = 0.85
  local changetime_s = 20
  do
    local v
    if state.powermode == powermode.electric
        and not power:haspower() then
      v = 0
    elseif state.lastchangetime_s ~= nil
        and sched:clock() <= state.lastchangetime_s + changetime_s then
      v = 0
    elseif penalty then
      v = 0
    else
      v = state.throttle
    end
    RailWorks.SetControlValue("Regulator", 0, v)
  end

  -- There's no virtual train brake, so just move the braking handle.
  if penalty then
    RailWorks.SetControlValue("TrainBrakeControl", 0, penaltybrake)
  end

  do
    -- DTG's "blended braking" algorithm
    local v
    local maxpressure_psi = 70
    local pipepress_psi =
      maxpressure_psi - RailWorks.GetControlValue("AirBrakePipePressurePSI", 0)
    if state.powermode == powermode.electric then v = 0
    elseif pipepress_psi > 0 then v = pipepress_psi*0.01428
    else v = 0 end
    RailWorks.SetControlValue("DynamicBrake", 0, v)
  end
  do
    local alarm = alerter:isalarm() or atc:isalarm() or acses:isalarm()
    local alert = adu:isatcalert() or adu:isacsesalert()
    RailWorks.SetControlValue("AWS", 0, RailWorks.frombool(alarm or alert))
    RailWorks.SetControlValue("AWSWarnCount", 0, RailWorks.frombool(alarm))
  end
end

local function setcutin ()
  if not sched:isstartup() then
    atc:setrunstate(RailWorks.GetControlValue("ATCCutIn", 0) == 1)
    acses:setrunstate(RailWorks.GetControlValue("ACSESCutIn", 0) == 1)
  end
end

local function getdigit (v, place)
  local tens = math.pow(10, place)
  if place > 0 and v < tens then
    return -1
  else
    return math.floor(math.mod(v, tens*10)/tens)
  end
end

local function setadu ()
  do
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
  end
  do
    local sigspeed_mph = adu:getsignalspeed_mph()
    if sigspeed_mph == nil then
      RailWorks.SetControlValue("SignalSpeed", 0, 1) -- hide
    else
      RailWorks.SetControlValue("SignalSpeed", 0, sigspeed_mph)
    end
  end
end

local function setdisplay ()
  do
    local speed_mph = RailWorks.GetControlValue("SpeedometerMPH", 0)
    RailWorks.SetControlValue("SpeedoHundreds", 0, getdigit(speed_mph, 2))
    RailWorks.SetControlValue("SpeedoTens", 0, getdigit(speed_mph, 1))
    RailWorks.SetControlValue("SpeedoUnits", 0, getdigit(speed_mph, 0))
    RailWorks.SetControlValue("SpeedoDecimal", 0, getdigit(speed_mph, -1))
  end
  do
    local overspeed_mph = adu:getoverspeed_mph()
    if overspeed_mph == nil then
      RailWorks.SetControlValue("TrackHundreds", 0, -1)
      RailWorks.SetControlValue("TrackTens", 0, -1)
      RailWorks.SetControlValue("TrackUnits", 0, -1)
    else
      RailWorks.SetControlValue("TrackHundreds", 0, getdigit(overspeed_mph, 2))
      RailWorks.SetControlValue("TrackTens", 0, getdigit(overspeed_mph, 1))
      RailWorks.SetControlValue("TrackUnits", 0, getdigit(overspeed_mph, 0))
    end
  end
  RailWorks.SetControlValue(
    "AlerterVisual", 0, RailWorks.frombool(alerter:isalarm()))
end

local function setditchlights ()
  local horntime_s = 30
  local horn = state.lasthorntime_s ~= nil
    and sched:clock() <= state.lasthorntime_s + horntime_s
  local flash = horn
  local fixed = state.headlights > 0.5
    and state.headlights < 1.5
    and state.crosslights
    and not flash
  ditchflasher:setflashstate(flash)
  local flashleft = ditchflasher:ison()
  do
    local showleft = fixed or (flash and flashleft)
    RailWorks.ActivateNode("ditch_left", showleft)
    Call("DitchLight_L:Activate", RailWorks.frombool(showleft))
  end
  do
    local showright = fixed or (flash and not flashleft)
    RailWorks.ActivateNode("ditch_right", showright)
    Call("DitchLight_R:Activate", RailWorks.frombool(showright))
  end
end

local setcablights
do
  local function activate (v)
    return RailWorks.frombool(v > 0.8)
  end
  setcablights = function ()
    -- engineer's side task light
    Call("CabLight_R:Activate", activate(RailWorks.GetControlValue("CabLight", 0)))
    -- engineer's forward task light
    Call("TaskLight_R:Activate", activate(RailWorks.GetControlValue("CabLight1", 0)))
    -- secondman's forward task light
    Call("TaskLight_L:Activate", activate(RailWorks.GetControlValue("CabLight2", 0)))
    -- secondman's side task light
    Call("CabLight_L:Activate", activate(RailWorks.GetControlValue("CabLight4", 0)))
    -- dome light
    Call("CabLight_M:Activate", activate(RailWorks.GetControlValue("CabLight5", 0)))
  end
end

local function setpowermode ()
  local pwrmode = RailWorks.GetControlValue("PowerMode", 0)
  if pwrmode == 0 and state.powermode == powermode.diesel then
    state.powermode = powermode.electric
    state.lastchangetime_s = sched:clock()
  elseif pwrmode == 1 and state.powermode == powermode.electric then
    state.powermode = powermode.diesel
    state.lastchangetime_s = sched:clock()
  end
end

local function setplayerpowermode ()
  if state.throttle <= 0 then
    setpowermode()
  end
  RailWorks.SetControlValue(
    "Power3rdRail", 0, RailWorks.frombool(power:isavailable(Power.types.thirdrail)))
end

local function setaipowermode ()
  if RailWorks.GetControlValue("Regulator", 0) <= 0 then
    setpowermode()
  end
end

local function setexhaust ()
  local r, g, b, rate
  local minrpm = 180
  local effort = RailWorks.GetTractiveEffort()
  if state.powermode == powermode.electric
      or RailWorks.GetControlValue("RPM", 0) < minrpm then
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

local function updateplayer ()
  readcontrols()
  readlocostate()

  sched:update()

  writelocostate()
  setcutin()
  setadu()
  setdisplay()
  setditchlights()
  setcablights()
  setplayerpowermode()
  setexhaust()

  -- Prevent the acknowledge button from sticking if the button on the HUD is
  -- clicked.
  if state.acknowledge then
    RailWorks.SetControlValue("AWSReset", 0, 0)
  end
end

local function updateai ()
  setditchlights()
  setcablights()
  setaipowermode()
  setexhaust()
end

Update = RailWorks.wraperrors(function (_)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer()
  else
    updateai()
  end
end)

OnControlValueChange = RailWorks.SetControlValue

OnCustomSignalMessage = RailWorks.wraperrors(function (message)
  power:receivemessage(message)
  atc:receivemessage(message)
  acses:receivemessage(message)
end)

OnConsistMessage = RailWorks.Engine_SendConsistMessage