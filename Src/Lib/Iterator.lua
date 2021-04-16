-- Library for manipulating key-value iterators.
local P = {}
Iterator = P

-- Copy the keys and values from the provided iterator into a table.
function P.totable (...)
  local t = {}
  for k, v in unpack(arg) do
    t[k] = v
  end
  return t
end

-- Return a new iterator with the function fn(k, v) -> k2, v2 applied to all
-- key-value pairs. Any keys mapped to nil will be deleted.
function P.map (fn, ...)
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

-- Return a new iterator with the function fn(k, v) -> v2 applied to all
-- key-value pairs. Keys will be renumbered with positive, continguous integers.
-- Any keys mapped to nil will be deleted.
function P.imap (fn, ...)
  local i = 0
  local f, s, k = unpack(arg)
  return function ()
    while true do
      local v
      k, v = f(s, k)
      if k == nil then
        return nil, nil
      else
        local v2 = fn(k, v)
        if v2 ~= nil then
          i = i + 1
          return i, fn(k, v)
        end
      end
    end
  end, nil, nil
end

-- Return a new iterator with all key-value pairs filtered such that fn(k, v) is
-- true.
function P.filter (fn, ...)
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
function P.ifilter (fn, ...)
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

local function empty () return pairs({}) end

-- Combine the provided iterators into a single iterator. The iterators should
-- be supplied as function/invariant/value triplets packed into tables --
-- e.g., {pairs({ ... })} .
function P.concat (...)
  if arg.n < 1 then
    return empty()
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
]]
function P.iconcat (...)
  if arg.n < 1 then
    return empty()
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

--[[
  Combine the iterators yielded by the provided iterator (in the form of
  function/invariant/value triplets packed into tables) into a single iterator.
  Keys will be discarded.
]]
function P.chain (...)
  if arg.n < 1 then
    return empty()
  end
  local f, s, k = unpack(arg)
  local v
  local fi, si, ki = empty()
  return function ()
    while true do
      local vi
      ki, vi = fi(si, ki)
      if ki == nil then
        k, v = f(s, k)
        if k == nil then
          return nil, nil
        else
          fi, si, ki = unpack(v)
        end
      else
        return ki, vi
      end
    end
  end, nil, nil
end

-- Returns true if fn(k, v) is true for one key-value pair in the iterator.
function P.hasone (fn, ...)
  return P.findfirst(fn, unpack(arg)) ~= nil
end

-- Returns the key of the first key-value pair in the iterator such that
-- fn(k, v) is true.
function P.findfirst (fn, ...)
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
function P.min (comp, ...)
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
function P.max (comp, ...)
  local maxk = nil
  local maxv
  for k, v in unpack(arg) do
    if maxk == nil or comp(maxv, v) then
      maxk, maxv = k, v
    end
  end
  return maxk
end

-- A simple a less than b comparer.
function P.ltcomp (a, b) return a < b end

local function getkey (k, _) return k end

-- Iterate through all of the keys in the provided key-value iterator.
function P.keys (...) return P.imap(getkey, unpack(arg)) end

local function getvalue (_, v) return v end

-- Iterate through all of the values in the provided key-value iterator.
function P.values (...) return P.imap(getvalue, unpack(arg)) end

-- Joins the values of the iterator together with the provided separator, like
-- table.concat(t, sep).
function P.join (sep, ...)
  local f, s, v = unpack(arg)
  local k
  k, v = f(s, v)
  if k == nil then
    return ""
  end
  local res = tostring(v)
  for _, v2 in f, s, v do
    res = res .. sep .. tostring(v2)
  end
  return res
end

local function iterrange (s, v)
  if v < s then return v + 1, v + 1
  else return nil, nil end
end

-- Produces a sequence of linear (x, x) pairs, where x ranges from 1 to n
-- inclusive.
function P.range (n)
  return iterrange, n, 0
end

return P