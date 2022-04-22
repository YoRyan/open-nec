-- Engine script for the Kawasaki M8 operated by Metro-North.
--
-- @include SafetySystems/Alerter.lua
-- @include SafetySystems/AspectDisplay/MetroNorth.lua
-- @include YoRyan/LibRailWorks/Animation.lua
-- @include YoRyan/LibRailWorks/Flash.lua
-- @include YoRyan/LibRailWorks/Iterator.lua
-- @include YoRyan/LibRailWorks/Misc.lua
-- @include YoRyan/LibRailWorks/RailWorks.lua
-- @include YoRyan/LibRailWorks/RollingStock/AiDirection.lua
-- @include YoRyan/LibRailWorks/RollingStock/BrakeLight.lua
-- @include YoRyan/LibRailWorks/RollingStock/InterVehicle.lua
-- @include YoRyan/LibRailWorks/RollingStock/Notch.lua
-- @include YoRyan/LibRailWorks/RollingStock/PowerSupply/Electrification.lua
-- @include YoRyan/LibRailWorks/RollingStock/PowerSupply/PowerSupply.lua
-- @include YoRyan/LibRailWorks/RollingStock/Spark.lua
-- @include YoRyan/LibRailWorks/Units.lua
local adu
local alerter
local power
local ivc
local blight
local mcnotch
local pantoanim, gateanim
local alarmonoff
local spark
local aidirection

local lastmotorpitch = 0
local lastmotorvol = 0

local powermode = {overhead = 1, thirdrail = 2}
local messageid = {
  locationprobe = 10110,
  intervehicle = 10111,
  motorlowpitch = 10112,
  motorhighpitch = 10113,
  motorvolume = 10114,
  compressorstate = 10115
}

