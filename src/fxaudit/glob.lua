--- Manifest glob matching: `*` stays within a directory, `**` crosses directories.
local Glob = {}

local function toPattern(glob)
  local out, i = { "^" }, 1
  while i <= #glob do
    local c = glob:sub(i, i)
    if glob:sub(i, i + 2) == "**/" then
      out[#out + 1] = "\1"
      i = i + 3
    elseif glob:sub(i, i + 1) == "**" then
      out[#out + 1] = "\2"
      i = i + 2
    elseif c == "*" then
      out[#out + 1] = "[^/]*"
      i = i + 1
    elseif c == "?" then
      out[#out + 1] = "[^/]"
      i = i + 1
    elseif c:match("[%^%$%(%)%%%.%[%]%+%-]") then
      out[#out + 1] = "%" .. c
      i = i + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  out[#out + 1] = "$"
  return table.concat(out)
end

function Glob.isGlob(path)
  return path:find("[%*%?]") ~= nil
end

--- Normalizes separators and a leading `./`.
function Glob.normalize(path)
  return (path:gsub("\\", "/"):gsub("^%./", ""))
end

--- Whether `path` matches `glob`. Lua patterns have no alternation, so a `**` is
-- expanded by trying it as nothing and as any directory prefix.
function Glob.matches(glob, path)
  local pattern = toPattern(Glob.normalize(glob))
  local function try(p)
    local a = p:find("\1", 1, true)
    if a then
      return try(p:sub(1, a - 1) .. p:sub(a + 1)) or try(p:sub(1, a - 1) .. ".*/" .. p:sub(a + 1))
    end
    local b = p:find("\2", 1, true)
    if b then return try(p:sub(1, b - 1) .. ".*" .. p:sub(b + 1)) end
    return path:match(p) ~= nil
  end
  return try(pattern)
end

return Glob
