-- Library for a simple boxcar moving average computer.
local P = {}
Average = P

-- Create a new Average context.
function P:new(conf)
  local nsamples = conf.nsamples or 1
  local data = {}
  for i = 1, nsamples do data[i] = 0 end
  local o = {_data = data, _length = nsamples, _ptr = 1}
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Sample a value.
function P:sample(value)
  self._data[self._ptr] = value
  self._ptr = math.mod(self._ptr, self._length) + 1
end

-- Compute the moving average.
function P:get()
  local sum = 0
  for i = 1, self._length do sum = sum + self._data[i] end
  return sum / self._length
end

return P
