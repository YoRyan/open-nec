-- A contemporary Amtrak ADU with a combined speed limit display.
--
-- @include Misc.lua
-- @include RailWorks.lua
-- @include RollingStock/Tone.lua
-- @include SafetySystems/Acses/AmtrakAcses.lua
-- @include SafetySystems/AspectDisplay/AspectDisplay.lua
-- @include Signals/NecSignals.lua
-- @include Units.lua
local P = {}
AmtrakCombinedAdu = P

P.aspect = {
  stop = 0,
  restrict = 1,
  approach = 2,
  approachmed30 = 3,
  approachmed45 = 4,
  cabspeed60 = 5,
  cabspeed60off = 6,
  cabspeed80 = 7,
  cabspeed80off = 8,
  clear100 = 9,
  clear125 = 10,
  clear150 = 11
}

local subsystem = {atc = 1, acses = 2}

-- Ensure we have inherited the properties of the base class, PiL-style.
-- We can't run code on initialization in TS, so we do this in :new().
local function inherit(base)
  if getmetatable(base) == nil then
    base.__index = base
    setmetatable(P, base)
  end
end

-- Create a new AmtrakCombinedAdu context.
function P:new(conf)
  inherit(Adu)
  local o = Adu:new(conf)
  o._acses = AmtrakAcses:new{
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
  o._csflasher = Flash:new{
    off_os = Nec.cabspeedflash_s,
    on_os = Nec.cabspeedflash_s
  }
  o._alert = Tone:new{}
  -- ATC on/off state
  o._atcon = true
  -- Communicates the current safety systems speed limit.
  o._speedlimit_mps = nil
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

  -- Read the current cab signal. Set the cab signal flash if needed.
  local pulsecode = self._cabsig:getpulsecode()
  self._csflasher:setflashstate(pulsecode == Nec.pulsecode.cabspeed60 or
                                  pulsecode == Nec.pulsecode.cabspeed80)

  -- Read the current speed limit. Play tone for any speed increase alerts.
  local speedlimit_mps, enforcing
  local atcspeed_mps = self._atcon and
                         CabSignal.amtrakpulsecodespeed_mps(pulsecode) or nil
  local acsesspeed_mps = self._acses:getinforcespeed_mps()
  if atcspeed_mps ~= nil and acsesspeed_mps ~= nil then
    local is150 = pulsecode == Nec.pulsecode.clear150
    speedlimit_mps = math.min(atcspeed_mps, acsesspeed_mps)
    enforcing = (acsesspeed_mps < atcspeed_mps or is150) and subsystem.acses or
                  subsystem.atc
  elseif atcspeed_mps ~= nil then
    speedlimit_mps, enforcing = atcspeed_mps, subsystem.atc
  elseif acsesspeed_mps ~= nil then
    speedlimit_mps, enforcing = acsesspeed_mps, subsystem.acses
  else
    speedlimit_mps, enforcing = nil, nil
  end
  local intoservice = self._speedlimit_mps == nil and speedlimit_mps ~= nil
  local speeddec = self._speedlimit_mps ~= nil and speedlimit_mps ~= nil and
                     self._speedlimit_mps > speedlimit_mps
  local speedinc = self._speedlimit_mps ~= nil and speedlimit_mps ~= nil and
                     self._speedlimit_mps < speedlimit_mps
  if intoservice or speedinc then self._alert:trigger() end
  self._speedlimit_mps, self._enforcing = speedlimit_mps, enforcing

  -- Read the engineer's controls. Initiate enforcement actions and look for
  -- acknowledgement presses.
  local aspeed_mps = math.abs(self._getspeed_mps())
  local now = RailWorks.GetSimulationTime()
  local acknowledge = self._getacknowledge()
  local suppressed = self._getbrakesuppression()
  local acsespenalty = enforcing == subsystem.acses and aspeed_mps >
                         self._acses:getpenaltycurve_mps()
  local overspeed =
    (enforcing == subsystem.atc and aspeed_mps > speedlimit_mps +
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
function P:isalarm()
  -- ACSES forces the alarm on even if the engineer has already acknowledged
  -- and suppressed.
  local aspeed_mps = math.abs(self._getspeed_mps())
  local acsesalarm = self._enforcing == subsystem.acses and aspeed_mps >
                       self._speedlimit_mps + self._alertlimit_mps
  return self._overspeed_s ~= nil or acsesalarm
end

-- True if the informational tone is sounding.
function P:isalertplaying() return self._alert:isplaying() end

-- Get the currently displayed cab signal aspect.
function P:getaspect()
  local acsesmode = self._acses:getmode()
  local atccode = self._cabsig:getpulsecode()
  local cson = self._csflasher:ison()
  if acsesmode == Acses.mode.positivestop then
    return P.aspect.stop
  elseif acsesmode == Acses.mode.approachmed30 then
    return P.aspect.approachmed30
  elseif atccode == Nec.pulsecode.restrict then
    return P.aspect.restrict
  elseif atccode == Nec.pulsecode.approach then
    return P.aspect.approach
  elseif atccode == Nec.pulsecode.approachmed then
    return P.aspect.approachmed45
  elseif atccode == Nec.pulsecode.cabspeed60 then
    return cson and P.aspect.cabspeed60 or P.aspect.cabspeed60off
  elseif atccode == Nec.pulsecode.cabspeed80 then
    return cson and P.aspect.cabspeed80 or P.aspect.cabspeed80off
  elseif atccode == Nec.pulsecode.clear100 then
    return P.aspect.clear100
  elseif atccode == Nec.pulsecode.clear125 then
    return P.aspect.clear125
  elseif atccode == Nec.pulsecode.clear150 then
    return P.aspect.clear150
  else
    return nil
  end
end

-- Determine whether the Metro-North aspect indicators should be lit.
function P:getmnrrilluminated()
  return self._cabsig:getterritory() == Nec.territory.mnrr
end

-- Get the current speed limit in force.
function P:getspeedlimit_mph()
  return
    self._speedlimit_mps ~= nil and self._speedlimit_mps * Units.mps.tomph or
      nil
end

-- Get the current time to penalty counter, if any.
function P:gettimetopenalty_s()
  if self._acses:getmode() == Acses.mode.positivestop then
    local ttp_s = self._acses:gettimetopenalty_s()
    if ttp_s ~= nil then
      return math.floor(ttp_s)
    else
      return nil
    end
  else
    return nil
  end
end

-- Get the current state of the ATC indicator light.
function P:getatcindicator() return self._enforcing == subsystem.atc end

-- Get the current state of the ACSES indicator light.
function P:getacsesindicator() return self._enforcing == subsystem.acses end

-- Get the current state of the ATC system.
function P:atccutin() return self._atcon end

-- Get the current state of the ACSES system.
function P:acsescutin() return self._acses:isrunning() end

return P
