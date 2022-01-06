-- Engine script for the Kawasaki M8 operated by Metro-North.
--
-- @include RollingStock/PowerSupply/Electrification.lua
-- @include RollingStock/PowerSupply/PowerSupply.lua
-- @include RollingStock/BrakeLight.lua
-- @include RollingStock/InterVehicle.lua
-- @include RollingStock/Notch.lua
-- @include RollingStock/Spark.lua
-- @include SafetySystems/AspectDisplay/MetroNorth.lua
-- @include SafetySystems/Alerter.lua
-- @include Animation.lua
-- @include Flash.lua
-- @include Iterator.lua
-- @include Misc.lua
-- @include RailWorks.lua
-- @include Scheduler.lua
-- @include Units.lua
local powermode = {overhead = 1, thirdrail = 2}
local messageid = {
  locationprobe = 10110,
  intervehicle = 10111,
  motorlowpitch = 10112,
  motorhighpitch = 10113,
  motorvolume = 10114,
  compressorstate = 10115
}

local playersched, anysched
local adu
local alerter
local power
local ivc
local blight
local mcnotch
local pantoanim, gateanim
local alarmonoff
local spark
local state = {
  mcontroller = 0,
  acknowledge = false,

  speed_mps = 0,
  acceleration_mps2 = 0,
  trackspeed_mps = 0,
  consistlength_m = 0,
  speedlimits = {},
  restrictsignals = {},

  lastmotorclock_s = nil,
  lastmotorvol = 0,
  lastmotorpitch = 0
}

Initialise = Misc.wraperrors(function()
  playersched = Scheduler:new{}
  anysched = Scheduler:new{}

  adu = MetroNorthAdu:new{
    getbrakesuppression = function() return state.mcontroller <= -0.4 end,
    getacknowledge = function() return state.acknowledge end,
    getspeed_mps = function() return state.speed_mps end,
    gettrackspeed_mps = function() return state.trackspeed_mps end,
    getconsistlength_m = function() return state.consistlength_m end,
    iterspeedlimits = function() return pairs(state.speedlimits) end,
    iterrestrictsignals = function() return pairs(state.restrictsignals) end,
    consistspeed_mps = 80 * Units.mph.tomps
  }

  alerter = Alerter:new{
    scheduler = playersched,
    getspeed_mps = function() return state.speed_mps end
  }
  alerter:start()

  local isthirdrail = string.sub(RailWorks.GetRVNumber(), 1, 1) == "T"
  power = PowerSupply:new{
    scheduler = anysched,
    modecontrol = "Panto",
    -- Combine AC panto down/up into a single mode.
    modereadfn = function(v) return math.max(v, 1) end,
    getcantransition = function() return state.mcontroller <= 0 end,
    modes = {
      [powermode.overhead] = function(elec)
        local energyon = RailWorks.GetControlValue("PantographControl", 0) == 1
        return energyon and pantoanim:getposition() == 1 and
                 elec:isavailable(Electrification.type.overhead)
      end,
      [powermode.thirdrail] = function(elec)
        local energyon = RailWorks.GetControlValue("PantographControl", 0) == 1
        return energyon and elec:isavailable(Electrification.type.thirdrail)
      end
    },
    getautomode = function(cp)
      if cp == Electrification.autochangepoint.ai_to_overhead then
        return powermode.overhead
      elseif cp == Electrification.autochangepoint.ai_to_thirdrail then
        return powermode.thirdrail
      end
    end,
    oninit = function()
      power:setmode(isthirdrail and powermode.thirdrail or powermode.overhead)
      -- power select switch
      RailWorks.SetControlValue("Panto", 0, isthirdrail and 2 or 1)
      -- pantograph position
      pantoanim:setposition(isthirdrail and 0 or 1)

      power:setavailable(Electrification.type.overhead, not isthirdrail)
      power:setavailable(Electrification.type.thirdrail, isthirdrail)
    end
  }

  ivc = InterVehicle:new{messageid = messageid.intervehicle}

  blight = BrakeLight:new{}

  mcnotch = Notch:new{
    scheduler = playersched,
    control = "ThrottleAndBrake",
    index = 0,
    gettarget = function(v)
      local coast = 0.0667
      local min = 0.2
      if v >= coast and v < min then
        return min
      elseif math.abs(v) < coast then
        return 0
      elseif v > -min and v <= -coast then
        return -min
      else
        return v
      end
    end
  }

  pantoanim = Animation:new{animation = "panto", duration_s = 2}

  gateanim = Animation:new{animation = "ribbons", duration_s = 1}

  -- Modulate the speed reduction alert sound, which normally plays just once.
  alarmonoff = Flash:new{scheduler = playersched, off_s = 0.1, on_s = 0.5}

  spark = PantoSpark:new{}

  RailWorks.BeginUpdate()
end)

