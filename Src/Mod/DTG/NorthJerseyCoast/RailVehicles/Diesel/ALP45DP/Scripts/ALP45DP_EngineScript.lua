-- Engine script for the dual-power ALP-45DP operated by New Jersey Transit.
-- @include RollingStock/Doors.lua
-- @include RollingStock/Power.lua
-- @include SafetySystems/Acses/Acses.lua
-- @include SafetySystems/AspectDisplay/NjTransit.lua
-- @include SafetySystems/Alerter.lua
-- @include SafetySystems/Atc.lua
-- @include Signals/CabSignal.lua
-- @include Animation.lua
-- @include Flash.lua
-- @include Misc.lua
-- @include RailWorks.lua
-- @include Scheduler.lua
-- @include Units.lua
local powermode = {init = -1, diesel = 0, overhead = 1}
local messageid = {destination = 10100}
local dieselpower = 3600 / 5900
local stopped_mps = 0.01

local playersched, anysched
local cabsig
local atc
local acses
local adu
local alerter
local power
local pantoanim
local doors
local ditchflasher
local decreaseonoff
local state = {
  throttle = 0,
  train_brake = 0,
  acknowledge = false,
  powermode = powermode.init,
  pantocmd = false,
  rv_destination = nil,

  speed_mps = 0,
  acceleration_mps2 = 0,
  trackspeed_mps = 0,
  consistlength_m = 0,
  speedlimits = {},
  restrictsignals = {},

  lasthorntime_s = nil,
  lastwipertime_s = nil
}

local function readrvnumber()
  local _, _, deststr, unitstr = string.find(RailWorks.GetRVNumber(),
                                             "(%a)(%d+)")
  local dest, unit
  if deststr ~= nil then
    dest = string.byte(string.upper(deststr)) - string.byte("A") + 1
    unit = tonumber(unitstr)
  else
    dest = nil
    unit = 4500
  end
  state.rv_destination = dest
  RailWorks.SetControlValue("UnitT", 0, Misc.getdigit(unit, 1))
  RailWorks.SetControlValue("UnitU", 0, Misc.getdigit(unit, 0))
