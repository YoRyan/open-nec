-- Library for manipulating key-value iterators.

Iterator = {}
Iterator.__index = Iterator

-- Copy the keys and values from the provided iterator into a table.
function Iterator.totable(...)
  local t = {}
  for k, v in unpack(arg) do
    t[k] = v
  end
  return t
end

-- Return a new iterator with the function fn(k, v) -> k2, v2 applied to all
-- key-value pairs. Any keys mapped to nil will be deleted.
function Iterator.map(fn, ...)
  local f, s, k = unpack(arg)
  local v
  return function ()
    while true do
      k, v = f(s, k)
      if k == nil then
        return nil, nil
      else
        local k2, v2 = fn(k, v)
        if k2 ~= nil then
          return k2, v2
        end
      end
    end
  end, nil, nil
end

-- Return a new iterator with all key-value pairs filtered such that fn(k, v) is
-- true. This iterator will have positive, continguous integers as keys.
function Iterator.ifilter(fn, ...)
  local f, s, k = unpack(arg)
  local v
  local i = 0
  return function ()
    while true do
      k, v = f(s, k)
      if k == nil then
        return nil, nil
      else
        if fn(k, v) then
          i = i + 1
          return i, v
        end
      end
    end
  end, nil, nil
end

-- Combine the provided iterators into a single iterator. The iterators should
-- be supplied as function/invariant/value triplets packed into tables --
-- e.g., {pairs({ ... })} .
function Iterator.concat(...)
  local f = {}
  local s = {}
  local k = {}
  for i, iter in ipairs(arg) do
    f[i] = iter[1]
    s[i] = iter[2]
    k[i] = iter[3]
  end
  local v
  local i = 1
  return function ()
    while f[i] ~= nil do
      k[i], v = f[i](s[i], k[i])
      if k[i] == nil then
        i = i + 1
      else
        return k[i], v
      end
    end
    return nil, nil
  end, nil, nil
end