local function readcontrols()
  local mcontroller = RailWorks.GetControlValue("ThrottleAndBrake", 0)
  local change = mcontroller ~= state.mcontroller
  state.mcontroller = mcontroller
  state.acknowledge = RailWorks.GetControlValue("AWSReset", 0) > 0
  if state.acknowledge or change then alerter:acknowledge() end
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
  local haspower = power:haspower()
  local penalty = alerter:ispenalty() or adu:ispenalty()
  local throttle, brake
  if penalty then
    throttle, brake = 0, 0.85
  else
    throttle = haspower and math.max(state.mcontroller, 0) or 0
    brake = math.max(-state.mcontroller, 0)
  end
  RailWorks.SetControlValue("Regulator", 0, throttle)
  RailWorks.SetControlValue("TrainBrakeControl", 0, brake)

  local psi = RailWorks.GetControlValue("AirBrakePipePressurePSI", 0)
  RailWorks.SetControlValue("DynamicBrake", 0,
                            math.max((150 - psi) * 0.01428, 0))

  alarmonoff:setflashstate(adu:isalarm())
  RailWorks.SetControlValue("SpeedReductionAlert", 0,
                            Misc.intbool(alarmonoff:ison()))
  RailWorks.SetControlValue("SpeedIncreaseAlert", 0,
                            Misc.intbool(adu:isalertplaying()))
  -- Unfortunately, we cannot display the AWS symbol without also playing the
  -- fast beep-beep sound. So, use it to sound the alerter.
  RailWorks.SetControlValue("AWS", 0, Misc.intbool(alerter:isalarm()))
end

local function sendconsiststatus()
  local amps = RailWorks.GetControlValue("Ammeter", 0)
  local motors
  if math.abs(amps) < 30 then
    motors = 0
  elseif amps > 0 then
    motors = 1
  else
    motors = -1
  end

  local doors
  if RailWorks.GetControlValue("DoorsOpenCloseLeft", 0) == 1 then
    doors = -1
  elseif RailWorks.GetControlValue("DoorsOpenCloseRight", 0) == 1 then
    doors = 1
  else
    doors = 0
  end

  ivc:setmessage(motors .. ":" .. doors)
end

