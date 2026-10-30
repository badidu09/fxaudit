--- Answers "does this global exist, and on which side?".
local Globals = require("fxaudit.data.globals")
local rawNatives = require("fxaudit.data.natives")

local Known = {}

local natives

local function loadNatives()
  if natives then return natives end
  natives = { client = {}, server = {}, shared = {} }
  for side, words in pairs(rawNatives) do
    for word in words:gmatch("%S+") do natives[side][word] = true end
  end
  return natives
end

--- Checks whether `name` exists on `side` ("client", "server" or "shared").
-- A shared file runs on both sides, so a name from either side is acceptable there.
function Known.exists(name, side)
  if Globals.lua[name] or Globals.shared[name] then return true end
  if name:match("^N_0x%x+$") then return true end
  local n = loadNatives()
  if n.shared[name] then return true end
  if side == "client" then return Globals.client[name] or n.client[name] or false end
  if side == "server" then return Globals.server[name] or n.server[name] or false end
  return Globals.client[name] or n.client[name] or Globals.server[name] or n.server[name] or false
end

--- Returns the side `name` is restricted to when it only exists on the other one.
function Known.wrongSide(name, side)
  if side ~= "client" and side ~= "server" then return nil end
  if Known.exists(name, side) then return nil end
  local other = side == "client" and "server" or "client"
  if Known.exists(name, other) then return other end
  return nil
end

--- Whether `name` is a builtin that scripts should not overwrite.
function Known.isBuiltin(name)
  return Known.exists(name, "shared") and true or false
end

--- Iterates over all known names, for "did you mean" suggestions.
function Known.forEach(side, fn)
  local n = loadNatives()
  local function each(t) for name in pairs(t) do fn(name) end end
  each(Globals.lua)
  each(Globals.shared)
  each(n.shared)
  if side ~= "server" then each(Globals.client); each(n.client) end
  if side ~= "client" then each(Globals.server); each(n.server) end
end

return Known