Initialise = Misc.wraperrors(function()
  adu = MetroNorthAdu:new{
    getbrakesuppression = function()
      return RailWorks.GetControlValue("ThrottleAndBrake", 0) <= -0.4
    end,
    getacknowledge = function()
      return RailWorks.GetControlValue("AWSReset", 0) > 0
    end
  }

  alerter = Alerter:new{
    getacknowledge = function()
      return RailWorks.GetControlValue("AWSReset", 0) > 0
    end
  }
  alerter:start()

  local isthirdrail = string.sub(RailWorks.GetRVNumber(), 1, 1) == "T"
  power = PowerSupply:new{
    modecontrol = "Panto",
    -- Combine AC panto down/up into a single mode.
    modereadfn = function(v) return math.max(v, 1) end,
    getcantransition = function()
      return RailWorks.GetControlValue("ThrottleAndBrake", 0) <= 0
    end,
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
    modenames = {
      [powermode.overhead] = "catenary",
      [powermode.thirdrail] = "third rail"
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
    control = "ThrottleAndBrake",
    index = 0,
    gettarget = function(v)
      local coast = 0.0667
      local min = 0.2
      if v >= coast and v < min then -- minimum power
        return min
      elseif math.abs(v) < coast then -- coast
        return 0
      elseif v > -min and v <= -coast then -- minimum brake
        return -min
      elseif v >= -0.99 and v < -0.9 then -- maximum brake
        return -0.9
      elseif v < -0.99 then -- emergency brake
        return -1
      else
        return v
      end
    end
  }

  pantoanim = Animation:new{animation = "panto", duration_s = 2}

  gateanim = Animation:new{animation = "ribbons", duration_s = 1}

  -- Modulate the speed reduction alert sound, which normally plays just once.
  alarmonoff = Flash:new{off_s = 0.1, on_s = 0.5}

  spark = PantoSpark:new{}

  aidirection = AiDirection:new{}

  RailWorks.BeginUpdate()
end)

local function setplayercontrols()
  local haspower = power:haspower()
  local penalty = alerter:ispenalty() or adu:ispenalty()
  local throttle, brake
  if penalty then
    throttle, brake = 0, 0.85
  else
    local controller = RailWorks.GetControlValue("ThrottleAndBrake", 0)
    throttle = haspower and math.max(controller, 0) or 0
    brake = math.max(-controller, 0)
  end
  RailWorks.SetControlValue("Regulator", 0, throttle)

  -- custom blended braking for Fan Railer's physics
  local isfanrailer = RailWorks.GetTotalMass() == 65.7
  local airbrake, dynbrake
  if isfanrailer then
    local aspeed_mph = math.abs(RailWorks.GetSpeed()) * Units.mps.tomph
    local dynbrakestart, dynbrakefull = 3, 8
    local minairbrake = 0.03 -- 8 psi
    local isemergency, maxairbrake = brake > 0.99, 0.4
    if aspeed_mph > dynbrakefull then
      airbrake = isemergency and 1 or math.min(brake, minairbrake)
      dynbrake = brake
    elseif aspeed_mph > dynbrakestart then
      local dynproportion = (aspeed_mph - dynbrakestart) /
                              (dynbrakefull - dynbrakestart)
      airbrake = isemergency and 1 or
                   math.max(maxairbrake * (1 - dynproportion) * brake,
                            math.min(brake, minairbrake))
      dynbrake = dynproportion * brake
    else
      airbrake = isemergency and 1 or maxairbrake * brake
      dynbrake = 0
    end
  else
    -- for stock physics, use DTG's algorithm
    local psi = RailWorks.GetControlValue("AirBrakePipePressurePSI", 0)
    airbrake = brake
    dynbrake = math.max((150 - psi) * 0.01428, 0)
  end
  RailWorks.SetControlValue("TrainBrakeControl", 0, airbrake)
  RailWorks.SetControlValue("DynamicBrake", 0, dynbrake)

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

local function setplayersounds(dt)
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
  pitch = clampincdec(lastmotorpitch, pitch, pitch_incdecmax)
  lastmotorpitch = pitch

  local volume = (pitch > acdcspeedmin + 0.01) and 1 or v2
  volume = clampincdec(lastmotorvol, volume, vol_incdecmax)
  lastmotorvol = volume

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
  local speed_mph = Misc.round(RailWorks.GetControlValue("SpeedometerMPH", 0))
  RailWorks.SetControlValue("SpeedoHundreds", 0, Misc.getdigit(speed_mph, 2))
  RailWorks.SetControlValue("SpeedoTens", 0, Misc.getdigit(speed_mph, 1))
  RailWorks.SetControlValue("SpeedoUnits", 0, Misc.getdigit(speed_mph, 0))

  local bp_psi = Misc.round(RailWorks.GetControlValue("AirBrakePipePressurePSI",
                                                      0))
  RailWorks.SetControlValue("PipeHundreds", 0, Misc.getdigit(bp_psi, 2))
  RailWorks.SetControlValue("PipeTens", 0, Misc.getdigit(bp_psi, 1))
  RailWorks.SetControlValue("PipeUnits", 0, Misc.getdigit(bp_psi, 0))

  -- Don't round this number; it gets stuck at 1.
  local bc_psi = math.floor(RailWorks.GetControlValue(
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
  if Misc.isinitialized() then
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
  if Misc.isinitialized() then
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

local function setplayerstatuslights()
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

local function setaistatuslights()
  local aspeed_mps = math.abs(RailWorks.GetSpeed())
  local isslow = aspeed_mps < 20 * Units.mph.tomps
  RailWorks.ActivateNode("SL_green", not isslow)
  RailWorks.ActivateNode("SL_yellow", isslow)
  RailWorks.ActivateNode("SL_blue", false)
  local isstopped = aspeed_mps < Misc.stopped_mps
  RailWorks.ActivateNode("SL_doors_L", isstopped)
  RailWorks.ActivateNode("SL_doors_R", isstopped)
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
  local show = isend and aidirection:getdirection() ==
                 AiDirection.direction.forward
  RailWorks.ActivateNode("left_ditch_light", show)
  RailWorks.ActivateNode("right_ditch_light", show)
  Call("Fwd_DitchLightLeft:Activate", Misc.intbool(show))
  Call("Fwd_DitchLightRight:Activate", Misc.intbool(show))
end

local function updateplayer(dt)
  power:update(dt)
  adu:update(dt)
  alerter:update(dt)
  ivc:update(dt)
  blight:playerupdate(dt)
  mcnotch:update(dt)
  pantoanim:update(dt)
  gateanim:update(dt)

  setplayercontrols()
  sendconsiststatus()
  setplayersounds(dt)
  setdrivescreen()
  setcutin()
  setadu()
  setpanto()
  setgate()
  setinteriorlights()
  setplayerstatuslights()
  setplayerditchlights()
end

local function updatehelper(dt)
  power:update(dt)
  ivc:update(dt)
  pantoanim:update(dt)
  gateanim:update(dt)

  sendconsiststatus()
  setpanto()
  setgate()
  setinteriorlights()
  setplayerstatuslights()
  sethelperditchlights()
end

local function updateai(dt)
  power:update(dt)
  pantoanim:update(dt)
  gateanim:update(dt)
  aidirection:aiupdate(dt)

  setaisounds()
  setpanto()
  setgate()
  setinteriorlights()
  setaistatuslights()
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

OnControlValueChange = Misc.wraperrors(function(name, index, value)
  if name == "ThrottleAndBrake" then alerter:acknowledge() end

  RailWorks.SetControlValue(name, index, value)
end)

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
