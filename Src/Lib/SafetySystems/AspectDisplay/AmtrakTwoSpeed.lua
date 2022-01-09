-- A 2000's-era Amtrak ADU with a separate signal and track speed limit displays.
--
-- We assume it is not possible to display 100, 125, or 150 mph signal speeds,
-- so we will use the track speed limit display to present them.
--
-- @include Misc.lua
-- @include RailWorks.lua
-- @include RollingStock/Tone.lua
-- @include SafetySystems/Acses/AmtrakAcses.lua
-- @include SafetySystems/AspectDisplay/AspectDisplay.lua
-- @include Signals/NecSignals.lua
-- @include Units.lua
local P = {}
AmtrakTwoSpeedAdu = P

P.aspect = {
  stop = 0,
  restrict = 1,
  approach = 2,
  approachmed = 3,
  cabspeed = 4,
  cabspeedoff = 5,
  clear = 6
}
P.square = {none = -1, signal = 0, track = 1}

local subsystem = {atc = 1, acses = 2}

-- Ensure we have inherited the properties of the base class, PiL-style.
-- We can't run code on initialization in TS, so we do this in :new().
local function inherit(base)
  if getmetatable(base) == nil then
    base.__index = base
    setmetatable(P, base)
  end
end

-- Create a new AmtrakTwoSpeedAdu context.
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
  o._alert = Tone:new{time_s = conf.alerttone_s}
  -- Flashes the signal speed on the civil speed display if it *is* the limiting
  -- speed.
  o._sigspeedflasher = Flash:new{off_s = 0.5, on_s = 1.5}
  -- Briefly shows the signal speed on the civil speed display if it is *not* the
  -- limiting speed.
  o._showsigspeed = Tone:new{time_s = 2}
  -- ATC on/off state
  o._atcon = true
  -- Communicates the current ATC-enforced limit.
  o._atcspeed_mps = nil
  -- Communicates the current ACSES-enforced speed limit.
  o._acsesspeed_mps = nil
  -- Communicates the current safety system in force.
  o._enforcing = nil
  -- Clock time when first entering the overspeed/alert curve state.
  o._overspeed_s = nil
  -- Used to track the player's acknowledgement presses.
  o._acknowledged = false
  -- Used to track the safety system that triggered the last overspeed.
  o._penalty = nil
  o._truesignalspeed_mph = nil
  o._civilspeed_mph = nil
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
  local canshowsigspeed = self:_canshowpulsecode(pulsecode)

  -- Read the current speed limits. Play tone for any speed increase alerts. Set
  -- the signal limit flashers if needed.
  local enforcing, flashsigspeed
  local atcspeed_mps = self._atcon and
                         CabSignal.amtrakpulsecodespeed_mps(pulsecode) or nil
  local acsesspeed_mps = self._acses:getcivilspeed_mps()
  if atcspeed_mps ~= nil and acsesspeed_mps ~= nil then
    local is150 = pulsecode == Nec.pulsecode.clear150
    enforcing = (acsesspeed_mps < atcspeed_mps or is150) and subsystem.acses or
                  subsystem.atc
    flashsigspeed = atcspeed_mps < acsesspeed_mps and not canshowsigspeed
  elseif atcspeed_mps ~= nil then
    enforcing, flashsigspeed = subsystem.atc, not canshowsigspeed
  elseif acsesspeed_mps ~= nil then
    enforcing, flashsigspeed = subsystem.acses, false
  else
    enforcing, flashsigspeed = nil, false
  end
  local intoservice = (self._atcspeed_mps == nil and atcspeed_mps ~= nil) or
                        (self._acsesspeed_mps == nil and acsesspeed_mps ~= nil)
  local speeddec = (self._atcspeed_mps ~= nil and atcspeed_mps ~= nil and
                     self._atcspeed_mps > atcspeed_mps) or
                     (self._acsesspeed_mps ~= nil and acsesspeed_mps ~= nil and
                       self._acsesspeed_mps > acsesspeed_mps)
  local speedinc = (self._atcspeed_mps ~= nil and atcspeed_mps ~= nil and
                     self._atcspeed_mps < atcspeed_mps) or
                     (self._acsesspeed_mps ~= nil and acsesspeed_mps ~= nil and
                       self._acsesspeed_mps < acsesspeed_mps)
  if intoservice or speedinc then self._alert:trigger() end
  if self._atcspeed_mps ~= atcspeed_mps and not canshowsigspeed then
    self._showsigspeed:trigger()
  end
  self._atcspeed_mps, self._acsesspeed_mps = atcspeed_mps, acsesspeed_mps
  self._enforcing = enforcing
  self._sigspeedflasher:setflashstate(flashsigspeed)

  -- Read the engineer's controls. Initiate enforcement actions and look for
  -- acknowledgement presses.
  local aspeed_mps = math.abs(self:_getspeed_mps())
  local now = RailWorks.GetSimulationTime()
  local acknowledge = self._getacknowledge()
  local suppressed = self._getbrakesuppression()
  local acsespenalty = enforcing == subsystem.acses and aspeed_mps >
                         self._acses:getpenaltycurve_mps()
  local overspeed = (enforcing == subsystem.atc and aspeed_mps > atcspeed_mps +
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

-- True if the ADU model is capable of displaying the supplied cab signal pulse
-- code.
function P:_canshowpulsecode(pulsecode)
  return pulsecode ~= Nec.pulsecode.clear100 and pulsecode ~=
           Nec.pulsecode.clear125 and pulsecode ~= Nec.pulsecode.clear150
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

-- Get the current ATC enforcement status.
function P:getatcstate() return self._atcon end

-- Get the current ACSES enforcement status.
function P:getacsesstate() return self._acses:isrunning() end

-- True if the penalty brake is applied.
function P:ispenalty() return self._penalty ~= nil end

-- True if the alarm is sounding.
function P:isalarm()
  -- ACSES forces the alarm on even if the engineer has already acknowledged
  -- and suppressed.
  local aspeed_mps = math.abs(self:_getspeed_mps())
  local acsesalarm = self._enforcing == subsystem.acses and aspeed_mps >
                       self._acsesspeed_mps + self._alertlimit_mps
  return self._overspeed_s ~= nil or acsesalarm
end

-- True if the informational tone is sounding.
function P:isalertplaying() return self._alert:isplaying() end

-- Get the currently displayed cab signal aspect.
function P:getaspect()
  local acsesmode = self._acses:getmode()
  local atccode = self._cabsig:getpulsecode()
  if acsesmode == Acses.mode.positivestop then
    return P.aspect.stop
  elseif acsesmode == Acses.mode.approachmed30 or atccode ==
    Nec.pulsecode.approachmed then
    return P.aspect.approachmed
  elseif atccode == Nec.pulsecode.restrict then
    return P.aspect.restrict
  elseif atccode == Nec.pulsecode.approach then
    return P.aspect.approach
  elseif atccode == Nec.pulsecode.cabspeed60 or atccode ==
    Nec.pulsecode.cabspeed80 then
    local cson = self._csflasher:ison()
    return cson and P.aspect.cabspeed or P.aspect.cabspeedoff
  elseif atccode == Nec.pulsecode.clear100 or atccode == Nec.pulsecode.clear125 or
    atccode == Nec.pulsecode.clear150 then
    return P.aspect.clear
  else
    return nil
  end
end

-- Get the current signal speed limit, which is influenced by both ATC and ACSES.
-- Some speeds cannot be displayed by any Dovetail ADU; these will be displayed
-- using the civil speed limit display.
function P:getsignalspeed_mph()
  local acsesmode = self._acses:getmode()
  local atccode = self._cabsig:getpulsecode()
  if acsesmode == Acses.mode.positivestop then
    return 0
  elseif acsesmode == Acses.mode.approachmed30 then
    return 30
  elseif atccode == Nec.pulsecode.restrict then
    return 20
  elseif atccode == Nec.pulsecode.approach then
    return 30
  elseif atccode == Nec.pulsecode.approachmed then
    return 45
  elseif atccode == Nec.pulsecode.cabspeed60 then
    return 60
  elseif atccode == Nec.pulsecode.cabspeed80 then
    return 80
  else
    return nil
  end
end

-- Get the current civil speed limit. Some signal speeds cannot be displayed by
-- any Dovetail ADU; they are displayed here.
function P:getcivilspeed_mph()
  local atccode = self._cabsig:getpulsecode()
  local truesigspeed_mph
  if atccode == Nec.pulsecode.clear100 then
    truesigspeed_mph = 100
  elseif atccode == Nec.pulsecode.clear125 then
    truesigspeed_mph = 125
  elseif atccode == Nec.pulsecode.clear150 then
    truesigspeed_mph = 150
  else
    truesigspeed_mph = nil
  end
  if self._sigspeedflasher:getflashstate() then
    return self._sigspeedflasher:ison() and truesigspeed_mph or nil
  elseif self._showsigspeed:isplaying() then
    return truesigspeed_mph
  else
    return self._acsesspeed_mps ~= nil and self._acsesspeed_mps *
             Units.mps.tomph or nil
  end
end

-- Get the current indicator light that is illuminated, if any.
function P:getsquareindicator()
  if self._enforcing == subsystem.atc then
    return P.square.signal
  elseif self._enforcing == subsystem.acses then
    return P.square.track
  else
    return P.square.none
  end
end

return P
