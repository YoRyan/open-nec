sched = Scheduler.new()
state = {throttle=0,
         train_brake=0,
         dynamic_brake=0}

function background ()
  while true do
    sched:yield()
  end
end

Initialise = RailWorks.wrapErrors(function ()
  RailWorks.BeginUpdate()
  sched:run(background)
end)

Update = RailWorks.wrapErrors(function (dt)
  if not RailWorks.GetIsEngineWithKey() then
    return
  end

  state.throttle = RailWorks.GetControlValue("VirtualThrottle", 0)
  state.train_brake = RailWorks.GetControlValue("VirtualBrake", 0)
  state.dynamic_brake = RailWorks.GetControlValue("VirtualDynamicBrake", 0)

  sched:update(dt)
  for msg in sched:iter_messages() do
    RailWorks.showMessage(msg)
  end
  sched:clear_messages()

  RailWorks.SetControlValue("Regulator", 0, state.throttle)
  RailWorks.SetControlValue("TrainBrakeControl", 0, state.train_brake)
  RailWorks.SetControlValue("DynamicBrake", 0, state.dynamic_brake)
end)

OnControlValueChange = RailWorks.wrapErrors(function (name, index, value)
  RailWorks.SetControlValue(name, index, value)
end)