end

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
    getbrakesuppression = function() return state.train_brake >= 0.6 end
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
    consistspeed_mps = 100 * Units.mph.tomps
  }

  local onebeep_s = 1
  adu = NjTransitAdu:new{
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

  power = Power:new{
    scheduler = anysched,
    available = {},
    modes = {
      [powermode.init] = function(connected) return false end,
      [powermode.diesel] = function(connected) return true end,
      [powermode.overhead] = function(connected)
        return connected[Power.supply.overhead] and pantoanim:getposition() == 1
      end
    },
    init_mode = powermode.init,
    transition_s = 100,
    getcantransition = function()
      return state.throttle <= 0 and state.speed_mps < stopped_mps
    end,
    getselectedmode = function() return state.powermode end,
    selectaimode = function(cp)
      if cp == Power.changepoint.ai_to_overhead then
        return powermode.electric
      elseif cp == Power.changepoint.ai_to_diesel then
        return powermode.diesel
      else
        return nil
      end
    end
  }

  pantoanim = Animation:new{
    scheduler = anysched,
    animation = "Pantograph",
    duration_s = 2
  }

  doors = Doors:new{scheduler = anysched}

  local ditchflash_s = 1
  ditchflasher = Flash:new{
    scheduler = playersched,
    off_s = ditchflash_s,
    on_s = ditchflash_s
  }

  -- Modulate the speed reduction alert sound, which normally plays just once.
  decreaseonoff = Flash:new{scheduler = playersched, off_s = 0.1, on_s = 0.5}

  readrvnumber()
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

  if RailWorks.GetControlValue("Horn", 0) > 0 then
    state.lasthorntime_s = playersched:clock()
  end

  local pantocmd = RailWorks.GetControlValue("PantographSwitch", 0)
  if pantocmd == -1 then
    state.pantocmd = false
  elseif pantocmd == 1 then
    state.pantocmd = true
  end

  local faultreset = RailWorks.GetControlValue("FaultReset", 0) == 1
  if power:gettransition() == nil then
    if state.powermode == powermode.diesel and state.pantocmd then
      state.powermode = powermode.overhead
    elseif state.powermode == powermode.overhead and faultreset then
      state.powermode = powermode.diesel
    end
  end
  if faultreset then RailWorks.SetControlValue("FaultReset", 0, 0) end
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
  local throttle, proportion
  if penalty or not haspower then
    throttle = 0
  else
    throttle = math.max(state.throttle, 0)
  end
  if not haspower then
    proportion = 0
  elseif power:getmode() == powermode.diesel then
    proportion = dieselpower
  else
    proportion = 1
  end
  RailWorks.SetControlValue("Regulator", 0, throttle)
  RailWorks.SetControlValue("TrainBrakeControl", 0,
                            penalty and 0.6 or state.train_brake)
  RailWorks.SetPowerProportion(-1, proportion)

  local psi = RailWorks.GetControlValue("AirBrakePipePressurePSI", 0)
  local dynbrake = math.min((110 - psi) / 16, 1)
  local dynthrottle = -math.min(state.throttle, 0)
  RailWorks.SetControlValue("DynamicBrake", 0, math.max(dynbrake, dynthrottle))

  local sander = RailWorks.GetControlValue("VirtualSander", 0)
  RailWorks.SetControlValue("Sander", 0, sander)
  RailWorks.SetControlValue("SanderSwitch", 0, sander)

  local bell = RailWorks.GetControlValue("VirtualBell", 0)
  RailWorks.SetControlValue("Bell", 0, bell)
  RailWorks.SetControlValue("BellSwitch", 0, bell)

  local handbrake = RailWorks.GetControlValue("HandBrakeSwitch", 0)
  if handbrake == 1 then
    RailWorks.SetControlValue("HandBrake", 0, 1)
  elseif handbrake == -1 then
    RailWorks.SetControlValue("HandBrake", 0, 0)
  end

  local vigilalarm = alerter:isalarm()
  local safetyalarm = atc:isalarm() or acses:isalarm()
  local safetyalert = adu:isatcalert() or adu:isacsesalert()
  RailWorks.SetControlValue("AWSWarnCount", 0,
                            Misc.intbool(vigilalarm or safetyalarm))
  RailWorks.SetControlValue("ACSES_Alert", 0, Misc.intbool(vigilalarm))
  decreaseonoff:setflashstate(safetyalarm)
  RailWorks.SetControlValue("ACSES_AlertDecrease", 0,
                            Misc.intbool(decreaseonoff:ison()))
  RailWorks.SetControlValue("ACSES_AlertIncrease", 0, Misc.intbool(safetyalert))

  RailWorks.SetControlValue("Horn", 0,
                            RailWorks.GetControlValue("VirtualHorn", 0))
end

local function setpowermode()
  local exhaust, dieselrpm, raisepanto
  if state.powermode == powermode.init then
    -- The PowerMode control takes some time to settle, so read it after
    -- startup.
    if not anysched:isstartup() then
      state.powermode = math.floor(tonumber(
                                     RailWorks.GetControlValue("PowerMode", 0)))
      power:setmode(state.powermode)
      if state.powermode == powermode.overhead then
        power:setavailable(Power.supply.overhead)
        pantoanim:setanimatedstate(true)
        pantoanim:setposition(1)
        state.pantocmd = true
      else
        power:setavailable()
        pantoanim:setanimatedstate(false)
        pantoanim:setposition(0)
        state.pantocmd = false
      end
    end
    exhaust = false
    dieselrpm = 0
    raisepanto = false
  else
    local before, after, remaining_s = power:gettransition()
    local rpm = RailWorks.GetControlValue("RPM", 0)
    if before == powermode.overhead and after == powermode.diesel then
      exhaust = remaining_s <= 30
      dieselrpm = remaining_s <= 60 and rpm or 0
      -- Lower the pantograph at the end of the transition to diesel.
      if remaining_s <= 2 then state.pantocmd = false end
      raisepanto = state.pantocmd
    elseif before == powermode.diesel and after == powermode.overhead then
      exhaust = remaining_s > 60
      dieselrpm = remaining_s > 30 and rpm or 0
      raisepanto = state.pantocmd
    else
      -- normal operation
      local iselectric = power:getmode() == powermode.overhead
      exhaust = not iselectric
      dieselrpm = iselectric and 0 or rpm
      raisepanto = state.pantocmd
    end
    -- Publish the current power mode via PantographControl...
    RailWorks.SetControlValue("PantographControl", 0, state.powermode)
    -- ...and the current pantograph position via VirtualPantographControl.
    RailWorks.SetControlValue("VirtualPantographControl", 0,
                              Misc.intbool(raisepanto))
  end
  Call("Exhaust1:SetEmitterActive", Misc.intbool(exhaust))
  Call("Exhaust2:SetEmitterActive", Misc.intbool(exhaust))
  Call("Exhaust3:SetEmitterActive", Misc.intbool(exhaust))
  Call("Exhaust4:SetEmitterActive", Misc.intbool(exhaust))
  RailWorks.SetControlValue("VirtualRPM", 0, dieselrpm)
  pantoanim:setanimatedstate(raisepanto)
end

local function setspeedometer()
  local rspeed_mph = Misc.round(math.abs(state.speed_mps) * Units.mps.tomph)
  RailWorks.SetControlValue("SpeedH", 0, Misc.getdigit(rspeed_mph, 2))
  RailWorks.SetControlValue("SpeedT", 0, Misc.getdigit(rspeed_mph, 1))
  RailWorks.SetControlValue("SpeedU", 0, Misc.getdigit(rspeed_mph, 0))

  local aduspeed_mph = adu:getcivilcurvespeed_mph()
  if aduspeed_mph ~= nil then
    RailWorks.SetControlValue("ACSES_SpeedH", 0, Misc.getdigit(aduspeed_mph, 2))
    RailWorks.SetControlValue("ACSES_SpeedT", 0, Misc.getdigit(aduspeed_mph, 1))
    RailWorks.SetControlValue("ACSES_SpeedU", 0, Misc.getdigit(aduspeed_mph, 0))
  else
    RailWorks.SetControlValue("ACSES_SpeedH", 0, -1)
    RailWorks.SetControlValue("ACSES_SpeedT", 0, -1)
    RailWorks.SetControlValue("ACSES_SpeedU", 0, -1)
  end

  local atccode = atc:getpulsecode()
  local acsesmode = acses:getmode()
  local sig
  if acsesmode == Acses.mode.positivestop then
    sig = 8
  elseif acsesmode == Acses.mode.approachmed30 then
    sig = 5
  elseif atccode == Nec.pulsecode.restrict then
    sig = 7
  elseif atccode == Nec.pulsecode.approach then
    sig = 6
  elseif atccode == Nec.pulsecode.approachmed then
    sig = 4
  elseif atccode == Nec.pulsecode.cabspeed60 then
    sig = 3
  elseif atccode == Nec.pulsecode.cabspeed80 then
    sig = 2
  else
    sig = 1
  end
  RailWorks.SetControlValue("ACSES_SignalDisplay", 0, sig)

  RailWorks.SetControlValue("ATC_Node", 0, Misc.intbool(atc:isalarm()))
  RailWorks.SetControlValue("ATC_CutOut", 0, Misc.intbool(not atc:isrunning()))
  RailWorks.SetControlValue("ACSES_Node", 0, Misc.intbool(acses:isalarm()))
  local acseson = acses:isrunning()
  RailWorks.SetControlValue("ACSES_CutIn", 0, Misc.intbool(acseson))
  RailWorks.SetControlValue("ACSES_CutOut", 0, Misc.intbool(not acseson))
end

local function setcutin()
  -- Reverse the polarities so that safety systems are on by default.
  -- ACSES and ATC shortcuts are reversed on NJT stock.
  atc:setrunstate(RailWorks.GetControlValue("ACSES", 0) == 0)
  acses:setrunstate(RailWorks.GetControlValue("ATC", 0) == 0)
end

local function sethep()
  -- TODO: Impose startup delay?
  RailWorks.SetControlValue("HEP_State", 0, RailWorks.GetControlValue("HEP", 0))
end

local function setcablights()
  local dome = RailWorks.GetControlValue("CabLight", 0)
  RailWorks.SetControlValue("CabLightSwitch", 0, dome)
  Call("CabLight:Activate", dome)

  local desk = RailWorks.GetControlValue("DeskLight", 0)
  RailWorks.SetControlValue("DeskLightSwitch", 0, desk)
  Call("DeskLight:Activate", desk)

  RailWorks.SetControlValue("InstrumentLightsSwitch", 0,
                            RailWorks.GetControlValue("InstrumentLights", 0))
end

local function setditchlights()
  local horntime_s = 30

  local ditchcontrol = RailWorks.GetControlValue("DitchLights", 0)
  RailWorks.SetControlValue("DitchLightsSwitch", 0, ditchcontrol)

  local flash = state.lasthorntime_s ~= nil and playersched:clock() <=
                  state.lasthorntime_s + horntime_s
  local fixed = ditchcontrol == 1 and not flash
  ditchflasher:setflashstate(flash)
  local flashleft = ditchflasher:ison()

  local showleft = fixed or (flash and flashleft)
  RailWorks.ActivateNode("ditch_left", showleft)
  Call("DitchLight_Left:Activate", Misc.intbool(showleft))

  local showright = fixed or (flash and not flashleft)
  RailWorks.ActivateNode("ditch_right", showright)
  Call("DitchLight_Right:Activate", Misc.intbool(showright))
end

local function setstatuslights()
  RailWorks.ActivateNode("LightsBlue", RailWorks.GetIsEngineWithKey())
  RailWorks.ActivateNode("LightsRed",
                         doors:isleftdooropen() or doors:isrightdooropen())

  -- Match the brake indicator light logic in the carriage script.
  local brake = RailWorks.GetControlValue("TrainBrakeControl", 0)
  RailWorks.ActivateNode("LightsYellow", brake > 0)
  RailWorks.ActivateNode("LightsGreen", brake <= 0)
end

local function setwipers()
  local intwipetime_s = 3
  local wiperon = RailWorks.GetControlValue("VirtualWipers", 0) == 1
  local wiperint = RailWorks.GetControlValue("WipersInt", 0) == 1
  RailWorks.SetControlValue("WipersSwitch", 0,
                            wiperon and (wiperint and -1 or 1) or 0)
  local wipe
  if wiperint then
    if wiperon then
      local now = playersched:clock()
      if state.lastwipertime_s == nil or now - state.lastwipertime_s >=
        intwipetime_s then
        wipe = true
        state.lastwipertime_s = now
      else
        wipe = false
      end
    else
      wipe = false
      state.lastwipertime_s = nil
    end
  else
    wipe = wiperon
  end
  RailWorks.SetControlValue("Wipers", 0, Misc.intbool(wipe))
end

local function setebrake()
  local stopspeed_mps = 0.01
  if RailWorks.GetControlValue("VirtualEmergencyBrake", 0) == 1 then
    RailWorks.SetControlValue("EmergencyBrake", 0, 1)
  elseif math.abs(state.speed_mps) < stopspeed_mps then
    RailWorks.SetControlValue("EmergencyBrake", 0, 0)
  end
end

local function setdestination()
  -- Broadcast the rail vehicle-derived destination, if any.
  if state.rv_destination ~= nil and anysched:isstartup() then
    RailWorks.Engine_SendConsistMessage(messageid.destination,
                                        state.rv_destination, 0)
    RailWorks.Engine_SendConsistMessage(messageid.destination,
                                        state.rv_destination, 1)
  end
end

local function updateplayer()
  readcontrols()
  readlocostate()

  playersched:update()
  anysched:update()

  pantoanim:update()
  doors:update()

  writelocostate()
  setpowermode()
  setspeedometer()
  setcutin()
  sethep()
  setcablights()
  setditchlights()
  setstatuslights()
  setwipers()
  setebrake()
  setdestination()
end

local function updateai()
  anysched:update()

  pantoanim:update()

  setpowermode()
  setcablights()
  setditchlights()
  setstatuslights()
  setdestination()
end

Update = Misc.wraperrors(function(_)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer()
  else
    updateai()
  end
end)

OnControlValueChange = Misc.wraperrors(function(name, index, value)
  -- Synchronize headlight controls.
  if name == "HeadlightSwitch" then
    if value == -1 then
      RailWorks.SetControlValue("Headlights", 0, 2)
    elseif value == 0 then
      RailWorks.SetControlValue("Headlights", 0, 0)
    elseif value == 1 then
      RailWorks.SetControlValue("Headlights", 0, 1)
    end
  elseif name == "Headlights" then
    if value == 0 then
      RailWorks.SetControlValue("HeadlightSwitch", 0, 0)
    elseif value == 1 then
      RailWorks.SetControlValue("HeadlightSwitch", 0, 1)
    elseif value == 2 then
      RailWorks.SetControlValue("HeadlightSwitch", 0, -1)
    end
  end

  -- The player has changed the destination sign.
  if name == "Destination" and not anysched:isstartup() then
    RailWorks.Engine_SendConsistMessage(messageid.destination, value, 0)
    RailWorks.Engine_SendConsistMessage(messageid.destination, value, 1)
  end

  RailWorks.SetControlValue(name, index, value)
end)

OnCustomSignalMessage = Misc.wraperrors(function(message)
  power:receiveplayermessage(message)
  cabsig:receivemessage(message)
end)

OnConsistMessage = RailWorks.Engine_SendConsistMessage
