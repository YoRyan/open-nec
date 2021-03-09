-- Engine script for the EMD AEM-7 operated by Amtrak.

sched = nil
atc = nil
acses = nil
cruise = nil
alerter = nil
power = nil
state = {
  throttle=0,
  train_brake=0,
  acknowledge=false,
  cruisespeed_mps=0,
  cruiseenabled=false,

  speed_mps=0,
  acceleration_mps2=0,
  trackspeed_mps=0,
  forwardspeedlimits={},
  backwardspeedlimits={},
  forwardrestrictsignals={},
  backwardrestrictsignals={},

  event_alert=nil,
  beep_alert=false,
  cs1flash=0, -- 0 = off, 1 = on, 2 = flash
  cs1light=false
}
onebeep_s = 0.3

Initialise = RailWorks.wraperrors(function ()
  sched = Scheduler:new{}
  do
    local newatc = Atc.new(sched)
    local config = newatc.config
    config.getspeed_mps =
      function () return state.speed_mps end
    config.getacceleration_mps2 =
      function () return state.acceleration_mps2 end
    config.getacknowledge =
      function () return state.acknowledge end
    config.doalert =
      function () state.event_alert:trigger() end
    atc = newatc
    atc:start()
  end
  do
    local newacses = Acses.new(sched, atc)
    local config = newacses.config
    config.getspeed_mps =
      function () return state.speed_mps end
    config.gettrackspeed_mps =
      function () return state.trackspeed_mps end
    config.iterforwardspeedlimits =
      function () return ipairs(state.forwardspeedlimits) end
    config.iterbackwardspeedlimits =
      function () return ipairs(state.backwardspeedlimits) end
    config.iterforwardrestrictsignals =
      function () return ipairs(state.forwardrestrictsignals) end
    config.iterbackwardrestrictsignals =
      function () return ipairs(state.backwardrestrictsignals) end
    config.getacknowledge =
      function () return state.acknowledge end
    config.doalert =
      function () state.event_alert:trigger() end
    acses = newacses
    acses:start()
  end
  cruise = Cruise:new{
    scheduler = sched,
    getspeed_mps = function () return state.speed_mps end,
    gettargetspeed_mps = function () return state.cruisespeed_mps end,
    getenabled = function () return state.cruiseenabled end
  }

  alerter = Alerter:new{
    scheduler = sched,
    getspeed_mps = function () return state.speed_mps end
  }
  alerter:start()

  power = Power:new{available={Power.types.overhead}}
  state.event_alert = Event:new{scheduler=sched}
  sched:run(doalerts)
  sched:run(cs1flasher)
  RailWorks.BeginUpdate()
end)

-- Play a beep sound when alerts sound.
function doalerts ()
  while true do
    state.event_alert:waitfor()
    state.beep_alert = true
    sched:sleep(onebeep_s)
    state.beep_alert = false
  end
end

-- Flash the upper green head to show a cab speed aspect.
function cs1flasher ()
  local waitchange = function (timeout)
    local start = state.cs1flash
    return sched:select(timeout, function () return state.cs1flash ~= start end)
  end
  while true do
    if state.cs1flash == 0 then
      state.cs1light = false
      waitchange()
    elseif state.cs1flash == 1 then
      state.cs1light = true
      waitchange()
    elseif state.cs1flash == 2 then
      local change
      repeat
        state.cs1light = not state.cs1light
        change = waitchange(Atc.cabspeedflash_s)
      until change ~= nil
    else
      waitchange() -- invalid value
    end
  end
end

