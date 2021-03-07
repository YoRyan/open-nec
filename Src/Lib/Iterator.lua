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
  return function ()
    while true do
      local v
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

-- Return a new iterator with the function fn(k, v) -> k2, v2 applied to all
-- key-value pairs. Keys will be renumbered with positive, continguous integers.
function Iterator.imap(fn, ...)
  local i = 0
  local f, s, k = unpack(arg)
  return function ()
    local v
    k, v = f(s, k)
    if k == nil then
      return nil, nil
    else
      i = i + 1
      return i, fn(k, v)
    end
  end, nil, nil
end

-- Return a new iterator with all key-value pairs filtered such that fn(k, v) is
-- true.
function Iterator.filter(fn, ...)
  local f, s, k = unpack(arg)
  return function ()
    while true do
      local v
      k, v = f(s, k)
      if k == nil then
        return nil, nil
      else
        if fn(k, v) then
          return k, v
        end
      end
    end
  end, nil, nil
end

-- Return a new iterator with all key-value pairs filtered such that fn(k, v) is
-- true. Keys will be renumbered with positive, continguous integers.
function Iterator.ifilter(fn, ...)
  local i = 0
  local f, s, k = unpack(arg)
  return function ()
    while true do
      local v
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
  if arg.n < 1 then
    return pairs({})
  end
  local i = 1
  local f, s, k = unpack(arg[i])
  return function ()
    while true do
      local v
      k, v = f(s, k)
      if k == nil then
        i = i + 1
        if arg[i] == nil then
          return nil, nil
        else
          f, s, k = unpack(arg[i])
        end
      else
        return k, v
      end
    end
  end, nil, nil
end

--[[
  Combine the provided iterators into a single iterator. Keys will be
  renumbered with positive, continguous integers. The iterators should
  be supplied as function/invariant/value triplets packed into tables --
  e.g., {pairs({ ... })} .
]]--
function Iterator.iconcat(...)
  if arg.n < 1 then
    return pairs({})
  end
  local i = 1
  local j = 0
  local f, s, k = unpack(arg[i])
  return function ()
    while true do
      local v
      k, v = f(s, k)
      if k == nil then
        i = i + 1
        if arg[i] == nil then
          return nil, nil
        else
          f, s, k = unpack(arg[i])
        end
      else
        j = j + 1
        return j, v
      end
    end
  end, nil, nil
end

-- Returns true if fn(k, v) is true for one key-value pair in the iterator.
function Iterator.hasone(fn, ...)
  return Iterator.findfirst(fn, unpack(arg)) ~= nil
end

-- Returns the key of the first key-value pair in the iterator such that
-- fn(k, v) is true.
function Iterator.findfirst(fn, ...)
  for k, v in unpack(arg) do
    if fn(k, v) then
      return k
    end
  end
  return nil
end

-- Returns the key of the minimum key-value pair in the iterator given comp,
-- a comparison function that returns true if the first argument is less than
-- the second.
function Iterator.min(comp, ...)
  local mink = nil
  local minv
  for k, v in unpack(arg) do
    if mink == nil or comp(v, minv) then
      mink, minv = k, v
    end
  end
  return mink
end

-- Returns the key of the maximum key-value pair in the iterator given comp,
-- a comparison function that returns true if the first argument is less than
-- the second.
function Iterator.max(comp, ...)
  local maxk = nil
  local maxv
  for k, v in unpack(arg) do
    if maxk == nil or comp(maxv, v) then
      maxk, maxv = k, v
    end
  end
  return maxk
end