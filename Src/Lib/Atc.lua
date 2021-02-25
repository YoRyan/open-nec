-- Constants, lookup tables, and code for Amtrak's Pennsylvania Railroad-derived
-- pulse code cab signaling and Automatic Train Control system.

Atc = {}
Atc.__index = Atc

Atc.pulsecode = {restrict=0,
                 approach=1,
                 approachmed=2,
                 cabspeed60=3,
                 cabspeed80=4,
                 clear100=5,
                 clear125=6,
                 clear150=7}
Atc.cabspeedflash_s = 0.5
Atc.inittime_s = 3
Atc.debugsignals = false

-- From the main coroutine, create a new Atc context. This will add coroutines
-- to the provided scheduler. The caller should also customize the properties
-- in the config table initialized here.
function Atc.new(scheduler)
  local self = setmetatable({}, Atc)
  self.config = {
    getspeed_mps=function () return 0 end,
    getacceleration_mps2=function () return 0 end,
    getacknowledge=function () return false end,
    doalert=function () end,
    countdown_s=6,
    -- Rates fom the Train Sim World: Northeast Corridor New York manual.
    suppressing_mps2=-0.5,
    suppression_mps2=-1.5,
    -- The suppression deceleration rate is in practice impossible to achieve in
    -- gameplay, so also let the locomotive supply its own suppression condition.
    getsuppression=function () return false end,
    -- 20 mph
    restrictspeed_mps=8.94,
    -- 3 mph
    speedmargin_mps=1.34
  }
  self.state = {
    -- The current pulse code in effect.
    pulsecode=Atc.pulsecode.clear125,
    -- True when the alarm is sounding.
    alarm=false,
    -- True when the suppressing deceleration rate is achieved.
    suppressing=false,
    -- True when the suppression condition is achieved.
    -- 'suppression' implies 'suppressing'.
    suppression=false,
    -- True when a penalty brake is applied.
    penalty=false,

    _enforce=Event.new(scheduler),
  }
  self._sched = scheduler
  self._sched:run(Atc._setsuppress, self)
  self._sched:run(Atc._doenforce, self)
  return self
end

function Atc._setsuppress(self)
  while true do
    local accel_mps2 = self.config.getacceleration_mps2()
    self.state.suppressing =
      accel_mps2 <= self.config.suppressing_mps2 or self.config.getsuppression()
    self.state.suppression =
      accel_mps2 <= self.config.suppression_mps2 or self.config.getsuppression()
    -- Sample every tenth of a second to avoid spurious precision errors.
    self._sched:sleep(0.1)
  end
end

function Atc._doenforce(self)
  while true do
    self._sched:select(
      nil,
      function () return self.state._enforce:poll() end,
      function () return not self:_iscomplying() end)
    -- Alarm phase. Acknowledge the alarm and reach the initial suppressing
    -- deceleration rate.
    self.state.alarm = true
    local acknowledged
    do
      local ack = false
      acknowledged = self._sched:select(
        self.config.countdown_s,
        function ()
          -- The player need only acknowledge the alarm once.
          ack = ack or self.config.getacknowledge()
          return ack and (self.state.suppressing or self:_iscomplying())
        end
      ) == 1
    end
    if acknowledged then
      -- Suppressing phase. Reach the suppression deceleration rate.
      self.state.alarm = false
      local suppressed = self._sched:select(
        self.config.countdown_s,
        function () return self.state.suppression or self:_iscomplying() end
      ) == 1
      if suppressed then
        -- Suppression phase. Maintain the suppression deceleration rate
        -- until the train complies with the speed limit.
        self._sched:select(
          nil,
          function () return not self.state.suppression end,
          function () return self:_iscomplying() end)
        -- From here, return to the beginning of the loop, either to wait for
        -- the next enforcement action or to repeat it immediately.
      else
        self:_penalty()
      end
    else
      self:_penalty()
    end
  end
end

function Atc._iscomplying(self)
  local limit_mps = self:getpulsecodespeed_mps(self.state.pulsecode)
  return self.config.getspeed_mps() <= limit_mps + self.config.speedmargin_mps
