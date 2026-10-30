--- Reads fxmanifest.lua statically. The manifest is never executed: scanning a
-- resource you do not trust must not run any of its code.
local Parser = require("fxaudit.parser")

local Manifest = {}

-- Directive name -> canonical list name.
local LIST_DIRECTIVES = {
  client_script = "client_scripts", client_scripts = "client_scripts",
  server_script = "server_scripts", server_scripts = "server_scripts",
  shared_script = "shared_scripts", shared_scripts = "shared_scripts",
  file = "files", files = "files",
  dependency = "dependencies", dependencies = "dependencies",
  export = "exports", exports = "exports",
  server_export = "server_exports", server_exports = "server_exports",
  game = "games", games = "games",
  provide = "provides", provides = "provides",
}

--- Unwinds `a 'x' { y } 'z'` into the name `a` and its ordered argument nodes.
local function unwindCall(node)
  local args = {}
  while node.type == "Call" do
    for i = #node.args, 1, -1 do table.insert(args, 1, node.args[i]) end
    node = node.func
  end
  if node.type == "Name" then return node.name, args end
  return nil
end

--- Extracts the constant strings of a string or list argument, with their positions.
local function stringsOf(arg, out)
  if arg.type == "String" then
    out[#out + 1] = { value = arg.value, line = arg.line, col = arg.col }
    return true
  elseif arg.type == "Table" then
    local allConstant = true
    for _, field in ipairs(arg.fields) do
      if field.kind == "positional" then
        if not stringsOf(field.value, out) then allConstant = false end
      end
    end
    return allConstant
  end
  return false
end

--- Parses manifest text.
-- @return table `{ lists, values, errors, dynamic, chunk }`: `lists` maps canonical names
--   to `{ value, line, col }` entries, `values` keeps the other single-string directives.
function Manifest.parse(source)
  local chunk = Parser.parse(source)
  local manifest = { lists = {}, values = {}, positions = {}, errors = chunk.errors, dynamic = {}, chunk = chunk }

  for _, statement in ipairs(chunk.body) do
    if statement.type == "CallStat" and statement.expr.type == "Call" then
      local name, args = unwindCall(statement.expr)
      local canonical = name and LIST_DIRECTIVES[name]
      if canonical then
        manifest.lists[canonical] = manifest.lists[canonical] or {}
        for _, arg in ipairs(args) do
          if not stringsOf(arg, manifest.lists[canonical]) then
            manifest.dynamic[#manifest.dynamic + 1] = { line = statement.line, col = statement.col, name = name }
          end
        end
      elseif name then
        local first = args[1]
        if first and first.type == "String" then
          manifest.values[name] = first.value
          manifest.positions[name] = { line = first.line, col = first.col }
        end
      end
    elseif statement.type ~= "Local" then
      -- Anything else (loops, conditions) cannot be evaluated without running the file.
      manifest.dynamic[#manifest.dynamic + 1] = { line = statement.line, col = statement.col, name = statement.type }
    end
  end

  return manifest
end

return Manifest
