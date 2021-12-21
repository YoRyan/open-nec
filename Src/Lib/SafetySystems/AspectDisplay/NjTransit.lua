-- An NJT-style integrated speedometer and ADU display.
--
-- @include Misc.lua
-- @include RailWorks.lua
-- @include RollingStock/Tone.lua
-- @include SafetySystems/Acses/NjtAses.lua
-- @include SafetySystems/AspectDisplay/AspectDisplay.lua
-- @include Signals/NecSignals.lua
-- @include Units.lua
local P = {}
NjTransitAdu = P

local subsystem = {atc = 1, acses = 2}

-- Ensure we have inherited the properties of the base class, PiL-style.
-- We can't run code on initialization in TS, so we do this in :new().
local function inherit(base)
  if getmetatable(base) == nil then
    base.__index = base
    setmetatable(P, base)
  end
end

-- Create a new NjTransitAdu context.
function P:new(conf)
  inherit(Adu)
  local o = Adu:new(conf)
  o._acses = NjtAses:new{
    cabsignal = o._cabsig,
    getbrakesuppression = conf.getbrakesuppression,
    getacknowledge = conf.getacknowledge,
    getspeed_mps = conf.getspeed_mps,
    gettrackspeed_mps = conf.gettrackspeed_mps,
    getconsistlength_m = conf.getconsistlength_m,
    iterspeedlimits = conf.iterspeedlimits,
    iterrestrictsignals = conf.iterrestrictsignals,
    consistspeed_mps = conf.consistspeed_mps,
    alertlimit_mps = o._alertlimit_mps,
    penaltylimit_mps = o._penaltylimit_mps,
    alertwarning_s = o._alertwarning_s
  }
  o._alert = Tone:new{}
  -- ATC on/off state
  o._atcon = true
  -- Communicates the current safety systems target (non-curve) speed limit.
  o._targetspeed_mps = nil
  -- Commmunicates the current signal aspect status.
  o._isclear = nil
  -- Communicates the current safety system in force.
  o._enforcing = nil
  -- Clock time when first entering the overspeed/alert curve state.
  o._overspeed_s = nil
  -- Used to track the player's acknowledgement presses.
  o._acknowledged = false
  -- Used to track the safety system that triggered the last overspeed.
  o._penalty = nil
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Update this system once every frame.
function P:update(dt)
  self._acses:update(dt)

  -- Read the current speed limit. Play tone for any speed increase alerts.
  local targetspeed_mps, enforcing
  local pulsecode = self._cabsig:getpulsecode()
  local isclear = pulsecode == Nec.pulsecode.clear125 or pulsecode ==
                    Nec.pulsecode.clear150
  local atcspeed_mps = self._atcon and
                         CabSignal.amtrakpulsecodespeed_mps(pulsecode) or nil
  local acsesspeed_mps = self._acses:gettargetspeed_mps()
  if atcspeed_mps ~= nil and acsesspeed_mps ~= nil then
    targetspeed_mps = math.min(atcspeed_mps, acsesspeed_mps)
    enforcing = acsesspeed_mps < atcspeed_mps and subsystem.acses or
                  subsystem.atc
  elseif atcspeed_mps ~= nil then
    targetspeed_mps, enforcing = atcspeed_mps, subsystem.atc
  elseif acsesspeed_mps ~= nil then
    targetspeed_mps, enforcing = acsesspeed_mps, subsystem.acses
  else
    targetspeed_mps, enforcing = nil, nil
  end
  local intoservice = self._targetspeed_mps == nil and targetspeed_mps ~= nil
  local speeddec = (self._targetspeed_mps ~= nil and targetspeed_mps ~= nil and
                     self._targetspeed_mps > targetspeed_mps) or
                     (self._isclear and not isclear)
  local speedinc = (self._targetspeed_mps ~= nil and targetspeed_mps ~= nil and
                     self._targetspeed_mps < targetspeed_mps) or
                     (not self._isclear and isclear)
  if intoservice or speedinc then self._alert:trigger() end
  self._targetspeed_mps, self._enforcing = targetspeed_mps, enforcing
  self._isclear = isclear

  -- Read the engineer's controls. Initiate enforcement actions and look for
  -- acknowledgement presses.
  local aspeed_mps = math.abs(self._getspeed_mps())
  local now = RailWorks.GetSimulationTime()
  local acknowledge = self._getacknowledge()
  local suppressed = self._getbrakesuppression()
  local acsespenalty = enforcing == subsystem.acses and aspeed_mps >
                         self._acses:getpenaltycurve_mps()
  local overspeed =
    (enforcing == subsystem.atc and aspeed_mps > targetspeed_mps +
      self._alertlimit_mps) or
      (enforcing == subsystem.acses and aspeed_mps >
        self._acses:getalertcurve_mps())
  local overspeedelapsed =
    self._overspeed_s ~= nil and now - self._overspeed_s > self._alertwarning_s
  if self._penalty == subsystem.atc then
    -- ATC requires a complete stop.
    local penalty = aspeed_mps > Misc.stopped_mps or not acknowledge
    self._overspeed_s = penalty and self._overspeed_s or nil
    self._acknowledged = false
    self._penalty = penalty and subsystem.atc or nil
  elseif self._penalty == subsystem.acses then
    -- ACSES allows a running release.
    local penalty = overspeed or not acknowledge
    self._overspeed_s = penalty and self._overspeed_s or nil
    self._acknowledged = false
    self._penalty = penalty and subsystem.acses or nil
  elseif acsespenalty then
    self._overspeed_s = self._overspeed_s ~= nil and self._overspeed_s or now
    self._acknowledged = false
    self._penalty = subsystem.acses
  elseif overspeedelapsed then
    self._overspeed_s = self._overspeed_s
    self._acknowledged = false
    self._penalty = self._enforcing
  elseif self._overspeed_s ~= nil then
    local acknowledged = self._acknowledged and (suppressed or not overspeed)
    self._overspeed_s = not acknowledged and self._overspeed_s or nil
    self._acknowledged = not acknowledged and
                           (self._acknowledged or acknowledge) or false
    self._penalty = nil
  elseif (overspeed and not suppressed) or speeddec then
    self._overspeed_s = now
    self._acknowledged = false
    self._penalty = nil
  else
    self._overspeed_s = nil
    self._acknowledged = false
    self._penalty = nil
  end
