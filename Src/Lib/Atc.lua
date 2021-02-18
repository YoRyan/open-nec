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

-- From the main coroutine, create a new Atc context. This will add coroutines
-- to the provided scheduler. The caller should also customize the properties
-- in the config table initialized here.
function Atc.new(scheduler)
  local self = setmetatable({}, Atc)
  self.config = {getspeed_mps=function () return 0 end,
                 getacceleration_mps2=function () return 0 end,
                 getacknowledge=function() return false end,
                 doalert=function () end,
                 -- From the Train Sim World: Northeast Corridor New York manual
                 suppressing_mps2=-0.5,
                 suppression_mps2=-1.5,
                 -- 20 mph
                 restrictspeed_mps=8.94,
                 -- 3 mph
                 speedmargin_mps=1.34}
  self.state = {pulsecode=Atc.pulsecode.restrict,
                alarm=false,
                suppressing=false,
                suppression=false,
                penalty=false,
                _downgrade=Event.new(scheduler),
                _upgrade=Event.new(scheduler)}
  self._sched = scheduler
  self._sched:run(Atc._doupgrades, self)
  return self
end

function Atc._doupgrades(self)
  while true do
    self.state._upgrade:waitfor()
    self.config.doalert()
  end
end

-- Receive a custom signal message.
function Atc.receivemessage(self, message)
  local newcode = self:_getnewpulsecode(message)
  if newcode < self.state.pulsecode then
    self.state._downgrade:trigger()
  elseif newcode > self.state.pulsecode then
    self.state._upgrade:trigger()
  end
  self.state.pulsecode = newcode
end

function Atc._getnewpulsecode(self, message)
  local code = Atc.getpulsecode(message)
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
function Atc.getpulsecode(message)
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