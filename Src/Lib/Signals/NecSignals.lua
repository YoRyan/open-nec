-- Constants and lookup tables for Northeast Corridor signaling systems.
local P = {}
Nec = P

P.pulsecode = {restrict=0,
               approach=1,
               approachmed=2,
               cabspeed60=3,
               cabspeed80=4,
               clear100=5,
               clear125=6,
               clear150=7}

P.acsescode = {none=0,
               approachmed45to30=1,
               approachmed30=2}

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
function P.iswaysideflash (head)
  return head >= P.waysidehead.flashgreen
end

-- Get the Amtrak/NJ Transit signal message that corresponds to a combo of ATC
-- and ACSES status codes. Is backwards compatible with Dovetail engine scripts.
function P.amtraksigmessage (pulsecode, acsescode)
  local prefix
  if pulsecode == P.pulsecode.restrict then
    prefix = "sig8"
  elseif pulsecode == P.pulsecode.approach then
    prefix = "sig6"
  elseif pulsecode == P.pulsecode.approachmed then
    prefix = "sig5"
  elseif pulsecode == P.pulsecode.cabspeed60 then
    prefix = "sig3"
  elseif pulsecode == P.pulsecode.cabspeed80 then
    prefix = "sig2"
  elseif pulsecode == P.pulsecode.clear100
      or pulsecode == P.pulsecode.clear125
      or pulsecode == P.pulsecode.clear150 then
    prefix = "sig1"
  else
    prefix = "sig0"
  end
  return prefix .. "spd0.OpenNEC.cab.."
    .. tostring(pulsecode) .. "." .. tostring(acsescode)
end

-- Parse a signal message. Returns the communicated ATC and ACSES status codes.
-- Returns nil if the message cannot be parsed.
function P.parsesigmessage (message)
  -- OpenNEC signals
  do
    local _, _, pulsecode, acsescode =
      string.find(message, "%.OpenNEC%.cab%.%.([^%.]+)%.([^%.]+)")
    if pulsecode ~= nil then
      return tonumber(pulsecode), tonumber(acsescode)
    end
  end
  -- Washington-Baltimore signals
  do
    local _, _, sig, speed = string.find(message, "sig(%d)speed(%d+)")
    if sig ~= nil then
      if sig == "1" and speed == "150" then
        return P.pulsecode.clear150, P.acsescode.none
      elseif sig == "1" and speed == "125" then
        return P.pulsecode.clear125, P.acsescode.none
      elseif sig == "1" and speed == "100" then
        return P.pulsecode.clear100, P.acsescode.none
      elseif sig == "2" and speed == "100" then
        return P.pulsecode.clear100, P.acsescode.none
      elseif sig == "2" and speed == "80" then
        return P.pulsecode.cabspeed80, P.acsescode.none
      elseif sig == "3" and speed == "60" then
        return P.pulsecode.cabspeed60, P.acsescode.none
      elseif sig == "4" and speed == "45" then
        return P.pulsecode.approachmed, P.acsescode.none
      elseif sig == "5" and speed == "30" then
        return P.pulsecode.approachmed, P.acsescode.approachmed30
      elseif sig == "6" and speed == "30" then
        return P.pulsecode.approach, P.acsescode.none
      elseif sig == "7" and speed == "20" then
        return P.pulsecode.restrict, P.acsescode.none
      end
    end
  end
  -- Amtrak/NJ Transit signals
  do
    local _, _, sig = string.find(message, "sig(%d)")
    if sig ~= nil then
      if sig == "1" then
        return P.pulsecode.clear125, P.acsescode.none
      elseif sig == "2" then
        return P.pulsecode.cabspeed80, P.acsescode.none
      elseif sig == "3" then
        return P.pulsecode.cabspeed60, P.acsescode.none
      elseif sig == "4" then
        return P.pulsecode.approachmed, P.acsescode.none
      elseif sig == "5" then
        return P.pulsecode.approachmed, P.acsescode.approachmed30
      elseif sig == "6" then
        return P.pulsecode.approach, P.acsescode.none
      elseif sig == "7" then
        return P.pulsecode.restrict, P.acsescode.none
      end
    end
  end
  -- Metro-North signals
  do
    local _, _, code = string.find(message, "[MN](%d%d)")
    if code ~= nil then
      if code == "10" then
        return P.pulsecode.clear125, P.acsescode.none
      elseif code == "11" then
        return P.pulsecode.approachmed, P.acsescode.none
      elseif code == "12" then
        return P.pulsecode.approach, P.acsescode.none
      elseif code == "13" or code == "14" then
        return P.pulsecode.restrict, P.acsescode.none
      elseif code == "15" then
        return P.pulsecode.restrict, P.acsescode.none
      end
    end
  end
  return nil, nil
end

return P