-- Engine script for the Acela Express operated by Amtrak.
-- @include RollingStock/CruiseControl.lua
-- @include RollingStock/Power.lua
-- @include RollingStock/RangeScroll.lua
-- @include RollingStock/Spark.lua
-- @include SafetySystems/Acses/Acses.lua
-- @include SafetySystems/AspectDisplay/AmtrakTwoSpeed.lua
-- @include SafetySystems/Alerter.lua
-- @include SafetySystems/Atc.lua
-- @include Animation.lua
-- @include Flash.lua
-- @include Iterator.lua
-- @include MovingAverage.lua
-- @include RailWorks.lua
-- @include Scheduler.lua
-- @include Units.lua
local playersched, anysched
local atc
local acses
local adu
local cruise
local alerter
local power
local frontpantoanim, rearpantoanim
local coneanim
local tracteffort
local groundflasher
local spark
local state = {
  throttle = 0,
  train_brake = 0,
  acknowledge = false,
  cruisespeed_mps = 0,
  cruiseenabled = false,
  startup = true,
  destinationjoy = 0,
  headlights = 0,
  groundlights = 0,

  speed_mps = 0,
  acceleration_mps2 = 0,
  trackspeed_mps = 0,
  consistlength_m = 0,
  speedlimits = {},
  restrictsignals = {},

  awsclearcount = 0,
  raisefrontpantomsg = nil,
  raiserearpantomsg = nil,
  lasthorntime_s = nil
}

local destscroller
local destinations = {
  {"No service", 24},
  {"Union Station", 3},
  {"BWI Airport", 4},
  {"Baltimore Penn", 5},
  {"Wilmington", 6},
  {"Philadelphia", 2},
  {"Trenton", 11},
  {"Metropark", 18},
  {"Newark Penn", 1},
  {"New York", 27},
  {"New Rochelle", 7},
  {"Stamford", 8},
  {"New Haven", 9},
  {"New London", 10},
  {"Providence", 12},
  {"Route 128", 13},
  {"Back Bay", 14},
  {"South Station", 15}
}

local messageid = {
  -- ID's must be reused from the DTG engine script so coaches will pass them down.
  raisefrontpanto = 1207,
  raiserearpanto = 1208,

  -- Used by the Acela coaches. Do not change.
  tiltisolate = 1209,
  destination = 1210
}

local function playawsclear()
  state.awsclearcount = math.mod(state.awsclearcount + 1, 2)
end

Initialise = RailWorks.wraperrors(function()
  playersched = Scheduler:new{}
  anysched = Scheduler:new{}

  atc = Atc:new{
    scheduler = playersched,
    getspeed_mps = function() return state.speed_mps end,
    getacceleration_mps2 = function() return state.acceleration_mps2 end,
    getacknowledge = function() return state.acknowledge end,
    doalert = function()
      adu:doatcalert()
      playawsclear()
    end,
    getbrakesuppression = function() return state.train_brake >= 0.4 end
  }

  acses = Acses:new{
    scheduler = playersched,
    getspeed_mps = function() return state.speed_mps end,
    gettrackspeed_mps = function() return state.trackspeed_mps end,
    getconsistlength_m = function() return state.consistlength_m end,
    iterspeedlimits = function() return pairs(state.speedlimits) end,
    iterrestrictsignals = function() return pairs(state.restrictsignals) end,
    getacknowledge = function() return state.acknowledge end,
    doalert = function()
      adu:doacsesalert()
      playawsclear()
    end
  }

  local alert_s = 1
  adu = AmtrakTwoSpeedAdu:new{
    scheduler = playersched,
    atc = atc,
    atcalert_s = alert_s,
    acses = acses,
    acsesalert_s = alert_s
  }

  atc:start()
  acses:start()

  cruise = Cruise:new{
    scheduler = playersched,
    getspeed_mps = function() return state.speed_mps end,
    gettargetspeed_mps = function() return state.cruisespeed_mps end,
    getenabled = function() return state.cruiseenabled end
  }

  alerter = Alerter:new{
    scheduler = playersched,
    getspeed_mps = function() return state.speed_mps end
  }
  alerter:start()

  power = Power:new{available = {Power.types.overhead}}

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

  coneanim = Animation:new{
    scheduler = playersched,
    animation = "cone",
    duration_s = 2
  }

  tracteffort = Average:new{nsamples = 30}

  local groundflash_s = 1
  groundflasher = Flash:new{
    scheduler = playersched,
    off_s = groundflash_s,
    on_s = groundflash_s
  }

  spark = PantoSpark:new{scheduler = anysched}

  destscroller = RangeScroll:new{
    scheduler = playersched,
    getdirection = function()
      if state.destinationjoy == -1 then
        return RangeScroll.direction.previous
      elseif state.destinationjoy == 1 then
        return RangeScroll.direction.next
      else
        return RangeScroll.direction.neutral
      end
    end,
    limit = table.getn(destinations),
    move_s = 0.5
  }

  RailWorks.BeginUpdate()
end)

