-- Engine script for the Comet V operated by New Jersey Transit.
-- @include RollingStock/Doors.lua
-- @include SafetySystems/Acses/Acses.lua
-- @include SafetySystems/AspectDisplay/NjTransitDigital.lua
-- @include SafetySystems/Alerter.lua
-- @include SafetySystems/Atc.lua
-- @include Animation.lua
-- @include Flash.lua
-- @include Iterator.lua
-- @include MovingAverage.lua
-- @include RailWorks.lua
-- @include Scheduler.lua
-- @include Units.lua
local playersched
local anysched
local atc
local acses
local adu
local alerter
local doors
local leftdoorsanim
local rightdoorsanim
local ditchflasher
local state = {
  throttle = 0,
  train_brake = 0,
  acknowledge = false,
  destination = 1,
  crosslights = 0,

  speed_mps = 0,
  acceleration_mps2 = 0,
  trackspeed_mps = 0,
  consistlength_m = 0,
  speedlimits = {},
  restrictsignals = {},

  lasthorntime_s = nil
}

local destinations = {
  "Dest_Trenton",
  "Dest_NewYork",
  "Dest_LongBranch",
  "Dest_Hoboken",
  "Dest_Dover",
  "Dest_BayHead"
}

local function getrvdestination()
  local id = string.sub(RailWorks.GetRVNumber(), 1, 1)
  local index = string.byte(id)
  if index == nil then
    return 1
  else
    return index - string.byte("A") + 1
  end
end

local function getrvnumber()
  local id = tonumber(string.sub(RailWorks.GetRVNumber(), 2))
  if id == nil then
    return 1234
  else
    return id
  end
end

local function getdigit(v, place)
  local tens = math.pow(10, place)
  if place ~= 0 and v < tens then
    return -1
  else
    return math.floor(math.mod(v, tens * 10) / tens)
  end
end

Initialise = RailWorks.wraperrors(function()
  playersched = Scheduler:new{}
  anysched = Scheduler:new{}

  atc = Atc:new{
    scheduler = playersched,
    getspeed_mps = function() return state.speed_mps end,
    getacceleration_mps2 = function() return state.acceleration_mps2 end,
    getacknowledge = function() return state.acknowledge end,
    doalert = function() adu:doatcalert() end,
    getbrakesuppression = function() return state.train_brake >= 0.6 end
  }

  acses = Acses:new{
    scheduler = playersched,
    getspeed_mps = function() return state.speed_mps end,
    gettrackspeed_mps = function() return state.trackspeed_mps end,
    getconsistlength_m = function() return state.consistlength_m end,
    iterspeedlimits = function() return pairs(state.speedlimits) end,
    iterrestrictsignals = function() return pairs(state.restrictsignals) end,
    getacknowledge = function() return state.acknowledge end,
    doalert = function() adu:doacsesalert() end,
    consistspeed_mps = 100 * Units.mph.tomps
  }

  local onebeep_s = 1
  adu = NjTransitDigitalAdu:new{
    scheduler = playersched,
    atc = atc,
    atcalert_s = onebeep_s,
    acses = acses,
    acsesalert_s = onebeep_s
  }

  atc:start()
  acses:start()

  local doors_s = 2
  leftdoorsanim = Animation:new{
    scheduler = anysched,
    animation = "Doors_L",
    duration_s = doors_s
  }
  rightdoorsanim = Animation:new{
    scheduler = anysched,
    animation = "Doors_R",
    duration_s = doors_s
  }
  doors = Doors:new{
    scheduler = anysched,
    leftanimation = leftdoorsanim,
    rightanimation = rightdoorsanim
  }

  alerter = Alerter:new{
    scheduler = playersched,
    getspeed_mps = function() return state.speed_mps end
  }
  alerter:start()

  local ditchflash_s = 1
  ditchflasher = Flash:new{
    scheduler = playersched,
    off_s = ditchflash_s,
    on_s = ditchflash_s
  }

  do
    local rvn = getrvnumber()
    RailWorks.SetControlValue("UN_thousands", 0, getdigit(rvn, 3))
    RailWorks.SetControlValue("UN_hundreds", 0, getdigit(rvn, 2))
    RailWorks.SetControlValue("UN_tens", 0, getdigit(rvn, 1))
    RailWorks.SetControlValue("UN_units", 0, getdigit(rvn, 0))
  end
  state.destination = getrvdestination()

  RailWorks.BeginUpdate()
end)

