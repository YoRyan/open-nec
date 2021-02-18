sched = Scheduler.new()
atc = nil
state = {throttle=0,
         train_brake=0,
         dynamic_brake=0,
         acknowledge=false,

         speed_mps=0,
         acceleration_mps2=0,

         alert=nil,
         beep_alert=false}
onebeep = 0.4

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
    config.doalert =
      function () state.alert:trigger() end
    atc = newatc
  end
  state.alert = Event.new(sched)
  sched:run(doalerts)
  RailWorks.BeginUpdate()
end)

function doalerts ()
  while true do
    state.alert:waitfor()
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

  sched:update(dt)
  for msg in sched:getmessages() do
    RailWorks.showmessage(msg)
  end
  sched:clearmessages()

  RailWorks.SetControlValue("Regulator", 0, state.throttle)
  RailWorks.SetControlValue("TrainBrakeControl", 0, state.train_brake)
  RailWorks.SetControlValue("DynamicBrake", 0, state.dynamic_brake)
  RailWorks.SetControlValue(
    "OverSpeedAlert", 0, RailWorks.frombool(state.beep_alert))
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

OnControlValueChange = function (name, index, value)
  RailWorks.SetControlValue(name, index, value)
end

OnCustomSignalMessage = RailWorks.wraperrors(function (message)
  atc:receivemessage(message)
end)