local function setplayersounds()
  local now = playersched:clock()
  local dt = state.lastmotorclock_s == nil and 0 or now - state.lastmotorclock_s
  state.lastmotorclock_s = now
  local dconsound = (power:haspower() and 1 or -1) * dt / 5
  RailWorks.SetControlValue("FanSound", 0, RailWorks.GetControlValue("FanSound",
                                                                     0) +
                              dconsound)

  -- motor sound algorithm from DTG
  local speedcurvemult, lowpitch_speedcurvemult = 0.07, 0.05
  local acoffset, acspeedmax = -0.3, 0.75
  local dcoffset, dcspeedmax = 0.1, 1
  local dcspeedcurveup_pitch, dcspeedcurveup_mult = 0.6, 0.4
  local vol_incdecmax, pitch_incdecmax = 4, 1
  local acdcspeedmin = 0.23

  local aspeed_mph = math.abs(RailWorks.GetSpeed()) * Units.mps.tomph
  local throttle = RailWorks.GetControlValue("Regulator", 0)
  local brake = RailWorks.GetControlValue("TrainBrakeControl", 0)
  local v1 = math.min(1, throttle * 3)
  local v2 = math.max(v1, math.max(0, math.min(1, aspeed_mph * 3 - 4.02336)) *
                        math.min(1, brake * 5))
  local function clampincdec(last, current, incdecmax)
    if current > last then
      return math.min(current, last + incdecmax * dt)
    elseif current < last then
      return math.max(current, last - incdecmax * dt)
    else
      return current
    end
  end

  local pitch
  if power:getmode() == powermode.thirdrail then
    pitch = speedcurvemult * aspeed_mph * v2 + dcoffset
    if pitch > dcspeedcurveup_pitch and v1 == v2 then
      pitch = pitch + (pitch - dcspeedcurveup_pitch) * dcspeedcurveup_mult
    end
    pitch = math.min(pitch, dcspeedmax)
  else
    pitch = aspeed_mph * speedcurvemult * v2 + acoffset
    pitch = math.min(pitch, acspeedmax)
  end
  pitch = clampincdec(state.lastmotorpitch, pitch, pitch_incdecmax)
  state.lastmotorpitch = pitch

  local volume = (pitch > acdcspeedmin + 0.01) and 1 or v2
  volume = clampincdec(state.lastmotorvol, volume, vol_incdecmax)
  state.lastmotorvol = volume

  local lowpitch = aspeed_mph * lowpitch_speedcurvemult
  RailWorks.SetControlValue("MotorLowPitch", 0, lowpitch)
  RailWorks.Engine_SendConsistMessage(messageid.motorlowpitch, lowpitch, 0)
  RailWorks.Engine_SendConsistMessage(messageid.motorlowpitch, lowpitch, 1)

  RailWorks.SetControlValue("MotorHighPitch", 0, pitch)
  RailWorks.Engine_SendConsistMessage(messageid.motorhighpitch, pitch, 0)
  RailWorks.Engine_SendConsistMessage(messageid.motorhighpitch, pitch, 1)

  RailWorks.SetControlValue("MotorVolume", 0, volume)
  RailWorks.Engine_SendConsistMessage(messageid.motorvolume, volume, 0)
  RailWorks.Engine_SendConsistMessage(messageid.motorvolume, volume, 1)

  local cstate = RailWorks.GetControlValue("CompressorState", 0)
  RailWorks.Engine_SendConsistMessage(messageid.compressorstate, cstate, 0)
  RailWorks.Engine_SendConsistMessage(messageid.compressorstate, cstate, 1)
end

local function setaisounds()
  -- motor sound algorithm from DTG
  local speedcurvemult = 0.07
  local aspeed_mph = math.abs(RailWorks.GetSpeed()) * Units.mps.tomph
  RailWorks.SetControlValue("MotorLowPitch", 0, aspeed_mph)
  RailWorks.SetControlValue("MotorHighPitch", 0, aspeed_mph * speedcurvemult)

  local aaccel_mps2 = math.abs(RailWorks.GetAcceleration())
  RailWorks.SetControlValue("MotorVolume", 0, math.min(aaccel_mps2 * 5, 1))
end

local function setdrivescreen()
  local speed_mph = Misc.round(state.speed_mps * Units.mps.tomph)
  RailWorks.SetControlValue("SpeedoHundreds", 0, Misc.getdigit(speed_mph, 2))
  RailWorks.SetControlValue("SpeedoTens", 0, Misc.getdigit(speed_mph, 1))
  RailWorks.SetControlValue("SpeedoUnits", 0, Misc.getdigit(speed_mph, 0))

  local bp_psi = Misc.round(RailWorks.GetControlValue("AirBrakePipePressurePSI",
                                                      0))
  RailWorks.SetControlValue("PipeHundreds", 0, Misc.getdigit(bp_psi, 2))
  RailWorks.SetControlValue("PipeTens", 0, Misc.getdigit(bp_psi, 1))
  RailWorks.SetControlValue("PipeUnits", 0, Misc.getdigit(bp_psi, 0))

  local bc_psi = Misc.round(RailWorks.GetControlValue(
                              "TrainBrakeCylinderPressurePSI", 0))
  RailWorks.SetControlValue("CylinderHundreds", 0, Misc.getdigit(bc_psi, 2))
  RailWorks.SetControlValue("CylinderTens", 0, Misc.getdigit(bc_psi, 1))
  RailWorks.SetControlValue("CylinderUnits", 0, Misc.getdigit(bc_psi, 0))

  local _, after, _ = power:gettransition()
  local pmode = after or power:getmode()
  local haspower = power:haspower()
  if pmode == powermode.overhead then
    RailWorks.SetControlValue("PowerAC", 0, haspower and 2 or 1)
    RailWorks.SetControlValue("PowerDC", 0, 0)
  else
    RailWorks.SetControlValue("PowerAC", 0, 0)
    RailWorks.SetControlValue("PowerDC", 0, haspower and 2 or 1)
  end

  -- Impose a startup delay so that the car displays don't flicker.
  if not playersched:isstartup() then
    local nbehind = ivc:getnbehind()
    RailWorks.SetControlValue("Cars", 0, nbehind)
    for i = 1, nbehind do
      local _, _, motorsstr, doorsstr = string.find(ivc:getmessagebehind(i),
                                                    "(-?%d+):(-?%d+)")
      local motors = tonumber(motorsstr) or 0
      RailWorks.SetControlValue("Motor_" .. (i + 1), 0, motors)
      local doors = tonumber(doorsstr) or 0
      RailWorks.SetControlValue("Doors_" .. (i + 1), 0, doors)
    end
  end
