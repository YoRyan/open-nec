--[[
  A class for inter-signal communication of string, number, boolean, and nil
  values between neighboring signals. Each signal can access the values
  broadcast by its neighbors in both the forward and backward directions.

  In the forward direction, signal 1 corresponds to the signal connected to
  link 1 (or link 0 if the signal has just one link), signal 2 corresponds to
  the signal connected to link 2, etc.

                           sig #1  sig #2
  this sig             2              o
     o         /-------|------o-------|-->
  ---|--------------|---------|---------->
     0              1

  In the reverse direction, there can be multiple signals connected to link 0.
  Signal 1 corresponds to the signal connected to the first signal link
  encountered when traveling backwards, signal 2 corresponds to the signal
  connected to the second signal link encountered, etc.

    sig #2  sig #1             this sig
       o________________v         o
  <----|------o---------|--|------|----
  <-----------|----/       ^      0
              ^____________|

  The current signal is *not* aware of any preceding signals until they send
  messages forward first. However, a "send backward to all" function is available
  to transmit a value to any preceding signals regardless of whether or not they
  have been discovered yet. (Individually addressed values take priority over
  this "all" value.)

  Variable names must not contain a period ("."). As long as one of the
  supported types is used, values will be automatically converted to and from
  strings for transmission via signal messages.
]]
local P = {}
InterSignal = P

local iscmessage = 100

local function initstate (self)
  self._nlinks = RailWorks.GetLinkCount()

  -- If there are 2+ links, one of them is link zero, which isn't behind a signal.
  self._nforward = math.max(self._nlinks - 1, 1)
  self._forwardrecv = TupleDict:new{}
  self._forwardrecvall = TupleDict:new{}
  self._forwardsent = TupleDict:new{}

  self._nbackward = 0
  self._backwardrecv = TupleDict:new{}
  self._backwardsent = TupleDict:new{}
  self._backwardsentall = {}
end

-- Create a new InterSignal context.
function P:new ()
  local o = {}
  setmetatable(o, self)
  self.__index = self
  initstate(o)
  return o
end

local function validforwardindex (self, i)
  return i >= 1 and i <= self._nforward
end

local function validbackwardindex (self, i)
  return i >= 1 and i <= self._nbackward
end

-- Read a value from a forward signal.
function P:readforward (index, name)
  if validforwardindex(self, index) then
    return self._forwardrecv[{index, name}] or self._forwardrecvall[{index, name}]
  else
    return nil
  end
end

-- Read a value from a backward signal.
function P:readbackward (index, name)
  if validbackwardindex(self, index) then
    return self._backwardrecv[{index, name}]
  else
    return nil
  end
end

local function totypedstring (v)
  return type(v) .. "." .. tostring(v)
end

local function fromtypedstring (s)
  local _, _, typestr, str = string.find(s, "^([^%.]+)%.(.+)")
  if typestr == nil then
    return nil
  elseif typestr == "number" then
    return tonumber(str)
  elseif typestr == "string" then
    return str
  elseif typestr == "boolean" then
    return str == "true"
  elseif typestr == "nil" then
    return nil
  else
    return nil
  end
end

-- Broadcast a value to a specified forward signal.
function P:sendforward (index, name, value)
  if validforwardindex(self, index)
      and value ~= self._forwardsent[{index, name}] then
    self._forwardsent[{index, name}] = value
    local link
    if self._nlinks == 1 then link = 0
    else link = index end
    RailWorks.SendSignalMessage(
      iscmessage,
      "OpenNEC.isc.1." .. name .. "." .. totypedstring(value),
      1, 1, link)
  end
end

-- Broadcast a value to a specified backward signal.
function P:sendbackward (index, name, value)
  if validbackwardindex(self, index)
      and value ~= self._backwardsent[{index, name}] then
    self._backwardsent[{index, name}] = value
    RailWorks.SendSignalMessage(
      iscmessage,
      "OpenNEC.isc." .. index .. "." .. name .. "." .. totypedstring(value),
      -1, 1, 0)
  end
end

-- Broadcast a value to all signals in the backward direction, even if they
-- haven't sent any messages to us first.
function P:sendbackwardall (name, value)
  if value ~= self._backwardsentall[name] then
    self._backwardsentall[name] = value
    RailWorks.SendSignalMessage(
      iscmessage,
      "OpenNEC.isc.all." .. name .. "." .. totypedstring(value),
      -1, 1, 0)
  end
end

-- Get the number of forward signals.
function P:getnforwardsignals ()
  return self._nforward
end

-- Get the number of backward signals.
function P:getnbackwardsignals ()
  return self._nbackward
end

-- Iterate through all forward signal values for a certain variable. Yields
-- {signal id, value} tuples.
function P:iterforwardvalues (name)
  return Iterator.map(
    function (i, _)
      return i, self:readforward(i, name)
    end,
    Iterator.range(self._nforward)
  )
end

-- Iterate through all backward signal values for a certain variable. Yields
-- {signal id, value} tuples.
function P:iterbackwardvalues (name)
  return Iterator.map(
    function (i, _)
      return i, self:readbackward(i, name)
    end,
    Iterator.range(self._nbackward)
  )
end

local function receiveforwardisc (self, linkindex, msgindex, name, value)
  if linkindex == 0 then
    -- Forward message to link zero - consume it and read the index.
    self._backwardrecv[{msgindex, name}] = value
    self._nbackward = math.max(msgindex, self._nbackward)
  else
    -- Forward message to a nonzero link - increment the index and forward it.
    RailWorks.SendSignalMessage(
      iscmessage,
      "OpenNEC.isc." .. (msgindex + 1) .. "." .. name .. "." .. totypedstring(value),
      1, 1, linkindex)
  end
end

local function receivebackwardisc (self, linkindex, msgindex, name, value)
  if msgindex <= 1 then
    -- Backward message, addressed to us - consume it.
    self._forwardrecv[{math.max(linkindex, 1), name}] = value
  elseif linkindex ~= 0 then
    -- Backward message to a nonzero link, not addressed to us - decrement
    -- the index and forward it.
    RailWorks.SendSignalMessage(
      iscmessage,
      "OpenNEC.isc." .. (msgindex - 1) .. "." .. name .. "." .. totypedstring(value),
      -1, 1, linkindex)
  end
end

local function receivebackwardallisc (self, linkindex, name, value)
  if linkindex ~= 0 then
    -- Backward message to a nonzero link - forward it.
    self._forwardrecvall[{linkindex, name}] = value
    RailWorks.SendSignalMessage(
      iscmessage,
      "OpenNEC.isc.all." .. name .. "." .. totypedstring(value), -1, 1, linkindex)
  elseif self._nlinks == 1 then
    -- Backwards message to link zero, which is the only link - consume it.
    self._forwardrecvall[{1, name}] = value
  end
end

-- Process a signal message sent by another signal, or by the game core.
function P:receivemessage (message, parameter, direction, index)
  if message == iscmessage then
    local _, _, msgindexstr, name, valuestr =
      string.find(parameter, "OpenNEC%.isc%.([%dal]+)%.([^%.]+)%.(.+)")
    if msgindexstr ~= nil then
      local value = fromtypedstring(valuestr)
      if msgindexstr == "all" then
        if direction > 0 then
          receivebackwardallisc(self, index, name, value)
        end
      else
        local msgindex = tonumber(msgindexstr)
        if direction < 0 then
          receiveforwardisc(self, index, msgindex, name, value)
        else
          receivebackwardisc(self, index, msgindex, name, value)
        end
      end
    end
  elseif message == RailWorks.sigmessage.RESET_SIGNAL_STATE then
    initstate(self)
  end
end

return P