local function readcontrols()
  local vthrottle = RailWorks.GetControlValue("VirtualThrottle", 0)
  local vbrake = RailWorks.GetControlValue("VirtualBrake", 0)
  local change = vthrottle ~= state.throttle or vbrake ~= state.train_brake
  state.throttle = vthrottle
  state.train_brake = vbrake
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) == 1
  if state.acknowledge or change then alerter:acknowledge() end

  if RailWorks.GetControlValue("Horn", 0) > 0 then
    state.lasthorntime_s = playersched:clock()
  end

  state.startup = RailWorks.GetControlValue("Startup", 0) == 1
  state.cruisespeed_mps = RailWorks.GetControlValue("CruiseControlSpeed", 0) *
                            Units.mph.tomps
  state.cruiseenabled = RailWorks.GetControlValue("CruiseControl", 0) == 1
  state.destinationjoy = RailWorks.GetControlValue("DestJoy", 0)
  state.headlights = RailWorks.GetControlValue("Headlights", 0)
  state.groundlights = RailWorks.GetControlValue("GroundLights", 0)
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

local function haspower() return power:haspower() and state.startup end

local function getdigit(v, place)
  local tens = math.pow(10, place)
  if place ~= 0 and v < tens then
    return -1
  else
    return math.floor(math.mod(v, tens * 10) / tens)
  end
end

local function writelocostate()
  local penalty = alerter:ispenalty() or atc:ispenalty() or acses:ispenalty()
  local penaltybrake = 0.6
  do
    local v
    if not haspower() then
      v = 0
    elseif penalty then
      v = 0
    elseif state.cruiseenabled then
      v = math.min(state.throttle, cruise:getthrottle())
    else
      v = state.throttle
    end
    RailWorks.SetControlValue("Regulator", 0, v)
  end
  do
    local v
    if penalty then
      v = penaltybrake
    else
      v = state.train_brake
    end
    RailWorks.SetControlValue("TrainBrakeControl", 0, v)
  end
  do
    -- DTG's "blended braking" algorithm
    local mineffectivespeed_mps = 10 * Units.mph.tomps
    local proportion = 0.3
    local v
    if penalty then
      v = penaltybrake * proportion
    elseif state.speed_mps >= mineffectivespeed_mps then
      v = state.train_brake * proportion
    else
      v = 0
    end
    RailWorks.SetControlValue("DynamicBrake", 0, v)
  end

  RailWorks.SetControlValue("AWSWarnCount", 0, RailWorks.frombool(
                              alerter:isalarm() or atc:isalarm() or
                                acses:isalarm()))
  RailWorks.SetControlValue("AWSClearCount", 0, state.awsclearcount)
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

  local frontcontact = frontpantoanim:getposition() == 1
  local rearcontact = rearpantoanim:getposition() == 1
  if frontcontact or rearcontact then
    power:setcollectors(Power.types.overhead)
  else
    power:setcollectors()
  end
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
  spark:setsparkstate(frontcontact or rearcontact)
  local isspark = spark:isspark()

  RailWorks.ActivateNode("Front_spark01", frontcontact and isspark)
  RailWorks.ActivateNode("Front_spark02", frontcontact and isspark)
  Call("Spark:Activate", RailWorks.frombool(frontcontact and isspark))

  RailWorks.ActivateNode("Rear_spark01", rearcontact and isspark)
  RailWorks.ActivateNode("Rear_spark02", rearcontact and isspark)
  Call("Spark2:Activate", RailWorks.frombool(rearcontact and isspark))
