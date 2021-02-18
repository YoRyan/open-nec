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