-- Library for manipulating data structures built with Lua tables.

Tables = {}
Tables.__index = Tables

-- Copy the provided iterator expression list into a table.
function Tables.fromiterator(...)
  local t = {}
  for k, v in unpack(arg) do
    t[k] = v
  end
  return t
end