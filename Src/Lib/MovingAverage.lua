-- Library for a simple boxcar moving average computer.

Average = {}
Average.__index = Average

-- Create a new Average context.
function Average.new(nsamples)
  local self = setmetatable({}, Average)
  self._data = {}
  for i = 1, nsamples do
    self._data[i] = 0
  end
  self._length = nsamples
  self._ptr = 1
  return self
end

-- Sample a value.
function Average.sample(self, value)
  self._data[self._ptr] = value
  self._ptr = math.mod(self._ptr, self._length) + 1
end

-- Compute the moving average.
function Average.get(self)
  local sum = 0
  for i = 1, self._length do
    sum = sum + self._data[i]
  end
  return sum/self._length
end