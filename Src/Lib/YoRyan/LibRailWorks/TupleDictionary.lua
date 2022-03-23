-- A dictionary that accepts tuples (as tables) as keys.
local P = {}
TupleDict = P

local terminatingkey = {} -- sentinel value

-- Create a new TupleDict context.
function P:new()
  local o = {}
  setmetatable(o, self)
  return o
end

-- Iterate through key-value pairs. Keys take the form of tables.
-- Do not use :method() syntax; that conflicts with our __index metamethod.
function P.pairs(self)
  return Iterator.chain(Iterator.imap(function(k, t)
    if k == terminatingkey then
      return {pairs({[{}] = t})}
    else
      return {
        Iterator.map(function(k2, v)
          table.insert(k2, 1, k)
          return k2, v
        end, P.pairs(t))
      }
    end
  end, pairs(self)))
end

function P:__index(key)
  local t = self
  for _, k in ipairs(key) do
    if t == nil then
      return nil
    else
      t = rawget(t, k)
    end
  end
  if t == nil then
    return nil
  else
    return rawget(t, terminatingkey)
  end
end

-- TODO: There's no garbage collection of empty tables in the event of deletions.
function P:__newindex(key, value)
  local t = self
  for _, k in ipairs(key) do
    if rawget(t, k) == nil then rawset(t, k, {}) end
    t = rawget(t, k)
  end
  rawset(t, terminatingkey, value)
end

return P
