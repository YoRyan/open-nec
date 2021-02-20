sched = Scheduler.new()
atc = nil
acses = nil
state = {
  throttle=0,
  train_brake=0,
  dynamic_brake=0,
  acknowledge=false,

  speed_mps=0,
  acceleration_mps2=0,
  trackspeed_mps=0,
  forwardspeedlimits={}, -- {{speed_mps=..., distance_m=...}, ...}
  backwardspeedlimits={}, -- {{speed_mps=..., distance_m=...}, ...}
  
  event_alert=nil,
  beep_alert=false
}
onebeep = 0.3
nspeedlimits = 3

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
  state.event_alert = Event.new(sched)
  sched:run(doalerts)
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

Update = RailWorks.wraperrors(function (dt)
  if not RailWorks.GetIsEngineWithKey() then
    return
  end

  state.throttle = RailWorks.GetControlValue("VirtualThrottle", 0)
  state.train_brake = RailWorks.GetControlValue("VirtualBrake", 0)
  state.dynamic_brake = RailWorks.GetControlValue("VirtualDynamicBrake", 0)
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) == 1
  state.speed_mps = RailWorks.GetSpeed()
  state.acceleration_mps2 = RailWorks.GetAcceleration()
  state.trackspeed_mps, _ = RailWorks.GetCurrentSpeedLimit(1)
  do
    local speedlimits = {}
    for speed_mps, distance_m in RailWorks.getforwardspeedlimits(nspeedlimits) do
      table.insert(speedlimits, {speed_mps=speed_mps, distance_m=distance_m})
    end
    state.forwardspeedlimits = speedlimits
  end
  do
    local speedlimits = {}
    for speed_mps, distance_m in RailWorks.getbackwardspeedlimits(nspeedlimits) do
      table.insert(speedlimits, {speed_mps=speed_mps, distance_m=distance_m})
    end
    state.backwardspeedlimits = speedlimits
  end

  sched:update(dt)
  for msg in sched:getmessages() do
    RailWorks.showmessage(msg)
  end
  sched:clearmessages()

  local penalty = atc.state.penalty or acses.state.penalty
  do
    local v
    if penalty then v = 0
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
    RailWorks.frombool(atc.state.alarm or acses.state.alarm))
  RailWorks.SetControlValue(
    "OverSpeedAlert", 0,
    RailWorks.frombool(state.beep_alert or atc.state.alarm or acses.state.alarm))
  RailWorks.SetControlValue(
    "TrackSpeed", 0,
    math.floor(acses.state.enforcedspeed_mps*2.24 + 0.5))
  showpulsecode(atc.state.pulsecode)
end)

function showpulsecode (code)
  local cs, cs1, cs2
  if code == Atc.pulsecode.restrict then
    cs, cs1, cs2 = 7, 0, 0
  elseif code == Atc.pulsecode.approach then
    cs, cs1, cs2 = 6, 0, 0
  elseif code == Atc.pulsecode.approachmed then
    cs, cs1, cs2 = 4, 0, 1
  elseif code == Atc.pulsecode.cabspeed60 then
    cs, cs1, cs2 = 3, 1, 0
  elseif code == Atc.pulsecode.cabspeed80 then
    cs, cs1, cs2 = 2, 1, 0
  elseif code == Atc.pulsecode.clear100
      or code == Atc.pulsecode.clear125
      or code == Atc.pulsecode.clear150 then
    cs, cs1, cs2 = 1, 1, 0
  else
    cs, cs1, cs2 = 8, 0, 0
  end
  RailWorks.SetControlValue("CabSignal", 0, cs)
  RailWorks.SetControlValue("CabSignal1", 0, cs1)
  RailWorks.SetControlValue("CabSignal2", 0, cs2)
end

OnControlValueChange = RailWorks.SetControlValue

OnCustomSignalMessage = RailWorks.wraperrors(function (message)
  atc:receivemessage(message)
end)