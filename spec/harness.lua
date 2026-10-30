--- Minimal dependency-free test harness.
local Harness = { passed = 0, failed = 0, failures = {} }

local current = ""

local function show(value)
  if type(value) ~= "table" then return string.format("%q", value) end
  local keys = {}
  for k in pairs(value) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do
    local v = value[k]
    if v == nil then v = value[tonumber(k)] end
    out[#out + 1] = k .. "=" .. show(v)
  end
  return "{" .. table.concat(out, ", ") .. "}"
end

function Harness.describe(name, body)
  local previous = current
  current = previous == "" and name or (previous .. " > " .. name)
  body()
  current = previous
end

function Harness.it(name, body)
  local ok, err = xpcall(body, debug.traceback)
  if ok then
    Harness.passed = Harness.passed + 1
  else
    Harness.failed = Harness.failed + 1
    Harness.failures[#Harness.failures + 1] = current .. " > " .. name .. "\n    " .. tostring(err)
  end
end

function Harness.eq(actual, expected, label)
  if show(actual) ~= show(expected) then
    error((label and (label .. ": ") or "") .. "expected " .. show(expected) .. ", got " .. show(actual), 2)
  end
end

function Harness.truthy(value, label)
  if not value then error((label or "value") .. " should be truthy", 2) end
end

function Harness.finish()
  for _, failure in ipairs(Harness.failures) do print("FAIL " .. failure) end
  print(string.format("%d passed, %d failed", Harness.passed, Harness.failed))
  os.exit(Harness.failed == 0 and 0 or 1)
end

return Harness