Update = RailWorks.wraperrors(function (dt)
  if not RailWorks.GetIsEngineWithKey() then
    RailWorks.EndUpdate()
    return
  end

  do
    local vthrottle = RailWorks.GetControlValue("VirtualThrottle", 0)
    local vbrake = RailWorks.GetControlValue("VirtualBrake", 0)
    local change = vthrottle ~= state.throttle or vbrake ~= state.train_brake
    state.throttle = vthrottle
    state.train_brake = vbrake
    state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) == 1
    if state.acknowledge or change then
      alerter:acknowledge()
    end
  end

  -- Reverse the polarities of the safety systems buttons so they are activated
  -- by default.
  alerter:setrunstate(RailWorks.GetControlValue("AlertControl", 0) == 0)
  do
    local speedcontrol = RailWorks.GetControlValue("SpeedControl", 0) == 0
    atc:setrunstate(speedcontrol)
    acses:setrunstate(speedcontrol)
  end

  state.cruisespeed_mps = RailWorks.GetControlValue("CruiseSet", 0)*Units.mph.tomps
  state.cruiseenabled = RailWorks.GetControlValue("CruiseSet", 0) > 10
  state.speed_mps = RailWorks.GetSpeed()
  state.acceleration_mps2 = RailWorks.GetAcceleration()
  state.trackspeed_mps = RailWorks.GetCurrentSpeedLimit(1)
  do
    local lookahead = Acses.nlimitlookahead
    state.forwardspeedlimits =
      Iterator.totable(RailWorks.iterforwardspeedlimits(lookahead))
    state.backwardspeedlimits =
      Iterator.totable(RailWorks.iterbackwardspeedlimits(lookahead))
  end
  do
    local lookahead = Acses.nsignallookahead
    state.forwardrestrictsignals =
      Iterator.totable(RailWorks.iterforwardrestrictsignals(lookahead))
    state.backwardrestrictsignals =
      Iterator.totable(RailWorks.iterbackwardrestrictsignals(lookahead))
  end

  sched:update(dt)
  for _, msg in sched:iterinfomessages() do
    RailWorks.showinfo(msg)
  end
  sched:clearinfomessages()
  for _, msg in sched:iteralertmessages() do
    RailWorks.showalert(msg)
  end
  sched:clearalertmessages()

  local penalty = atc:ispenalty() or acses:ispenalty() or alerter:ispenalty()
  do
    local powertypes = {}
    if RailWorks.GetControlValue("PantographControl", 0) == 1 then
      table.insert(powertypes, Power.types.overhead)
    end
    local v
    if not power:haspower(unpack(powertypes)) then
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
    if penalty then v = 0.99
    else v = state.train_brake end
    RailWorks.SetControlValue("TrainBrakeControl", 0, v)
  end
  do
    local v
    if penalty then v = 0.5
    else v = state.train_brake/2 end -- "blended braking"
    RailWorks.SetControlValue("DynamicBrake", 0, v)
  end

  -- Used for the dynamic brake sound?
  RailWorks.SetControlValue(
    "DynamicCurrent", 0, math.abs(RailWorks.GetControlValue("Ammeter", 0)))

  RailWorks.SetControlValue(
    "AWS", 0,
    RailWorks.frombool(atc:isalarm() or acses:isalarm() or alerter:isalarm()))
  RailWorks.SetControlValue(
    "AWSWarnCount", 0,
    RailWorks.frombool(alerter:isalarm()))
  RailWorks.SetControlValue(
    "OverSpeedAlert", 0,
    RailWorks.frombool(state.beep_alert or atc:isalarm() or acses:isalarm()))
  RailWorks.SetControlValue(
    "TrackSpeed", 0,
    math.floor(acses:getinforcespeed_mps()*Units.mps.tomph + 0.5))

  setcabsignal()
  RailWorks.SetControlValue("CabSignal1", 0, RailWorks.frombool(state.cs1light))

  do
    local cablight = RailWorks.GetControlValue("CabLightControl", 0)
    Call("FrontCabLight:Activate", cablight)
    Call("RearCabLight:Activate", cablight)
  end
end)

-- Set the state of the cab signal display.
function setcabsignal ()
  local code = atc:getpulsecode()
  local cs, cs1, cs2
  if code == Atc.pulsecode.restrict then
    cs, cs1, cs2 = 7, 0, 0
  elseif code == Atc.pulsecode.approach then
    cs, cs1, cs2 = 6, 0, 0
  elseif code == Atc.pulsecode.approachmed then
    cs, cs1, cs2 = 4, 0, 1
  elseif code == Atc.pulsecode.cabspeed60 then
    cs, cs1, cs2 = 3, 2, 0
  elseif code == Atc.pulsecode.cabspeed80 then
    cs, cs1, cs2 = 2, 2, 0
  elseif code == Atc.pulsecode.clear100
      or code == Atc.pulsecode.clear125
      or code == Atc.pulsecode.clear150 then
    cs, cs1, cs2 = 1, 1, 0
  else
    cs, cs1, cs2 = 8, 0, 0
  end
  RailWorks.SetControlValue("CabSignal", 0, cs)
  state.cs1flash = cs1
  RailWorks.SetControlValue("CabSignal2", 0, cs2)
end

OnControlValueChange = RailWorks.SetControlValue

OnCustomSignalMessage = RailWorks.wraperrors(function (message)
  power:receivemessage(message)
  atc:receivemessage(message)
end)