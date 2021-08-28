-- Constants and lookup tables for Northeast Corridor signaling systems.
local P = {}
Nec = P

P.pulsecode = {
  restrict = 0,
  approach = 1,
  approachmed = 2,
  cabspeed60 = 3,
  cabspeed80 = 4,
  clear100 = 5,
  clear125 = 6,
  clear150 = 7
}

P.interlock = {none = 0, approachmed45to30 = 1, approachmed30 = 2}

P.territory = {other = 0, mnrr = 1}

P.cabspeedflash_s = 0.5

P.waysidehead = {
  blank = 0,
  green = 1,
  amber = 2,
  red = 3,
  lunar = 4,
  white = 5,
  flashgreen = 10,
  flashamber = 11,
  flashwhite = 12
}

P.waysideflash_s = 0.5

-- Determine if the provided wayside head state will require a continuous flash
-- effect.
function P.iswaysideflash(head) return head >= P.waysidehead.flashgreen end

-- Parse a signal message. Returns an object with the ATC pulse code
-- ("pulsecode"), ACSES interlock state ("interlock"), and ACSES current
-- territory ("territory"). Or, returns nil if the message cannot be parsed.
function P.parsesigmessage(message)
  local pulsecode, interlock, territory
  -- Amtrak/NJ Transit signals
  do
    local _, _, sig = string.find(message, "^sig(%d)")
    if sig ~= nil then
      territory = P.territory.other
      if sig == "1" then
        pulsecode = P.pulsecode.clear125
        interlock = P.interlock.none
      elseif sig == "2" then
        pulsecode = P.pulsecode.cabspeed80
        interlock = P.interlock.none
      elseif sig == "3" then
        pulsecode = P.pulsecode.cabspeed60
        interlock = P.interlock.none
      elseif sig == "4" then
        pulsecode = P.pulsecode.approachmed
        interlock = P.interlock.none
      elseif sig == "5" then
        pulsecode = P.pulsecode.approachmed
        interlock = P.interlock.approachmed30
      elseif sig == "6" then
        pulsecode = P.pulsecode.approach
        interlock = P.interlock.none
      elseif sig == "7" then
        pulsecode = P.pulsecode.restrict
        interlock = P.interlock.none
      end
    end
  end
  -- Washington-Baltimore signals (a subset of the standard Amtrak/NJT signals)
  do
    local _, _, sig, speed = string.find(message, "^sig(%d)speed(%d+)$")
    if sig ~= nil then
      territory = P.territory.other
      if sig == "1" and speed == "150" then
        pulsecode = P.pulsecode.clear150
        interlock = P.interlock.none
      elseif sig == "1" and speed == "125" then
        pulsecode = P.pulsecode.clear125
        interlock = P.interlock.none
      elseif sig == "1" and speed == "100" then
        pulsecode = P.pulsecode.clear100
        interlock = P.interlock.none
      elseif sig == "2" and speed == "100" then
        pulsecode = P.pulsecode.clear100
        interlock = P.interlock.none
      elseif sig == "2" and speed == "80" then
        pulsecode = P.pulsecode.cabspeed80
        interlock = P.interlock.none
      elseif sig == "3" and speed == "60" then
        pulsecode = P.pulsecode.cabspeed60
        interlock = P.interlock.none
      elseif sig == "4" and speed == "45" then
        pulsecode = P.pulsecode.approachmed
        interlock = P.interlock.none
      elseif sig == "5" and speed == "30" then
        pulsecode = P.pulsecode.approachmed
        interlock = P.interlock.approachmed30
      elseif sig == "6" and speed == "30" then
        pulsecode = P.pulsecode.approach
        interlock = P.interlock.none
      elseif sig == "7" and speed == "20" then
        pulsecode = P.pulsecode.restrict
        interlock = P.interlock.none
      end
    end
  end
  -- Metro-North signals
  do
    local _, _, code = string.find(message, "^[MN](%d%d)$")
    if code ~= nil then
      territory = P.territory.mnrr
      if code == "10" then
        pulsecode = P.pulsecode.clear125
        interlock = P.interlock.none
      elseif code == "11" then
        pulsecode = P.pulsecode.approachmed
        interlock = P.interlock.none
      elseif code == "12" then
        pulsecode = P.pulsecode.approach
        interlock = P.interlock.none
      elseif code == "13" or code == "14" then
        pulsecode = P.pulsecode.restrict
        interlock = P.interlock.none
      elseif code == "15" then
        pulsecode = P.pulsecode.restrict
        interlock = P.interlock.none
      end
    end
  end
  if pulsecode == nil or interlock == nil or territory == nil then
    return nil
  else
    return {pulsecode = pulsecode, interlock = interlock, territory = territory}
  end
end

return P
