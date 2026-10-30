--- Small deterministic JSON encoder: keys are sorted, so reports diff cleanly.
local Json = {}

local ESCAPES = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encodeString(value)
  return '"' .. value:gsub('[%c"\\]', function(c)
    return ESCAPES[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function encode(value, indent, out)
  local kind = type(value)
  if kind == "string" then
    out[#out + 1] = encodeString(value)
  elseif kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      out[#out + 1] = "null"
    elseif math.type(value) == "float" and value == math.floor(value) then
      out[#out + 1] = string.format("%d", value)
    else
      out[#out + 1] = tostring(value)
    end
  elseif kind == "boolean" then
    out[#out + 1] = tostring(value)
  elseif kind == "nil" then
    out[#out + 1] = "null"
  elseif kind == "table" then
    local inner = indent .. "  "
    if #value > 0 or value.__array then
      if #value == 0 then
        out[#out + 1] = "[]"
        return
      end
      out[#out + 1] = "[\n"
      for i, item in ipairs(value) do
        out[#out + 1] = inner
        encode(item, inner, out)
        out[#out + 1] = i < #value and ",\n" or "\n"
      end
      out[#out + 1] = indent .. "]"
    else
      local keys = {}
      for key in pairs(value) do keys[#keys + 1] = key end
      table.sort(keys)
      if #keys == 0 then
        out[#out + 1] = "{}"
        return
      end
      out[#out + 1] = "{\n"
      for i, key in ipairs(keys) do
        out[#out + 1] = inner .. encodeString(key) .. ": "
        encode(value[key], inner, out)
        out[#out + 1] = i < #keys and ",\n" or "\n"
      end
      out[#out + 1] = indent .. "}"
    end
  else
    error("cannot encode a " .. kind)
  end
end

function Json.encode(value)
  local out = {}
  encode(value, "", out)
  return table.concat(out)
end

--- Marks a possibly empty table as a JSON array.
function Json.array(items)
  items.__array = true
  return items
end

return Json
