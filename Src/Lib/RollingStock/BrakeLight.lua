-- Class for train brake indicator lights. Player locomotives can send the
-- current status over console messages, and non-player locomotives/coaches can
-- receive them (or use fallback logic).
--
-- @include Misc.lua
-- @include RailWorks.lua
local P = {}
BrakeLight = P

-- Create a new BrakeLight context.
function P:new(conf)
  local o = {
    _messageid = conf.messageid or 10101,
    _getbrakeson = conf.getbrakeson or function()
      return RailWorks.GetControlValue("AirBrakePipePressurePSI", 0) < 100
    end,
    _lastsent = nil,
    _lastrecv = nil
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Update this module every frame.
function P:playerupdate(_)
  local status = self._getbrakeson()
  if status ~= self._lastsent then
    local send = status and "1" or "0"
    RailWorks.Engine_SendConsistMessage(self._messageid, send, 0)
    RailWorks.Engine_SendConsistMessage(self._messageid, send, 1)
    self._lastsent = status
  end
end

-- Receive and process a consist message.
function P:receivemessage(message, argument, direction)
  if message == self._messageid then self._lastrecv = argument == "1" end
end

-- Determine whether the brake indicators should be in the "applied" state.
function P:isapplied()
  if self._lastrecv ~= nil then
    return self._lastrecv
  else
    return self._getbrakeson()
  end
end

return P
