sched = Scheduler.new()
state = {throttle=0,
         train_brake=0,
         dynamic_brake=0,
         atc_code=Atc.pulsecode.restrict,
         atc_do_upgrade=false,
         atc_upgrade_beep=false,
         atc_do_downgrade=false}
onebeep = 0.4

Initialise = RailWorks.wraperrors(function ()
  RailWorks.BeginUpdate()
  sched:run(background)
  sched:run(upgrade_sound)
end)

function background ()
  while true do
    sched:yield()
  end
end

function upgrade_sound ()
  while true do
    sched:yielduntil(function () return state.atc_do_upgrade end)
    state.atc_do_upgrade = false
    state.atc_upgrade_beep = true
    sched:sleep(onebeep)
    state.atc_upgrade_beep = false
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
    "OverSpeedAlert", 0, RailWorks.frombool(state.atc_upgrade_beep))
  showpulsecode(state.atc_code)
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

OnControlValueChange = RailWorks.wraperrors(function (name, index, value)
  RailWorks.SetControlValue(name, index, value)
end)

OnCustomSignalMessage = RailWorks.wraperrors(function (message)
  local newcode = readpulsecode(message)
  state.atc_do_upgrade = newcode > state.atc_code
  state.atc_do_downgrade = newcode < state.atc_code
  state.atc_code = newcode
end)

function readpulsecode (message)
  local atc = Atc.getpulsecode(message)
  if atc ~= nil then
    return atc
  end
  local power = Power.getchangepoint(message)
  if power ~= nil then
    -- Power switch signal. No change.
    return state.atc_code
  end
  RailWorks.showmessage("WARNING:\nUnknown signal '" .. message .. "'")
  return Atc.pulsecode.restrict
end