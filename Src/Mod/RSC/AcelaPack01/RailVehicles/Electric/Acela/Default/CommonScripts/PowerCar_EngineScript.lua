-- Engine script for the Acela Express operated by Amtrak.
--
-- @include RollingStock/PowerSupply/Electrification.lua
-- @include RollingStock/PowerSupply/PowerSupply.lua
-- @include RollingStock/BrakeLight.lua
-- @include RollingStock/CruiseControl.lua
-- @include RollingStock/RangeScroll.lua
-- @include RollingStock/Spark.lua
-- @include SafetySystems/AspectDisplay/AmtrakTwoSpeed.lua
-- @include SafetySystems/Alerter.lua
-- @include Animation.lua
-- @include Flash.lua
-- @include Iterator.lua
-- @include Misc.lua
-- @include MovingAverage.lua
-- @include RailWorks.lua
-- @include Units.lua
local adu
local cruise
local alerter
local power
local blight
local frontpantoanim, rearpantoanim
local coneanim
local tracteffort
local groundflasher
local spark
local destscroller

local messageid = {
  -- ID's must be reused from the DTG engine script so coaches will pass them down.
  raisefrontpanto = 1207,
  raiserearpanto = 1208,

  -- Used by the Acela coaches. Do not change.
  tiltisolate = 1209,
  destination = 1210
}
local destinations = {
  {"No service", 24},
  {"Union Station", 3},
  {"New Carrollton", 19},
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

local raisefrontpantomsg = nil
local raiserearpantomsg = nil
local adualertplaying = false

Initialise = Misc.wraperrors(function()
  adu = AmtrakTwoSpeedAdu:new{
    getbrakesuppression = function()
      return RailWorks.GetControlValue("VirtualBrake", 0) > 0.3
    end,
    getacknowledge = function()
      return RailWorks.GetControlValue("AWSReset", 0) > 0
    end
  }

  cruise = Cruise:new{
    getplayerthrottle = function()
      return RailWorks.GetControlValue("VirtualThrottle", 0)
    end,
    gettargetspeed_mps = function()
      return RailWorks.GetControlValue("CruiseControlSpeed", 0) *
               Units.mph.tomps
    end,
    getenabled = function()
      return RailWorks.GetControlValue("CruiseControl", 0) == 1
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

  coneanim = Animation:new{animation = "cone", duration_s = 2}

  tracteffort = Average:new{nsamples = 30}

  local groundflash_s = 0.65
  groundflasher = Flash:new{off_s = groundflash_s, on_s = groundflash_s}

  spark = PantoSpark:new{}

  destscroller = RangeScroll:new{
    getdirection = function()
      local joy = RailWorks.GetControlValue("DestJoy", 0)
      if joy == -1 then
        return RangeScroll.direction.previous
      elseif joy == 1 then
        return RangeScroll.direction.next
      else
        return RangeScroll.direction.neutral
      end
    end,
    onchange = function(v)
      local destination, _ = unpack(destinations[v])
      Misc.showalert(destination)
    end,
    limit = table.getn(destinations),
    move_s = 0.5
  }

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

  local airbrake = penalty and 0.6 or
                     RailWorks.GetControlValue("VirtualBrake", 0)
  RailWorks.SetControlValue("TrainBrakeControl", 0, airbrake)

  -- DTG's "blended braking" algorithm
  local speed_mph = RailWorks.GetControlValue("SpeedometerMPH", 0)
  local dynbrake = speed_mph >= 10 and airbrake * 0.3 or 0
  RailWorks.SetControlValue("DynamicBrake", 0, dynbrake)

  RailWorks.SetControlValue("AWSWarnCount", 0,
                            Misc.intbool(alerter:isalarm() or adu:isalarm()))

  -- Quick and dirty way to execute only when the sound starts to play.
  local adualert = adu:isalertplaying()
  if not adualertplaying and adualert then
    RailWorks.SetControlValue("AWSClearCount", 0, Misc.intbool(
                                RailWorks.GetControlValue("AWSClearCount", 0) ==
                                  0))
  end
  adualertplaying = adualert
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
  local frontup = false
  local rearup = true
  frontpantoanim:setanimatedstate(frontup)
  rearpantoanim:setanimatedstate(rearup)
end

local function setslavepantos()
  -- We assume the helper engine is flipped.
  if raisefrontpantomsg ~= nil then
    rearpantoanim:setanimatedstate(raisefrontpantomsg)
  end
  if raiserearpantomsg ~= nil then
    frontpantoanim:setanimatedstate(raiserearpantomsg)
  end
end

local function setpantosparks()
  local frontcontact = frontpantoanim:getposition() == 1
  local rearcontact = rearpantoanim:getposition() == 1
  local isspark = power:haspower() and (frontcontact or rearcontact) and
                    spark:isspark()

  RailWorks.ActivateNode("Front_spark01", frontcontact and isspark)
  RailWorks.ActivateNode("Front_spark02", frontcontact and isspark)
  Call("Spark:Activate", Misc.intbool(frontcontact and isspark))

  RailWorks.ActivateNode("Rear_spark01", rearcontact and isspark)
  RailWorks.ActivateNode("Rear_spark02", rearcontact and isspark)
  Call("Spark2:Activate", Misc.intbool(rearcontact and isspark))
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

local function setplayerdest()
  local selected = destscroller:getselected()
  local _, id = unpack(destinations[selected])
  if RailWorks.GetControlValue("DestOnOff", 0) == 1 then
    RailWorks.Engine_SendConsistMessage(messageid.destination, id, 0)
    RailWorks.Engine_SendConsistMessage(messageid.destination, id, 1)
  else
    RailWorks.Engine_SendConsistMessage(messageid.destination, 0, 0)
    RailWorks.Engine_SendConsistMessage(messageid.destination, 0, 1)
  end
end

local function setaidest()
  RailWorks.Engine_SendConsistMessage(messageid.destination, 1, 0)
  RailWorks.Engine_SendConsistMessage(messageid.destination, 1, 1)
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

  local headlights = RailWorks.GetControlValue("Headlights", 0)
  local lights
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
  RailWorks.SetControlValue("LightsIndicator", 0, lights)

  tracteffort:sample(RailWorks.GetTractiveEffort() * 300)
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
  local pstate = cruiseon and 8 or
                   math.floor(
                     RailWorks.GetControlValue("VirtualThrottle", 0) * 6 + 0.5)
  RailWorks.SetControlValue("PowerState", 0, pstate)
end

local function setcutin()
  -- Reverse the polarities so that safety systems are on by default.
  adu:setatcstate(RailWorks.GetControlValue("ATCCutIn", 0) == 0)
  adu:setacsesstate(RailWorks.GetControlValue("ACSESCutIn", 0) == 0)
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

  -- If we set the digits too early, they flicker (or turn invisible) for the
  -- rest of the game.
  if Misc.isinitialized() then
    local signalspeed_mph = adu:getsignalspeed_mph()
    if signalspeed_mph == nil then
      RailWorks.SetControlValue("SignalSpeed", 0, 1) -- blank
    else
      RailWorks.SetControlValue("SignalSpeed", 0, signalspeed_mph)
    end
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

  RailWorks.SetControlValue("MaximumSpeedLimitIndicator", 0,
                            adu:getsquareindicator())
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
  RailWorks.ActivateNode("LeftOn", showleft)
  RailWorks.ActivateNode("DitchLightsL", showleft)
  Call("DitchLightLeft:Activate", Misc.intbool(showleft))

  local showright = fixed or (flash and not flashleft)
  RailWorks.ActivateNode("RightOn", showright)
  RailWorks.ActivateNode("DitchLightsR", showright)
  Call("DitchLightRight:Activate", Misc.intbool(showright))
end

local function updateplayer(dt)
  adu:update(dt)
  cruise:update(dt)
  alerter:update(dt)
  power:update(dt)
  blight:playerupdate(dt)
  frontpantoanim:update(dt)
  rearpantoanim:update(dt)
  coneanim:update(dt)
  destscroller:update(dt)

  setplayercontrols()
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
  setaidest()
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

  if message == messageid.raisefrontpanto then
    raisefrontpantomsg = argument == "true"
  elseif message == messageid.raiserearpanto then
    raiserearpantomsg = argument == "true"
  end

  RailWorks.Engine_SendConsistMessage(message, argument, direction)
end)