end

local function setcutin()
  if not playersched:isstartup() then
    adu:setatcstate(RailWorks.GetControlValue("ATCCutIn", 0) == 1)
    adu:setacsesstate(RailWorks.GetControlValue("ACSESCutIn", 0) == 1)
  end
end

local function setadu()
  local aspect = adu:getaspect()
  local n, l, m, r, s
  if aspect == MetroNorthAdu.aspect.stop then
    n, l, m, r, s = 0, 0, 0, 0, 1
  elseif aspect == MetroNorthAdu.aspect.restrict then
    n, l, m, r, s = 0, 0, 0, 1, 0
  elseif aspect == MetroNorthAdu.aspect.medium then
    n, l, m, r, s = 0, 0, 1, 0, 0
  elseif aspect == MetroNorthAdu.aspect.limited then
    n, l, m, r, s = 0, 1, 0, 0, 0
  elseif aspect == MetroNorthAdu.aspect.normal then
    n, l, m, r, s = 1, 0, 0, 0, 0
  end
  RailWorks.SetControlValue("SigN", 0, n)
  RailWorks.SetControlValue("SigL", 0, l)
  RailWorks.SetControlValue("SigM", 0, m)
  RailWorks.SetControlValue("SigR", 0, r)
  RailWorks.SetControlValue("SigS", 0, s)

  local signalspeed_mph = adu:getsignalspeed_mph()
  RailWorks.SetControlValue("SignalSpeed", 0,
                            signalspeed_mph == nil and 1 or signalspeed_mph)

  local civilspeed_mph = adu:getcivilspeed_mph()
  if civilspeed_mph == nil then
    RailWorks.SetControlValue("TrackSpeedHundreds", 0, 0)
    RailWorks.SetControlValue("TrackSpeedTens", 0, -1)
    RailWorks.SetControlValue("TrackSpeedUnits", 0, -1)
  else
    RailWorks.SetControlValue("TrackSpeedHundreds", 0,
                              Misc.getdigit(civilspeed_mph, 2))
    RailWorks.SetControlValue("TrackSpeedTens", 0,
                              Misc.getdigit(civilspeed_mph, 1))
    RailWorks.SetControlValue("TrackSpeedUnits", 0,
                              Misc.getdigit(civilspeed_mph, 0))
  end
end

local function setpanto()
  pantoanim:setanimatedstate(RailWorks.GetControlValue("Panto", 0) == 1)

  local contact = pantoanim:getposition() == 1
  local isspark = contact and spark:isspark()
  RailWorks.ActivateNode("panto_spark", isspark)
  Call("Spark:Activate", Misc.intbool(isspark))
end

local function setgate()
  local iscoupled = RailWorks.Engine_SendConsistMessage(messageid.locationprobe,
                                                        "", 0)
  gateanim:setanimatedstate(iscoupled)
end

local function setinteriorlights()
  local cab = RailWorks.GetControlValue("Cablight", 0)
  Call("Cablight:Activate", cab)

  local hep = power:haspower()
  RailWorks.ActivateNode("round_lights_off", not hep)
  RailWorks.ActivateNode("round_lights_on", hep)
  for i = 1, 9 do Call("PVLight_00" .. i .. ":Activate", Misc.intbool(hep)) end
  for i = 10, 12 do Call("PVLight_0" .. i .. ":Activate", Misc.intbool(hep)) end
  Call("HallLight_001:Activate", Misc.intbool(hep))
  Call("HallLight_002:Activate", Misc.intbool(hep))
end