end

-- Set the current ATC enforcement status.
function P:setatcstate(onoff)
  if Misc.isinitialized() then
    if not self._atcon and onoff then
      Misc.showalert("ATC", "Cut In")
    elseif self._atcon and not onoff then
      Misc.showalert("ATC", "Cut Out")
    end
  end
  self._atcon = onoff
end

-- Set the current ACSES enforcement status.
function P:setacsesstate(onoff)
  if Misc.isinitialized() then
    local acseson = self._acses:isrunning()
    if not acseson and onoff then
      Misc.showalert("ACSES", "Cut In")
    elseif acseson and not onoff then
      Misc.showalert("ACSES", "Cut Out")
    end
  end
  self._acses:setrunstate(onoff)
end

-- True if the penalty brake is applied.
function P:ispenalty() return self._penalty ~= nil end

-- True if the alarm is sounding.
function P:isalarm() return self._overspeed_s ~= nil end

-- True if the informational tone is sounding.
function P:isalertplaying() return self._alert:isplaying() end

-- Determine whether or not the current ATC aspect is a clear one.
function P:isclearsignal() return self._isclear end

local function getgreenspeed_mph(self)
  if self:isclearsignal() and not self:acsescutin() then
    return nil
  elseif self._enforcing == subsystem.atc then
    return self._targetspeed_mps ~= nil and self._targetspeed_mps *
             Units.mps.tomph or nil
  elseif self._enforcing == subsystem.acses then
    local curvespeed_mps = self._acses:getcurvespeed_mps()
    return curvespeed_mps ~= nil and curvespeed_mps * Units.mps.tomph or nil
  else
    return nil
  end
end

-- Get the current position of the green speed zone given the current speed.
function P:getgreenzone_mph() return getgreenspeed_mph(self) or 0 end

-- Get the current position of the red speed zone given the current speed.
function P:getredzone_mph()
  local green_mph = getgreenspeed_mph(self)
  if green_mph ~= nil then
    local aspeed_mph = math.abs(self._getspeed_mps()) * Units.mps.tomph
    return aspeed_mph > green_mph and aspeed_mph or 0
  else
    return 0
  end
end

-- Get the current state of the ATC indicator light.
function P:getatcenforcing()
  return self:isalarm() and self._enforcing == subsystem.atc
end

-- Get the current state of the ACSES indicator light.
function P:getacsesenforcing()
  return self:isalarm() and self._enforcing == subsystem.acses
end

-- Get the current state of the ATC system.
function P:atccutin() return self._atcon end

-- Get the current state of the ACSES system.
function P:acsescutin() return self._acses:isrunning() end

return P