end

local function settilt()
  local isolate = RailWorks.GetControlValue("TiltIsolate", 0)
  RailWorks.Engine_SendConsistMessage(messageid.tiltisolate, isolate, 0)
  RailWorks.Engine_SendConsistMessage(messageid.tiltisolate, isolate, 1)
end

local function setcone()
  local open = RailWorks.GetControlValue("FrontCone", 0) == 1
  coneanim:setanimatedstate(open)
end

local setplayerdest
do
  local lastselected = 1
  function setplayerdest()
    local selected = destscroller:getselected()
    local destination, id = unpack(destinations[selected])
    if lastselected ~= selected then
      RailWorks.showalert(destination)
      lastselected = selected
    end

    if RailWorks.GetControlValue("DestOnOff", 0) == 1 then
      RailWorks.Engine_SendConsistMessage(messageid.destination, id, 0)
      RailWorks.Engine_SendConsistMessage(messageid.destination, id, 1)
    else
      RailWorks.Engine_SendConsistMessage(messageid.destination, 0, 0)
      RailWorks.Engine_SendConsistMessage(messageid.destination, 0, 1)
    end
  end
end

local function setaidest()
  RailWorks.Engine_SendConsistMessage(messageid.destination, 1, 0)
  RailWorks.Engine_SendConsistMessage(messageid.destination, 1, 1)
end

local function setstatusscreen()
  RailWorks.SetControlValue("ControlScreenIzq", 0,
                            RailWorks.frombool(not haspower()))
  do
    local frontpantoup = frontpantoanim:getposition() == 1
    local rearpantoup = rearpantoanim:getposition() == 1
    local indicator
    if not frontpantoup and not rearpantoup then
      indicator = -1
    elseif not frontpantoup and rearpantoup then
      indicator = 2
    elseif frontpantoup and not rearpantoup then
      indicator = 0
    elseif frontpantoup and rearpantoup then
      indicator = 1
    end
    RailWorks.SetControlValue("PantoIndicator", 0, indicator)
  end
  do
    local indicator
    if state.headlights == 1 then
      if state.groundlights == 1 then
        indicator = 1
      elseif state.groundlights == 2 then
        indicator = 2
      else
        indicator = 0
      end
    else
      indicator = -1
    end
    RailWorks.SetControlValue("LightsIndicator", 0, indicator)
  end
  do
    local maxtracteffort = 300
    tracteffort:sample(RailWorks.GetTractiveEffort() * maxtracteffort)
    RailWorks.SetControlValue("Effort", 0, tracteffort:get())
  end
end

local function toroundedmph(v) return math.floor(v * Units.mps.tomph + 0.5) end

local function getdigitguide(v)
  if v < 10 then
    return 0
  else
    return math.floor(math.log10(v))
  end
end

local function setdrivescreen()
  RailWorks.SetControlValue("ControlScreenDer", 0,
                            RailWorks.frombool(not haspower()))
  do
    local speed_mph = toroundedmph(state.speed_mps)
    RailWorks.SetControlValue("SPHundreds", 0, getdigit(speed_mph, 2))
    RailWorks.SetControlValue("SPTens", 0, getdigit(speed_mph, 1))
    RailWorks.SetControlValue("SPUnits", 0, getdigit(speed_mph, 0))
    RailWorks.SetControlValue("SpeedoGuide", 0, getdigitguide(speed_mph))
  end
  do
    local v
    if state.cruiseenabled then
      v = 8
    else
      v = math.floor(state.throttle * 6 + 0.5)
    end
    RailWorks.SetControlValue("PowerState", 0, v)
  end
end

local function setcutin()
  -- Reverse the polarities so that safety systems are on by default.
  atc:setrunstate(RailWorks.GetControlValue("ATCCutIn", 0) == 0)
  acses:setrunstate(RailWorks.GetControlValue("ACSESCutIn", 0) == 0)
end