local function setstatuslights()
  local brakesapplied = blight:isapplied()
  RailWorks.ActivateNode("SL_green", not brakesapplied)
  RailWorks.ActivateNode("SL_yellow", brakesapplied)
  RailWorks.ActivateNode("SL_blue",
                         RailWorks.GetControlValue("HandBrake", 0) == 1)
  RailWorks.ActivateNode("SL_doors_L", RailWorks.GetControlValue(
                           "DoorsOpenCloseLeft", 0) == 1)
  RailWorks.ActivateNode("SL_doors_R", RailWorks.GetControlValue(
                           "DoorsOpenCloseRight", 0) == 1)
end

local function setplayerditchlights()
  local headlights = RailWorks.GetControlValue("Headlights", 0)
  local show = headlights > 0.5 and headlights < 1.5
  RailWorks.ActivateNode("left_ditch_light", show)
  RailWorks.ActivateNode("right_ditch_light", show)
  Call("Fwd_DitchLightLeft:Activate", Misc.intbool(show))
  Call("Fwd_DitchLightRight:Activate", Misc.intbool(show))
end

local function sethelperditchlights()
  local headlights = RailWorks.GetControlValue("Headlights", 0)
  local isend = not RailWorks.Engine_SendConsistMessage(messageid.locationprobe,
                                                        "", 0)
  local show = headlights > 1.5 and isend
  RailWorks.ActivateNode("left_ditch_light", show)
  RailWorks.ActivateNode("right_ditch_light", show)
  Call("Fwd_DitchLightLeft:Activate", Misc.intbool(show))
  Call("Fwd_DitchLightRight:Activate", Misc.intbool(show))
end

local function setaiditchlights()
  local isend = not RailWorks.Engine_SendConsistMessage(messageid.locationprobe,
                                                        "", 0)
  -- There's no surefire way to determine which end of the train an AI unit is on,
  -- so use speed (just like DTG).
  local isforward = RailWorks.GetSpeed() > Misc.stopped_mps
  local show = isend and isforward
  RailWorks.ActivateNode("left_ditch_light", show)
  RailWorks.ActivateNode("right_ditch_light", show)
  Call("Fwd_DitchLightLeft:Activate", Misc.intbool(show))
  Call("Fwd_DitchLightRight:Activate", Misc.intbool(show))
end

local function updateplayer(dt)
  readcontrols()
  readlocostate()

  playersched:update()
  anysched:update()
  power:update()
  adu:update(dt)
  ivc:update(dt)
  blight:playerupdate()
  mcnotch:update()
  pantoanim:update(dt)
  gateanim:update(dt)

  writelocostate()
  sendconsiststatus()
  setplayersounds()
  setdrivescreen()
  setcutin()
  setadu()
  setpanto()
  setgate()
  setinteriorlights()
  setstatuslights()
  setplayerditchlights()
end

local function updatehelper(dt)
  anysched:update()
  power:update()
  ivc:update(dt)
  pantoanim:update(dt)
  gateanim:update(dt)

  sendconsiststatus()
  setpanto()
  setgate()
  setinteriorlights()
  setstatuslights()
  sethelperditchlights()
end

local function updateai(dt)
  anysched:update()
  power:update()
  pantoanim:update(dt)
  gateanim:update(dt)

  setaisounds()
  setpanto()
  setgate()
  setinteriorlights()
  setstatuslights()
  setaiditchlights()
end

Update = Misc.wraperrors(function(dt)
  if RailWorks.GetIsEngineWithKey() then
    updateplayer(dt)
  elseif RailWorks.GetIsPlayer() then
    updatehelper(dt)
  else
    updateai(dt)
  end
end)

OnControlValueChange = RailWorks.SetControlValue

OnCustomSignalMessage = Misc.wraperrors(function(message)
  power:receivemessage(message)
  adu:receivemessage(message)
end)

OnConsistMessage = Misc.wraperrors(function(message, argument, direction)
  blight:receivemessage(message, argument, direction)

  if ivc:receivemessage(message, argument, direction) then
    return
  elseif message == messageid.locationprobe then
    return
  elseif message == messageid.motorlowpitch then
    RailWorks.SetControlValue("MotorLowPitch", 0, tonumber(argument))
  elseif message == messageid.motorhighpitch then
    RailWorks.SetControlValue("MotorHighPitch", 0, tonumber(argument))
  elseif message == messageid.motorvolume then
    RailWorks.SetControlValue("MotorVolume", 0, tonumber(argument))
  elseif message == messageid.compressorstate then
    RailWorks.SetControlValue("CompressorState", 0, tonumber(argument))
  end

  RailWorks.Engine_SendConsistMessage(message, argument, direction)
end)
