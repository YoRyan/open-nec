sched = Scheduler.new()
state = {throttle=0,
         train_brake=0,
         dynamic_brake=0,
         atc_code=Atc.pulse_code.restricting}

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
  show_pulse_code(state.atc_code)
end)

function show_pulse_code (code)
  local cs, cs1, cs2
  if code == Atc.pulse_code.restricting then
    cs, cs1, cs2 = 7, 0, 0
  elseif code == Atc.pulse_code.approach then
    cs, cs1, cs2 = 6, 0, 0
  elseif code == Atc.pulse_code.approach_medium then
    cs, cs1, cs2 = 4, 0, 1
  elseif code == Atc.pulse_code.cab_speed_60 then
    cs, cs1, cs2 = 3, 1, 0
  elseif code == Atc.pulse_code.cab_speed_80 then
    cs, cs1, cs2 = 2, 1, 0
  elseif code == Atc.pulse_code.clear_100
      or code == Atc.pulse_code.clear_125
      or code == Atc.pulse_code.clear_150 then
    cs, cs1, cs2 = 1, 1, 0
  else
    cs, cs1, cs2 = 8, 0, 0
  end
  RailWorks.SetControlValue("CabSignal", 0, cs)
  RailWorks.SetControlValue("CabSignal1", 0, cs1)
  RailWorks.SetControlValue("CabSignal2", 0, cs2)
end

OnControlValueChange = RailWorks.wrapErrors(function (name, index, value)
  RailWorks.SetControlValue(name, index, value)
end)

OnCustomSignalMessage = RailWorks.wrapErrors(function (message)
  local code = Atc.get_pulse_code(message)
  if code == nil then
    RailWorks.showMessage("WARNING:\nUnknown signal '" .. message .. "'")
    state.atc_code = Atc.pulse_code.restricting
  else
    state.atc_code = code
  end
end)