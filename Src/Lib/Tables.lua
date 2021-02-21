-- Library for manipulating data structures built with Lua tables.

Tables = {}
Tables.__index = Tables

-- Iterate through all values in a numeric-indexed table, in order and without
-- indices.
function Tables.values(t)
  local i = 1
  return function (_, _)
    if i <= table.getn(t) then
      local v = t[i]
      i = i + 1
      return v
    else
      return nil
    end
  end, nil, nil
end

-- Apply fn to all values in a numeric-indexed table and return the index of the
-- first value for which fn evaluates to true. If no such value exists, return nil.
function Tables.find(t, fn)
  return table.foreachi(t, function (i, v)
    if fn(v) then
      return i
    else
      return nil
    end
  end)
end