end

function Atc._iscomplyingstrict(self)
  local limit_mps = self:getpulsecodespeed_mps(self.state.pulsecode)
  return self.config.getspeed_mps() <= limit_mps
end

-- Get the speed limit, in m/s, that corresponds to a pulse code.
function Atc.getpulsecodespeed_mps(self, pulsecode)
  if pulsecode == Atc.pulsecode.restrict then
    return self.config.restrictspeed_mps
  elseif pulsecode == Atc.pulsecode.approach then
    return 13.4 -- 30 mph
  elseif pulsecode == Atc.pulsecode.approachmed then
    return 20.1 -- 45 mph
  elseif pulsecode == Atc.pulsecode.cabspeed60 then
    return 26.8 -- 60 mph
  elseif pulsecode == Atc.pulsecode.cabspeed80 then
    return 35.8 -- 80 mph
  elseif pulsecode == Atc.pulsecode.clear100 then
    return 44.7 -- 100 mph
  elseif pulsecode == Atc.pulsecode.clear125 then
    return 55.9 -- 125 mph
  elseif pulsecode == Atc.pulsecode.clear150 then
    return 67.1 -- 150 mph
  else
    return nil
  end
end

function Atc._penalty(self)
  self.state.alarm = true
  self.state.penalty = true
  self._sched:select(nil, function ()
    return self.config.getspeed_mps() <= 0 and self.config.getacknowledge()
  end)
  self.state.alarm = false
  self.state.penalty = false
end

-- Receive a custom signal message.
function Atc.receivemessage(self, message)
  local newcode = self:_getnewpulsecode(message)
  if newcode < self.state.pulsecode and self._sched:clock() > 3 then
    self.state._enforce:trigger()
  elseif newcode > self.state.pulsecode then
    self.config.doalert()
  end
  self.state.pulsecode = newcode
  if Atc.debugsignals then
    self._sched:print(message)
  end
end

function Atc._getnewpulsecode(self, message)
  local code = self:getpulsecode(message)
  if code ~= nil then
    return code
  end
  local power = Power.getchangepoint(message)
  if power ~= nil then
    -- Power switch signal. No change.
    return self.state.pulsecode
  end
  self._sched:print("WARNING:\nUnknown signal '" .. message .. "'")
  return Atc.pulsecode.restrict
end

-- Get the pulse code that corresponds to a signal message. If nil, then the
-- message is of an unknown format.
function Atc.getpulsecode(self, message)
  -- Amtrak/NJ Transit signals
  if string.sub(message, 1, 3) == "sig" then
    local code = string.sub(message, 4, 4)
    -- DTG "Clear"
    if code == "1" then
      return Atc.pulsecode.clear125
    elseif code == "2" then
      return Atc.pulsecode.cabspeed80
    elseif code == "3" then
      return Atc.pulsecode.cabspeed60
    -- DTG "Approach Limited (45mph)"
    elseif code == "4" then
      return Atc.pulsecode.approachmed
    -- DTG "Approach Medium (30mph)"
    elseif code == "5" then
      return Atc.pulsecode.approach
    -- DTG "Approach (30mph)"
    elseif code == "6" then
      return Atc.pulsecode.approach
    elseif code == "7" then
      return Atc.pulsecode.restrict
    -- DTG "Ignore"
    elseif code == "8" then
      return self.state.pulsecode
    else
      return nil
    end
  -- Metro-North signals
  elseif string.find(message, "[MN]") == 1 then
    local code = string.sub(message, 2, 3)
    -- DTG "Clear"
    if code == "10" then
      return Atc.pulsecode.clear125
    -- DTG "Approach Limited (45mph)"
    elseif code == "11" then
      return Atc.pulsecode.approachmed
    -- DTG "Approach Medium (30mph)"
    elseif code == "12" then
      return Atc.pulsecode.approach
    elseif code == "13" or code == "14" then
      return Atc.pulsecode.restrict
    -- DTG "Stop"
    elseif code == "15" then
      return Atc.pulsecode.restrict
    else
      return nil
    end
  else
    return nil
  end
end