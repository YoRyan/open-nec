-- A contemporary Amtrak ADU with a combined speed limit display.
--
-- @include YoRyan/LibRailWorks/Misc.lua
-- @include YoRyan/LibRailWorks/RailWorks.lua
-- @include YoRyan/LibRailWorks/RollingStock/Tone.lua
-- @include SafetySystems/Acses/AmtrakAcses.lua
-- @include SafetySystems/AspectDisplay/AspectDisplay.lua
-- @include NecSignals.lua
-- @include YoRyan/LibRailWorks/Units.lua
local P = {}
AmtrakCombinedAdu = P

P.aspect = {
  stop = 0,
  restrict = 1,
  approach = 2,
  approachmed30 = 3,
  approachmed45 = 4,
  cabspeed60 = 5,
  cabspeed60off = 5.5,
  cabspeed80 = 6,
  cabspeed80off = 6.5,
  clear100 = 7,
  clear125 = 8,
  clear150 = 9
}

local subsystem = {atc = 1, acses = 2}
local event = {
  speeddowngrade = 1,
  speedupgrade = 2,
  aspectdowngrade = 3,
  aspectupgrade = 4
}

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
  -- Clock time when first entering the overspeed/alert curve state.
  o._overspeed_s = nil
  -- Used to track the player's acknowledgement presses.
  o._acknowledged = false
  -- Used to track the safety system that triggered the last overspeed.
  o._penalty = nil
  o._lastspeedlimit_mps = nil
  o._lastaspect = nil
  setmetatable(o, self)
  self.__index = self
  return o
end

local function getpulsecode(self) return self._cabsig:getpulsecode() end

local function getatcspeed_mps(self)
  local pulsecode = getpulsecode(self)
  return self._atcon and CabSignal.amtrakpulsecodespeed_mps(pulsecode) or nil
end

local function getacsesspeed_mps(self) return self._acses:getcivilspeed_mps() end

local function getacsesmode(self) return self._acses:getmode() end

local function getspeedlimit_mps(self)
  local acsesmode = getacsesmode(self)
  if acsesmode == Acses.mode.positivestop then
    return 0
  else
    local atcspeed_mps = getatcspeed_mps(self)
    local acsesspeed_mps = getacsesspeed_mps(self)
    if atcspeed_mps ~= nil and acsesspeed_mps ~= nil then
      return acsesspeed_mps < atcspeed_mps and acsesspeed_mps or atcspeed_mps
    elseif atcspeed_mps ~= nil then
      return atcspeed_mps
    else
      return acsesspeed_mps
    end
  end
end

local function getenforcingsubsystem(self)
  local acsesmode = getacsesmode(self)
  if acsesmode == Acses.mode.positivestop then
    return subsystem.acses
  else
    local atcspeed_mps = getatcspeed_mps(self)
    local acsesspeed_mps = getacsesspeed_mps(self)
    if atcspeed_mps ~= nil and acsesspeed_mps ~= nil then
      local is150 = getpulsecode(self) == Nec.pulsecode.clear150
      return (acsesspeed_mps < atcspeed_mps or is150) and subsystem.acses or
               subsystem.atc
    elseif atcspeed_mps ~= nil then
      return subsystem.atc
    elseif acsesspeed_mps ~= nil then
      return subsystem.acses
    else
      return nil
    end
  end
end

local function getevent(self)
  local ret

  local speedlimit_mps = getspeedlimit_mps(self)
  if self._lastspeedlimit_mps == nil and speedlimit_mps ~= nil then
    ret = event.speedupgrade
  elseif self._lastspeedlimit_mps ~= nil and speedlimit_mps ~= nil then
    if self._lastspeedlimit_mps < speedlimit_mps then
      ret = event.speedupgrade
    elseif self._lastspeedlimit_mps > speedlimit_mps then
      ret = event.speeddowngrade
    end
  end

  local aspect = self:getaspect()
  if self._lastaspect == nil and aspect ~= nil then
    ret = event.aspectupgrade
  elseif self._lastaspect ~= nil and aspect ~= nil then
    local lastaspectf = math.floor(self._lastaspect)
    local aspectf = math.floor(aspect)
    if lastaspectf < aspectf then
      ret = event.aspectupgrade
    elseif lastaspectf > aspectf then
      ret = event.aspectdowngrade
    end
  end

  self._lastspeedlimit_mps = speedlimit_mps
  self._lastaspect = aspect
  return ret
end

