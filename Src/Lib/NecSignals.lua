-- Constants and lookup tables for Northeast Corridor signaling systems.
local P = {}
Nec = P

P.pulsecode = {
  restrict = 10,
  approach = 20,
  approachmed30 = 21,
  approachmed = 30,
  cabspeed60 = 31,
  cabspeed80 = 32,
  clear100 = 41,
  clear125 = 40,
  clear150 = 42
}

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
-- ("pulsecode") and ACSES current territory ("territory"). Or, returns nil if
-- the message cannot be parsed.
function P.parsesigmessage(message)
  local pulsecode, territory
  -- Amtrak/NJ Transit signals
  do
    local _, _, sig = string.find(message, "^sig(%d)")
    if sig ~= nil then
      territory = P.territory.other
      if sig == "1" then
        pulsecode = P.pulsecode.clear125
      elseif sig == "2" then
        pulsecode = P.pulsecode.cabspeed80
      elseif sig == "3" then
        pulsecode = P.pulsecode.cabspeed60
      elseif sig == "4" then
        pulsecode = P.pulsecode.approachmed
      elseif sig == "5" then
        pulsecode = P.pulsecode.approachmed
      elseif sig == "6" then
        pulsecode = P.pulsecode.approach
      elseif sig == "7" then
        pulsecode = P.pulsecode.restrict
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
      elseif sig == "1" and speed == "125" then
        pulsecode = P.pulsecode.clear125
      elseif sig == "1" and speed == "100" then
        pulsecode = P.pulsecode.clear100
      elseif sig == "2" and speed == "100" then
        pulsecode = P.pulsecode.clear100
      elseif sig == "2" and speed == "80" then
        pulsecode = P.pulsecode.cabspeed80
      elseif sig == "3" and speed == "60" then
        pulsecode = P.pulsecode.cabspeed60
      elseif sig == "4" and speed == "45" then
        pulsecode = P.pulsecode.approachmed
      elseif sig == "5" and speed == "30" then
        pulsecode = P.pulsecode.approachmed
      elseif sig == "6" and speed == "30" then
        pulsecode = P.pulsecode.approach
      elseif sig == "7" and speed == "20" then
        pulsecode = P.pulsecode.restrict
      end
    end
  end
  -- Metro-North signals
  do
    local _, _, code = string.find(message, "^[MN](%d%d)")
    if code ~= nil then
      territory = P.territory.mnrr
      if code == "10" then
        pulsecode = P.pulsecode.clear125
      elseif code == "11" then
        pulsecode = P.pulsecode.approachmed
      elseif code == "12" then
        pulsecode = P.pulsecode.approach
      elseif code == "13" or code == "14" then
        pulsecode = P.pulsecode.restrict
      elseif code == "15" then
        pulsecode = P.pulsecode.restrict
      end
    end
  end
  if pulsecode == nil or territory == nil then
    return nil
  else
    return {pulsecode = pulsecode, territory = territory}
  end
end

return P
