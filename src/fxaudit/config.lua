--- Reads .fxaudit.lua. Like the manifest, it is never executed: it must be a plain
-- `return { ... }` of constants, so scanning an untrusted repository stays safe.
local Parser = require("fxaudit.parser")
local Fs = require("fxaudit.fs")

local Config = {}

local function constant(node)
  local kind = node.type
  if kind == "String" or kind == "Number" then return node.value end
  if kind == "True" then return true end
  if kind == "False" then return false end
  if kind == "Paren" then return constant(node.expr) end
  if kind == "Table" then
    local out, index = {}, 0
    for _, field in ipairs(node.fields) do
      local value = constant(field.value)
      if field.kind == "positional" then
        index = index + 1
        out[index] = value
      elseif field.kind == "named" then
        out[field.name] = value
      else
        out[constant(field.key)] = value
      end
    end
    return out
  end
  error("only constants are allowed in the config (line " .. tostring(node.line) .. ")", 0)
end

--- Turns a list of strings into a set.
local function toSet(list)
  local out = {}
  for _, value in ipairs(list or {}) do out[value] = true end
  return out
end

--- Parses config text into `{ globals, disable, severity, exclude, minSeverity, failOn }`.
function Config.parse(source)
  local chunk = Parser.parse(source)
  if #chunk.errors > 0 then
    error("line " .. chunk.errors[1].line .. ": " .. chunk.errors[1].message, 0)
  end
  local last = chunk.body[#chunk.body]
  if #chunk.body ~= 1 or last.type ~= "Return" or not last.values[1] then
    error("expected a single 'return { ... }'", 0)
  end
  local raw = constant(last.values[1])
  return {
    globals = toSet(raw.globals),
    disable = toSet(raw.disable),
    severity = raw.severity or {},
    exclude = raw.exclude or {},
    minSeverity = raw.min_severity,
    failOn = raw.fail_on,
  }
end

--- Loads a config file; a missing default file simply gives an empty config.
function Config.load(path, required)
  local source = Fs.read(path)
  if not source then
    if required then error("config file not found: " .. path, 0) end
    return { globals = {}, disable = {}, severity = {}, exclude = {} }
  end
  local ok, result = pcall(Config.parse, source)
  if not ok then error(path .. ": " .. tostring(result), 0) end
  return result
end

return Config