-- Update this system once every frame.
function P:update(dt)
  self._acses:update(dt)

  -- Read the current cab signal. Set the cab signal flash if needed.
  local pulsecode = getpulsecode(self)
  self._csflasher:setflashstate(pulsecode == Nec.pulsecode.cabspeed60 or
                                  pulsecode == Nec.pulsecode.cabspeed80)

  -- Read the current speed limit. Play tone for any speed increase alerts.
  local evt = getevent(self)
  if evt == event.speedupgrade or (self._atcon and evt == event.aspectupgrade) then
    self._alert:trigger()
  end

  -- Read the engineer's controls. Initiate enforcement actions and look for
  -- acknowledgement presses.
  local aspeed_mps = math.abs(self:_getspeed_mps())
  local now = RailWorks.GetSimulationTime()
  local acknowledge = self._getacknowledge()
  local suppressed = self._getbrakesuppression()
  local enforcing = getenforcingsubsystem(self) -- easiest way to avoid nils
  local speedlimit_mps = getspeedlimit_mps(self)
  local atcoverspeed = enforcing == subsystem.atc and aspeed_mps >
                         speedlimit_mps + self._alertlimit_mps
  local acsesoverspeed = enforcing == subsystem.acses and aspeed_mps >
                           self._acses:getalertcurve_mps()
  local acsespenalty = enforcing == subsystem.acses and aspeed_mps >
                         self._acses:getpenaltycurve_mps()
  local overspeed = atcoverspeed or acsesoverspeed
  local overspeedelapsed =
    self._overspeed_s ~= nil and now - self._overspeed_s > self._alertwarning_s
  local downgrade = evt == event.speeddowngrade or
                      (self._atcon and evt == event.aspectdowngrade)
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
    self._penalty = enforcing
  elseif self._overspeed_s ~= nil then
    local acknowledged = self._acknowledged and (suppressed or not overspeed)
    self._overspeed_s = not acknowledged and self._overspeed_s or nil
    self._acknowledged = not acknowledged and
                           (self._acknowledged or acknowledge) or false
    self._penalty = nil
  elseif (overspeed and not suppressed) or downgrade then
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
  local isacses = getenforcingsubsystem(self) == subsystem.acses
  local aspeed_mps = math.abs(self:_getspeed_mps())
  local acsesalarm = isacses and aspeed_mps > self._acses:getalertcurve_mps()
  return self._overspeed_s ~= nil or acsesalarm
end

-- True if the informational tone is sounding.
function P:isalertplaying() return self._alert:isplaying() end

-- Get the currently displayed cab signal aspect.
function P:getaspect()
  local acsesmode = getacsesmode(self)
  local pulsecode = getpulsecode(self)
  local cson = self._csflasher:ison()
  if acsesmode == Acses.mode.positivestop then
    return P.aspect.stop
  elseif pulsecode == Nec.pulsecode.restrict then
    return P.aspect.restrict
  elseif pulsecode == Nec.pulsecode.approach then
    return P.aspect.approach
  elseif pulsecode == Nec.pulsecode.approachmed30 then
    return P.aspect.approachmed30
  elseif pulsecode == Nec.pulsecode.approachmed then
    return P.aspect.approachmed45
  elseif pulsecode == Nec.pulsecode.cabspeed60 then
    return cson and P.aspect.cabspeed60 or P.aspect.cabspeed60off
  elseif pulsecode == Nec.pulsecode.cabspeed80 then
    return cson and P.aspect.cabspeed80 or P.aspect.cabspeed80off
  elseif pulsecode == Nec.pulsecode.clear100 then
    return P.aspect.clear100
  elseif pulsecode == Nec.pulsecode.clear125 then
    return P.aspect.clear125
  elseif pulsecode == Nec.pulsecode.clear150 then
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
  local speedlimit_mps = getspeedlimit_mps(self)
  return speedlimit_mps ~= nil and speedlimit_mps * Units.mps.tomph or nil
end

-- Get the current time to penalty counter, if any.
function P:gettimetopenalty_s()
  if getacsesmode(self) == Acses.mode.positivestop then
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
function P:getatcindicator() return getenforcingsubsystem(self) == subsystem.atc end

-- Get the current state of the ACSES indicator light.
function P:getacsesindicator()
  return getenforcingsubsystem(self) == subsystem.acses
end

-- Get the current state of the ATC system.
function P:atccutin() return self._atcon end

-- Get the current state of the ACSES system.
function P:acsescutin() return self._acses:isrunning() end

return P
