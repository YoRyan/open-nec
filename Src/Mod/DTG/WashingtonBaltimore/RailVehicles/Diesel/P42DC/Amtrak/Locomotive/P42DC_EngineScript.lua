-- Engine script for the P42DC operated by Amtrak.
-- @include SafetySystems/Acses/Acses.lua
-- @include SafetySystems/AspectDisplay/Genesis.lua
-- @include SafetySystems/Alerter.lua
-- @include SafetySystems/Atc.lua
-- @include Signals/CabSignal.lua
-- @include Flash.lua
-- @include Iterator.lua
-- @include RailWorks.lua
-- @include Scheduler.lua
-- @include Units.lua
local sched
local cabsig
local atc
local acses
local adu
local alerter
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

  lasthorntime_s = nil,
  lastthrottletime_s = nil
}

local function getdigit(v, place)
  local tens = math.pow(10, place)
  if place > 0 and v < tens then
    return -1
  else
    return math.floor(math.mod(v, tens * 10) / tens)
  end
end

local function setenginenumber()
  local number = tonumber(RailWorks.GetRVNumber()) or 0
  RailWorks.SetControlValue("LocoHundreds", 0, getdigit(number, 2))
  RailWorks.SetControlValue("LocoTens", 0, getdigit(number, 1))
  RailWorks.SetControlValue("LocoUnits", 0, getdigit(number, 0))
end

Initialise = RailWorks.wraperrors(function()
  setenginenumber()

  sched = Scheduler:new{}

  cabsig = CabSignal:new{scheduler = sched}

  atc = Atc:new{
    scheduler = sched,
    cabsignal = cabsig,
    getspeed_mps = function() return state.speed_mps end,
    getacceleration_mps2 = function() return state.acceleration_mps2 end,
    getacknowledge = function() return state.acknowledge end,
    doalert = function() adu:doatcalert() end,
    getbrakesuppression = function() return state.train_brake >= 0.4 end
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
    consistspeed_mps = 110 * Units.mph.tomps
  }

  local onebeep_s = 0.25
  adu = GenesisAdu:new{
    scheduler = sched,
    cabsignal = cabsig,
    atc = atc,
    atcalert_s = onebeep_s,
    acses = acses,
    acsesalert_s = onebeep_s
  }

  atc:start()
  acses:start()

  alerter = Alerter:new{
    scheduler = sched,
    getspeed_mps = function() return state.speed_mps end
  }

  local ditchflash_s = 1
  ditchflasher = Flash:new{
    scheduler = sched,
    off_s = ditchflash_s,
    on_s = ditchflash_s
  }

  RailWorks.BeginUpdate()
end)

local function readcontrols()
  local throttle = RailWorks.GetControlValue("ThrottleAndBrake", 0)
  local brake = RailWorks.GetControlValue("TrainBrakeControl", 0)
  local change = throttle ~= state.throttle or brake ~= state.train_brake
  state.throttle = throttle
  state.train_brake = brake
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) == 1
  if state.acknowledge or change then alerter:acknowledge() end

  if RailWorks.GetControlValue("Horn", 0) > 0 then
    state.lasthorntime_s = sched:clock()
  end

  state.headlights = RailWorks.GetControlValue("Headlights", 0)
  state.crosslights = RailWorks.GetControlValue("CrossingLight", 0) == 1
end

local function readlocostate()
  state.speed_mps = RailWorks.GetControlValue("SpeedometerMPH", 0) *
                      Units.mph.tomps
  state.acceleration_mps2 = RailWorks.GetAcceleration()
  state.trackspeed_mps = RailWorks.GetCurrentSpeedLimit(1)
  state.consistlength_m = RailWorks.GetConsistLength()
  state.speedlimits = Iterator.totable(RailWorks.iterspeedlimits(
                                         Acses.nlimitlookahead))
  state.restrictsignals = Iterator.totable(
                            RailWorks.iterrestrictsignals(Acses.nsignallookahead))
end

local function writelocostate()
  local penalty = alerter:ispenalty() or atc:ispenalty() or acses:ispenalty()
  local penaltybrake = 0.85
  -- There's no virtual throttle, so just move the combined power handle.
  if penalty then RailWorks.SetControlValue("ThrottleAndBrake", 0, 0.5) end
  -- There's no virtual train brake, so just move the braking handle.
  if penalty then
    RailWorks.SetControlValue("TrainBrakeControl", 0, penaltybrake)
  end
  do
    local alarm = alerter:isalarm() or atc:isalarm() or acses:isalarm()
    local alert = adu:isatcalert() or adu:isacsesalert()
    RailWorks.SetControlValue("AlerterAudible", 0,
                              RailWorks.frombool(alarm or alert))
  end
end

local function setdynamicbraketab()
  local setuptime_s = 7
  local setuppos = 0.444444
  if state.throttle >= 0.5 then state.lastthrottletime_s = sched:clock() end
  if state.lastthrottletime_s ~= nil and sched:clock() <
    state.lastthrottletime_s + setuptime_s and state.throttle < setuppos then
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
  RailWorks.SetControlValue("AlerterVisual", 0,
                            RailWorks.frombool(alerter:isalarm()))
end

local function setditchlights()
  local horntime_s = 30
  local horn = state.lasthorntime_s ~= nil and sched:clock() <=
                 state.lasthorntime_s + horntime_s
  local flash = horn
  local fixed = state.headlights > 0.5 and state.headlights < 1.5 and
                  state.crosslights and not flash
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
  local function activate(v) return RailWorks.frombool(v > 0.8) end
  setcablights = function()
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

local function updateplayer()
  readcontrols()
  readlocostate()

  sched:update()

  writelocostate()
  setdynamicbraketab()
  setadu()
  setdisplay()
  setditchlights()
  setcablights()
  setexhaust()

  -- Prevent the acknowledge button from sticking if the button on the HUD is
  -- clicked.
  if state.acknowledge then RailWorks.SetControlValue("AWSReset", 0, 0) end
end

local function updateai()
  setditchlights()
  setcablights()
  setexhaust()
end

Update = RailWorks.wraperrors(function(_)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer()
  else
    updateai()
  end
end)

OnControlValueChange = RailWorks.SetControlValue

OnCustomSignalMessage = RailWorks.wraperrors(function(message)
  cabsig:receivemessage(message)
end)

OnConsistMessage = RailWorks.Engine_SendConsistMessage