local function readcontrols()
  local throttle = RailWorks.GetControlValue("ThrottleAndBrake", 0)
  local vbrake = RailWorks.GetControlValue("VirtualBrake", 0)
  local change = throttle ~= state.throttle or vbrake ~= state.train_brake
  state.throttle = throttle
  state.train_brake = vbrake
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) == 1
  if state.acknowledge or change then alerter:acknowledge() end
  state.crosslights = RailWorks.GetControlValue("DitchLightSwitch", 0)

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
  state.speedlimits = Iterator.totable(RailWorks.iterspeedlimits(
                                         Acses.nlimitlookahead))
  state.restrictsignals = Iterator.totable(
                            RailWorks.iterrestrictsignals(Acses.nsignallookahead))
end

local function writelocostate()
  local penalty = alerter:ispenalty() or atc:ispenalty() or acses:ispenalty()
  do
    local throttle = penalty and 0 or math.max(state.throttle, 0)
    RailWorks.SetControlValue("Regulator", 0, throttle)
    local dynbrake = penalty and 0 or math.max(-state.throttle, 0)
    RailWorks.SetControlValue("DynamicBrake", 0, dynbrake)
  end
  do
    local v
    if penalty then
      v = 0.6
    else
      v = state.train_brake
    end
    RailWorks.SetControlValue("TrainBrakeControl", 0, v)
  end

  RailWorks.SetControlValue("Reverser", 0,
                            RailWorks.GetControlValue("UserVirtualReverser", 0))
  RailWorks.SetControlValue("Horn", 0,
                            RailWorks.GetControlValue("VirtualHorn", 0))
  RailWorks.SetControlValue("Bell", 0,
                            RailWorks.GetControlValue("VirtualBell", 0))
  RailWorks.SetControlValue("Wipers", 0,
                            RailWorks.GetControlValue("VirtualWipers", 0))
  RailWorks.SetControlValue("Sander", 0,
                            RailWorks.GetControlValue("VirtualSander", 0))
  RailWorks.SetControlValue("PantographControl", 0, RailWorks.GetControlValue(
                              "VirtualPantographControl", 0))

  do
    local alarm = atc:isalarm() or acses:isalarm() or alerter:isalarm()
    local alert = adu:isatcalert() or adu:isacsesalert()
    RailWorks.SetControlValue("AWS", 0, RailWorks.frombool(alarm or alert))
    RailWorks.SetControlValue("AWSWarnCount", 0, RailWorks.frombool(alarm))
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

local function setspeedometer()
  do
    local restrict = adu:isspeedrestriction()
    local rspeed_mph = toroundedmph(math.abs(state.speed_mps))
    local h = getdigit(rspeed_mph, 2)
    local t = getdigit(rspeed_mph, 1)
    local u = getdigit(rspeed_mph, 0)
    RailWorks.SetControlValue("SpeedH", 0, restrict and -1 or h)
    RailWorks.SetControlValue("SpeedT", 0, restrict and -1 or t)
    RailWorks.SetControlValue("SpeedU", 0, restrict and -1 or u)
    RailWorks.SetControlValue("Speed2H", 0, restrict and h or -1)
    RailWorks.SetControlValue("Speed2T", 0, restrict and t or -1)
    RailWorks.SetControlValue("Speed2U", 0, restrict and u or -1)
    RailWorks.SetControlValue("SpeedP", 0, getdigitguide(rspeed_mph))
  end

  RailWorks.SetControlValue("ACSES_SpeedGreen", 0,
                            adu:getgreenzone_mph(state.speed_mps))
  RailWorks.SetControlValue("ACSES_SpeedRed", 0,
                            adu:getredzone_mph(state.speed_mps))

  RailWorks.SetControlValue("ATC_Node", 0, RailWorks.frombool(atc:isalarm()))
  RailWorks.SetControlValue("ACSES_Node", 0, RailWorks.frombool(acses:isalarm()))
end

local function setcablight()
  local dome = RailWorks.GetControlValue("CabLight", 0)
  RailWorks.ActivateNode("cablights", dome == 1)
  Call("CabLight:Activate", dome)
  Call("CabLight2:Activate", dome)
end

