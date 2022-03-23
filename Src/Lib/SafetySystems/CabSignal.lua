-- A cab signal message tracker that retains the last signal message received.
--
-- It is used by the ATC and ACSES systems, but unlike them, it cannot be reset
-- by the player.
--
-- @include Signals/NecSignals.lua
local P = {}
CabSignal = P

local debugsignals = false

local function initstate(self)
  self._lastsig = {
    pulsecode = Nec.pulsecode.restrict,
    territory = Nec.territory.other
  }
end

-- Create a new CabSignal context.
function P:new(conf)
  local o = {}
  setmetatable(o, self)
  self.__index = self
  initstate(o)
  return o
end

-- Receive a custom signal message and update the stored state.
function P:receivemessage(message)
  local sig = Nec.parsesigmessage(message)
  if sig ~= nil then self._lastsig = sig end
  if debugsignals then Misc.showalert(message) end
end

-- Get the current cab signal pulse code.
function P:getpulsecode() return self._lastsig.pulsecode end

-- Get the current ACSES territory code.
function P:getterritory() return self._lastsig.territory end

-- Get the speed limit, in m/s, that corresponds to a pulse code.
-- Amtrak speed limits.
function P.amtrakpulsecodespeed_mps(pulsecode)
  if pulsecode == Nec.pulsecode.restrict then
    return 20 * Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.approach then
    return 30 * Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.approachmed30 then
    return 30 * Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.approachmed then
    return 45 * Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.cabspeed60 then
    return 60 * Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.cabspeed80 then
    return 80 * Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.clear100 then
    return 100 * Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.clear125 then
    return 125 * Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.clear150 then
    return 150 * Units.mph.tomps
  else
    return nil
  end
end

-- Get the speed limit, in m/s, that corresponds to a pulse code.
-- Metro-North and LIRR speed limits.
function P.mtapulsecodespeed_mps(pulsecode)
  if pulsecode == Nec.pulsecode.restrict then
    return 15 * Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.approach then
    return 30 * Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.approachmed30 then
    return 30 * Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.approachmed then
    return 45 * Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.cabspeed60 then
    return 60 * Units.mph.tomps
  elseif pulsecode == Nec.pulsecode.cabspeed80 or pulsecode ==
    Nec.pulsecode.clear100 or pulsecode == Nec.pulsecode.clear125 or pulsecode ==
    Nec.pulsecode.clear150 then
    return 80 * Units.mph.tomps
  else
    return nil
  end
end

return P
