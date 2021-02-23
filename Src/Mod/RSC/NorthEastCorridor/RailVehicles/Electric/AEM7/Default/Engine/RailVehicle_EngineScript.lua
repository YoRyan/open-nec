sched = Scheduler.new()
atc = nil
acses = nil
cruise = nil
alerter = nil
state = {
  throttle=0,
  train_brake=0,
  dynamic_brake=0,
  acknowledge=false,
  cruisespeed_mps=0,
  cruiseenabled=false,
  alerterenabled=false,

  speed_mps=0,
  acceleration_mps2=0,
  trackspeed_mps=0,
  forwardspeedlimits={},
  backwardspeedlimits={},
  
  event_alert=nil,
  beep_alert=false,
  cs1flash=0, -- 0 = off, 1 = on, 2 = flash
  cs1light=false
}
onebeep = 0.3
nspeedlimits = 5

Initialise = RailWorks.wraperrors(function ()
  do
    local newatc = Atc.new(sched)
    local config = newatc.config
    config.getspeed_mps =
      function () return state.speed_mps end
    config.getacceleration_mps2 =
      function () return state.acceleration_mps2 end
    config.getacknowledge =
      function () return state.acknowledge end
    config.getsuppression =
      -- Brake in the "Full Service" range.
      function () return state.train_brake >= 0.55 and state.throttle == 0 end
    config.doalert =
      function () state.event_alert:trigger() end
    atc = newatc
  end
  do
    local newacses = Acses.new(sched)
    local config = newacses.config
    config.getspeed_mps =
      function () return state.speed_mps end
    config.gettrackspeed_mps =
      function () return state.trackspeed_mps end
    config.getforwardspeedlimits =
      function () return state.forwardspeedlimits end
    config.getbackwardspeedlimits =
      function () return state.forwardspeedlimits end
    config.getacknowledge =
      function () return state.acknowledge end
    config.doalert =
      function () state.event_alert:trigger() end
    acses = newacses
  end
  do
    local newcruise = Cruise.new(sched)
    local config = newcruise.config
    config.getspeed_mps =
      function () return state.speed_mps end
    config.gettargetspeed_mps =
      function () return state.cruisespeed_mps end
    config.getenabled =
      function () return state.cruiseenabled end
    cruise = newcruise
  end
  do
    local newalerter = Alerter.new(sched)
    local config = newalerter.config
    config.getspeed_mps =
      function () return state.speed_mps end
    config.getenabled =
      function () return state.alerterenabled end
    alerter = newalerter
  end
  state.event_alert = Event.new(sched)
  sched:run(doalerts)
  sched:run(cs1flasher)
  RailWorks.BeginUpdate()
end)

function doalerts ()
  while true do
    state.event_alert:waitfor()
    state.beep_alert = true
    sched:sleep(onebeep)
    state.beep_alert = false
  end
end

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
    return
  end

  do
    local vthrottle = RailWorks.GetControlValue("VirtualThrottle", 0)
    local vbrake = RailWorks.GetControlValue("VirtualBrake", 0)
    local vdynamic = RailWorks.GetControlValue("VirtualDynamicBrake", 0)
    local change = vthrottle ~= state.throttle
      or vbrake ~= state.train_brake
      or vdynamic ~= state.dynamic_brake
    state.throttle = vthrottle
    state.train_brake = vbrake
    state.dynamic_brake = vdynamic
    state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) == 1
    if state.acknowledge or change then
      alerter.state.acknowledge:trigger()
    end
  end

  state.cruisespeed_mps = RailWorks.GetControlValue("CruiseSet", 0)*0.447
  state.cruiseenabled = RailWorks.GetControlValue("CruiseSet", 0) > 10
  state.alerterenabled = RailWorks.GetControlValue("AlertControl", 0) == 1
  state.speed_mps = RailWorks.GetSpeed()
  state.acceleration_mps2 = RailWorks.GetAcceleration()
  state.trackspeed_mps, _ = RailWorks.GetCurrentSpeedLimit(1)
  state.forwardspeedlimits = RailWorks.getforwardspeedlimits(nspeedlimits)
  state.backwardspeedlimits = RailWorks.getbackwardspeedlimits(nspeedlimits)

  sched:update(dt)
  for msg in sched:getmessages() do
    RailWorks.showmessage(msg)
  end
  sched:clearmessages()

  local penalty = atc.state.penalty or acses.state.penalty or alerter.state.penalty
  do
    local v
    if penalty then v = 0
    elseif state.cruiseenabled then v = state.throttle*cruise.state.throttle
    else v = state.throttle end
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
    if penalty then v = 0
    else v = state.dynamic_brake end
    RailWorks.SetControlValue("DynamicBrake", 0, v)
  end

  RailWorks.SetControlValue(
    "AWS", 0,
    RailWorks.frombool(
      atc.state.alarm or acses.state.alarm or alerter.state.alarm))
  RailWorks.SetControlValue(
    "AWSWarnCount", 0,
    RailWorks.frombool(alerter.state.alarm))
  RailWorks.SetControlValue(
    "OverSpeedAlert", 0,
    RailWorks.frombool(state.beep_alert or atc.state.alarm or acses.state.alarm))
  RailWorks.SetControlValue(
    "TrackSpeed", 0,
    math.floor(acses.state.enforcedspeed_mps*2.24 + 0.5))

  setpulsecode()
  RailWorks.SetControlValue("CabSignal1", 0, RailWorks.frombool(state.cs1light))

  do
    local cablight = RailWorks.GetControlValue("CabLightControl", 0)
    Call("FrontCabLight:Activate", cablight)
    Call("RearCabLight:Activate", cablight)
  end
end)

function setpulsecode ()
  local code = atc.state.pulsecode
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
  atc:receivemessage(message)
end)