local function setditchlights()
  local horntime_s = 30
  local flash = state.lasthorntime_s ~= nil and playersched:clock() <=
                  state.lasthorntime_s + horntime_s and state.crosslights == 2
  local fixed = RailWorks.GetControlValue("HeadlightSwitch", 0) >= 1 and
                  state.crosslights == 1 and not flash
  ditchflasher:setflashstate(flash)
  local flashleft = ditchflasher:ison()
  do
    local showleft = fixed or (flash and flashleft)
    RailWorks.ActivateNode("ditch_left", showleft)
    Call("Ditch_L:Activate", RailWorks.frombool(showleft))
  end
  do
    local showright = fixed or (flash and not flashleft)
    RailWorks.ActivateNode("ditch_right", showright)
    Call("Ditch_R:Activate", RailWorks.frombool(showright))
  end
end

local function setstatuslights()
  RailWorks.ActivateNode("LightsBlue", RailWorks.GetIsEngineWithKey())
  RailWorks.ActivateNode("LightsRed",
                         doors:isleftdooropen() or doors:isrightdooropen())
  do
    -- Match the brake indicator light logic in the carriage script.
    local brake = RailWorks.GetControlValue("TrainBrakeControl", 0)
    RailWorks.ActivateNode("LightsYellow", brake > 0)
    RailWorks.ActivateNode("LightsGreen", brake <= 0)
  end
end

local function setdestination()
  local valid = state.destination >= 1 and state.destination <=
                  table.getn(destinations)
  for i, node in ipairs(destinations) do
    if valid then
      RailWorks.ActivateNode(node, i == state.destination)
    else
      RailWorks.ActivateNode(node, i == 1)
    end
  end
end

local function updateplayer()
  readcontrols()
  readlocostate()

  playersched:update()
  anysched:update()

  leftdoorsanim:update()
  rightdoorsanim:update()
  doors:update()

  writelocostate()
  setspeedometer()
  setcablight()
  setditchlights()
  setstatuslights()
  setdestination()

  -- Prevent the acknowledge button from sticking if the button on the HUD is
  -- clicked.
  if state.acknowledge then RailWorks.SetControlValue("AWSReset", 0, 0) end
end

local function updateai()
  anysched:update()

  leftdoorsanim:update()
  rightdoorsanim:update()
  doors:update()

  setcablight()
  setditchlights()
  setstatuslights()
  setdestination()
end

Update = RailWorks.wraperrors(function(_)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer()
  else
    updateai()
  end
end)

OnControlValueChange = RailWorks.wraperrors(
                         function(name, index, value)
    -- Synchronize headlight controls.
    if name == "HeadlightSwitch" then
      if value == 0 then
        RailWorks.SetControlValue("Headlights", 0, 0)
      elseif value == 1 then
        RailWorks.SetControlValue("Headlights", 0, 2)
      elseif value == 2 then
        RailWorks.SetControlValue("Headlights", 0, 3)
      end
    elseif name == "Headlights" then
      if value == 0 or value == 1 then
        RailWorks.SetControlValue("HeadlightSwitch", 0, 0)
      elseif value == 2 then
        RailWorks.SetControlValue("HeadlightSwitch", 0, 1)
      elseif value == 3 then
        RailWorks.SetControlValue("HeadlightSwitch", 0, 2)
      end
    end

    -- Synchronize pantograph controls.
    if name == "PantographSwitch" then
      if value == -1 then
        RailWorks.SetControlValue("VirtualPantographControl", 0, 0)
      elseif value == 1 then
        RailWorks.SetControlValue("VirtualPantographControl", 0, 1)
      end
    elseif name == "VirtualPantographControl" then
      if value == 0 then
        RailWorks.SetControlValue("PantographSwitch", 0, -1)
      elseif value == 1 then
        RailWorks.SetControlValue("PantographSwitch", 0, 1)
      end
    end

    -- Synchronize ditch light controls.
    if name == "DitchLightSwitch" then
      if value == 0 or value == 2 then
        RailWorks.SetControlValue("DitchLights", 0, 0)
      elseif value == 1 then
        RailWorks.SetControlValue("DitchLights", 0, 1)
      end
    elseif name == "DitchLights" then
      if value == 0 then
        RailWorks.SetControlValue("DitchLightSwitch", 0, 2)
      elseif value == 1 then
        RailWorks.SetControlValue("DitchLightSwitch", 0, 1)
      end
    end

    -- Read the selected destination only when the player changes it.
    if name == "Destination" and not playersched:isstartup() then
      state.destination = math.floor(value + 0.5) - 1
    end

    RailWorks.SetControlValue(name, index, value)
  end)

OnCustomSignalMessage = RailWorks.wraperrors(function(message)
  atc:receivemessage(message)
  acses:receivemessage(message)
end)

OnConsistMessage = RailWorks.Engine_SendConsistMessage
