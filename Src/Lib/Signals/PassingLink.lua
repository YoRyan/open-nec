-- Generates events when one end of a consist passes over a signal link.
local P = {}
PassingLink = P

P.event = {frontforward=0,
           frontreverse=1,
           backforward=2,
           backreverse=3}

-- Create a new PassingLink context.
function P:new (conf)
  local o = {_handler=conf.handler}
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Read a train position from an OnConsistPass call and, if appropriate, fire an
-- event.
function P:consistpass
    (prevfrontdist_m, prevbackdist_m, frontdist_m, backdist_m, link)
  if prevfrontdist_m >= 0 and frontdist_m < 0 then
    self._handler(P.event.frontforward, link)
  elseif prevfrontdist_m < 0 and frontdist_m >= 0 then
    self._handler(P.event.frontreverse, link)
  end
  if prevbackdist_m >= 0 and backdist_m < 0 then
    self._handler(P.event.backforward, link)
  elseif prevbackdist_m < 0 and backdist_m >= 0 then
    self._handler(P.event.backreverse, link)
  end
end

return P