local function setadu()
  do
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
  end
  -- If we set the digits too early, they flicker (or turn invisible) for the
  -- rest of the game.
  if not playersched:isstartup() then
    local signalspeed_mph = adu:getsignalspeed_mph()
    if signalspeed_mph == nil then
      RailWorks.SetControlValue("SignalSpeed", 0, 1) -- blank
    else
      RailWorks.SetControlValue("SignalSpeed", 0, signalspeed_mph)
    end
  end
  do
    local civilspeed_mph = adu:getcivilspeed_mph()
    if civilspeed_mph == nil then
      RailWorks.SetControlValue("TSHundreds", 0, -1)
      RailWorks.SetControlValue("TSTens", 0, -1)
      RailWorks.SetControlValue("TSUnits", 0, -1)
    else
      RailWorks.SetControlValue("TSHundreds", 0, getdigit(civilspeed_mph, 2))
      RailWorks.SetControlValue("TSTens", 0, getdigit(civilspeed_mph, 1))
      RailWorks.SetControlValue("TSUnits", 0, getdigit(civilspeed_mph, 0))
    end
  end
  RailWorks.SetControlValue("MaximumSpeedLimitIndicator", 0,
                            adu:getsquareindicator())
end

local function setcablight()
  local on = RailWorks.GetControlValue("CabLight", 0)
  Call("CabLight:Activate", on)
end

local function setgroundlights()
  local horntime_s = 30
  local horn = state.lasthorntime_s ~= nil and playersched:clock() <=
                 state.lasthorntime_s + horntime_s
  local fixed = state.headlights == 1 and state.groundlights == 1
  local flash = (state.headlights == 1 and state.groundlights == 2) or horn
  groundflasher:setflashstate(flash)
  local flashleft = groundflasher:ison()
  do
    local showleft = fixed or (flash and flashleft)
    RailWorks.ActivateNode("LeftOn", showleft)
    RailWorks.ActivateNode("DitchLightsL", showleft)
    Call("DitchLightLeft:Activate", RailWorks.frombool(showleft))
  end
  do
    local showright = fixed or (flash and not flashleft)
    RailWorks.ActivateNode("RightOn", showright)
    RailWorks.ActivateNode("DitchLightsR", showright)
    Call("DitchLightRight:Activate", RailWorks.frombool(showright))
  end
end

local function updateplayer()
  readcontrols()
  readlocostate()

  playersched:update()
  anysched:update()
  frontpantoanim:update()
  rearpantoanim:update()
  coneanim:update()

  writelocostate()
  setplayerpantos()
  setpantosparks()
  settilt()
  setcone()
  setplayerdest()
  setstatusscreen()
  setdrivescreen()
  setcutin()
  setadu()
  setcablight()
  setgroundlights()

  -- Prevent the acknowledge button from sticking if the button on the HUD is
  -- clicked.
  if state.acknowledge then RailWorks.SetControlValue("AWSReset", 0, 0) end
end

local function updateai()
  anysched:update()
  frontpantoanim:update()
  rearpantoanim:update()

  setaipantos()
  setaidest()
  setpantosparks()
  setcablight()
  setgroundlights()
end

local function updateslave()
  anysched:update()
  frontpantoanim:update()
  rearpantoanim:update()

  setslavepantos()
  setpantosparks()
  setcablight()
  setgroundlights()
end

Update = RailWorks.wraperrors(function(_)
  -- -> [slave][coach]...[coach][player] ->
  -- -> [ai   ][coach]...[coach][ai    ] ->
  if RailWorks.GetIsEngineWithKey() then
    updateplayer()
  elseif RailWorks.GetIsPlayer() then
    updateslave()
  else
    updateai()
  end
end)

OnControlValueChange = RailWorks.SetControlValue

OnCustomSignalMessage = RailWorks.wraperrors(function(message)
  power:receivemessage(message)
  atc:receivemessage(message)
  acses:receivemessage(message)
end)

OnConsistMessage = RailWorks.wraperrors(function(message, argument, direction)
  -- Cross the pantograph states. We assume the slave engine is flipped.
  if message == messageid.raisefrontpanto then
    state.raiserearpantomsg = argument == "true"
  elseif message == messageid.raiserearpanto then
    state.raisefrontpantomsg = argument == "true"
  end
  RailWorks.Engine_SendConsistMessage(message, argument, direction)
end)
