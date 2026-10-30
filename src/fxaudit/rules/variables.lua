--- FX2xx: undefined names, global leaks, unused variables.
local Ast = require("fxaudit.ast")
local Known = require("fxaudit.data.known")
local Globals = require("fxaudit.data.globals")
local Text = require("fxaudit.text")

local Variables = {}

local function ignoredName(name)
  return name == "_" or name:sub(1, 1) == "_"
end

local function checkLocals(ctx)
  for _, var in ipairs(ctx.info.vars) do
    local position = { line = var.line, col = var.col }
    local unused = var.reads == 0 and var.attrib ~= "close"

    if unused and not ignoredName(var.name) then
      if var.kind == "loop" then
        ctx.report("FX214", position, "loop variable '" .. var.name .. "' is never used", {
          hint = "rename it '_' to show this is intentional",
        })
      elseif var.kind == "function" then
        ctx.report("FX205", position, "local function '" .. var.name .. "' is never called")
      elseif var.kind == "local" and var.writes > 0 then
        ctx.report("FX206", position, "local '" .. var.name .. "' is assigned but its value is never read")
      elseif var.kind == "local" then
        ctx.report("FX203", position, "local '" .. var.name .. "' is never used")
      end
    end

    if var.kind == "local" and not var.hasInit and var.reads > 0 then
      if var.writes == 0 then
        ctx.report("FX209", var.readNodes[1].node, "'" .. var.name .. "' is read but never assigned: it is always nil", {
          hint = "declared without a value at line " .. var.line,
        })
      else
        local read, write = var.readNodes[1], var.writeNodes[1]
        if read.func == var.func and write.func == var.func and read.loopDepth == 0
          and read.node.pos < write.node.pos then
          ctx.report("FX210", read.node, "'" .. var.name .. "' is read before its first assignment at line " .. write.node.line)
        end
      end
    end

    if var.kind == "loop" and var.writes > 0 then
      ctx.report("FX212", var.writeNodes[1].node, "loop variable '" .. var.name .. "' is assigned inside the loop")
    end

    if var.shadows and not ignoredName(var.name) and var.name ~= "self" then
      ctx.report("FX207", position, "'" .. var.name .. "' hides the variable declared at line " .. var.shadows.line)
    end

    if var.redefines and not ignoredName(var.name) then
      ctx.report("FX208", position, "'" .. var.name .. "' is already declared at line " .. var.redefines.line .. " in this scope")
    end
  end

  -- Only parameters after the last used one are removable from the signature.
  for _, func in ipairs(ctx.info.functions) do
    local params = func.node.paramVars
    if params then
      for i = #params, 1, -1 do
        local param = params[i]
        if param.reads > 0 or param.selfReads > 0 then break end
        if not ignoredName(param.name) then
          ctx.report("FX204", { line = param.line, col = param.col }, "parameter '" .. param.name .. "' is never used")
        end
      end
    end
  end
end

--- Returns the set of reads guarded by a presence test, like `if Foo then` or `type(Foo)`.
local function collectGuarded(chunk)
  local guarded = {}
  local function markTruthy(expr)
    expr = Ast.unparen(expr)
    if expr.type == "Name" then
      guarded[expr] = true
    elseif expr.type == "Binop" and (expr.op == "and" or expr.op == "or") then
      markTruthy(expr.left)
      if expr.op == "and" then markTruthy(expr.right) end
    elseif expr.type == "Unop" and expr.op == "not" then
      markTruthy(expr.operand)
    end
  end
  Ast.walk(chunk, function(node)
    if node.type == "If" then
      for _, clause in ipairs(node.clauses) do markTruthy(clause.cond) end
    elseif node.type == "Binop" and (node.op == "and" or node.op == "or") then
      markTruthy(node.left)
    elseif node.type == "Call" and node.func.type == "Name" and node.func.name == "type" and node.args[1] then
      markTruthy(node.args[1])
    end
  end)
  return guarded
end

--- Collects the names `_G.x = ...` and `rawset(_G, "x", ...)` define.
local function explicitGlobals(ctx, add)
  Ast.walk(ctx.chunk, function(node)
    if node.type == "Assign" then
      for _, target in ipairs(node.targets) do
        if target.type == "Index" and target.object.type == "Name"
          and (target.object.name == "_G" or target.object.name == "_ENV")
          and target.key.type == "String" then
          add(target.key.value)
        end
      end
    elseif node.type == "FunctionStat" and node.target.type == "Index"
      and node.target.object.type == "Name" and node.target.object.name == "_G" then
      add(node.target.name)
    elseif node.type == "Call" and node.func.type == "Name" and node.func.name == "rawset"
      and node.args[1] and node.args[1].type == "Name" and node.args[1].name == "_G"
      and node.args[2] and node.args[2].type == "String" then
      add(node.args[2].value)
    end
  end)
end

--- Builds a name lookup per side from the resource's own definitions.
local function buildDefinitions(resource)
  local defined = { client = {}, server = {}, shared = {}, unknown = {} }
  for _, ctx in ipairs(resource.files) do
    local function add(name)
      local entry = defined[ctx.side]
      entry[name] = entry[name] or { files = {} }
      entry[name].files[ctx.path] = true
    end
    for _, ref in ipairs(ctx.info.globals) do
      if ref.write then add(ref.name) end
    end
    explicitGlobals(ctx, add)
  end
  return defined
end

local function visibleSides(side)
  if side == "client" then return { "client", "shared" } end
  if side == "server" then return { "server", "shared" } end
  if side == "shared" then return { "shared", "client", "server" } end
  return { "unknown", "shared", "client", "server" }
end

local function isDefined(defined, side, name)
  for _, s in ipairs(visibleSides(side)) do
    if defined[s][name] then return true end
  end
  return false
end

local function suggest(name, ctx, defined)
  local finder = Text.suggester(name)
  Known.forEach(ctx.side, finder.offer)
  for _, s in ipairs(visibleSides(ctx.side)) do
    for candidate in pairs(defined[s]) do finder.offer(candidate) end
  end
  return finder.best
end

local function checkGlobals(resource, ctx, defined)
  local guarded = collectGuarded(ctx.chunk)
  local imported = resource.importedGlobals or {}
  local custom = resource.customGlobals or {}
  local suggestions = {}
  local fileUsesEnv = false
  for _, ref in ipairs(ctx.info.globals) do
    if ref.name == "_ENV" then fileUsesEnv = true end
  end

  for _, ref in ipairs(ctx.info.globals) do
    local name = ref.name
    if fileUsesEnv then
      -- A rebound _ENV makes global resolution undecidable here.
    elseif not ref.write then
      local exists = Known.exists(name, ctx.side) or isDefined(defined, ctx.side, name)
        or imported[name] or custom[name]
      if not exists then
        local other = Known.wrongSide(name, ctx.side)
        if other then
          ctx.report("FX215", ref.node, "'" .. name .. "' only exists on the " .. other .. " side, and this file runs on the " .. ctx.side, {
            hint = other == "server" and "ask the server through an event or callback" or "ask the client through an event or callback",
          })
        elseif not guarded[ref.node] then
          local laterLocal
          for _, var in ipairs(ctx.info.vars) do
            if var.name == name and (var.line > ref.node.line
              or (var.line == ref.node.line and var.col > ref.node.col)) then
              laterLocal = var
              break
            end
          end
          if laterLocal then
            ctx.report("FX211", ref.node, "'" .. name .. "' is used before its 'local' declaration at line " .. laterLocal.line, {
              hint = "move the declaration above this line",
            })
          else
            if suggestions[name] == nil then suggestions[name] = suggest(name, ctx, defined) or false end
            local best = suggestions[name]
            local uncertain = resource.unresolvedImports and #resource.unresolvedImports > 0
            ctx.report("FX200", ref.node, "'" .. name .. "' is not defined anywhere", {
              hint = best and ("did you mean '" .. best .. "'?")
                or (uncertain and ("it may come from " .. resource.unresolvedImports[1]) or "declare it, or add it to 'globals' in .fxaudit.lua if it comes from another resource"),
              confidence = (not best and uncertain) and "low" or nil,
            })
          end
        end
      end
    end
  end

  -- Writes: only the first write of each name, to avoid repeating a single problem.
  local seenWrite = {}
  local readsPerName, writesPerName, topLevelWrite = {}, {}, {}
  for _, ref in ipairs(ctx.info.globals) do
    if ref.write then
      writesPerName[ref.name] = (writesPerName[ref.name] or 0) + 1
      if not ref.inFunction then topLevelWrite[ref.name] = true end
    else
      readsPerName[ref.name] = (readsPerName[ref.name] or 0) + 1
    end
  end

  for _, ref in ipairs(ctx.info.globals) do
    local name = ref.name
    if ref.write and not seenWrite[name] and not fileUsesEnv then
      seenWrite[name] = true
      if Known.exists(name, ctx.side) or Known.exists(name, "any") then
        if name ~= "_" then
          ctx.report("FX213", ref.node, "assigning '" .. name .. "' replaces a builtin for the whole resource", {
            hint = "use a local with another name, unless replacing it is intentional",
          })
        end
      elseif ref.inFunction and not ref.isDefinition then
        local usedElsewhere = false
        for _, other in ipairs(resource.files) do
          if other ~= ctx then
            for _, otherRef in ipairs(other.info.globals) do
              if otherRef.name == name then usedElsewhere = true; break end
            end
          end
          if usedElsewhere then break end
        end
        if not topLevelWrite[name] and not usedElsewhere then
          ctx.report("FX201", ref.node, "'" .. name .. "' leaks: it is assigned in a function without 'local' and becomes a global", {
            hint = "write 'local " .. name .. "' here, or declare it at the top of the file if it must be shared between functions",
          })
        elseif not topLevelWrite[name] and usedElsewhere then
          ctx.report("FX201", ref.node, "'" .. name .. "' is created from inside a function and shared with other files; it is nil until this function has run", {
            hint = "declare it at the top of a shared file",
            confidence = "low",
            severity = "low",
          })
        end
      elseif not ref.inFunction and not ref.isDefinition then
        local usedElsewhere = false
        for _, other in ipairs(resource.files) do
          if other ~= ctx then
            for _, otherRef in ipairs(other.info.globals) do
              if otherRef.name == name then usedElsewhere = true; break end
            end
          end
          if usedElsewhere then break end
        end
        if not usedElsewhere and not resource.isLibrary then
          ctx.report("FX202", ref.node, "global '" .. name .. "' is only used in this file: make it local")
        end
      end
    end
  end
end

local function checkLibraryFields(ctx)
  local extended = {}
  Ast.walk(ctx.chunk, function(node)
    if node.type == "FunctionStat" then
      local path = Ast.path(node.target)
      if path then extended[path] = true end
    elseif node.type == "Assign" then
      for _, target in ipairs(node.targets) do
        local path = Ast.path(target)
        if path then extended[path] = true end
      end
    end
  end)
  Ast.walk(ctx.chunk, function(node)
    if node.type == "Index" and node.dotted and node.object.type == "Name" and not node.object.var then
      local library = Globals.libraries[node.object.name]
      if library and not library[node.name] and not extended[node.object.name .. "." .. node.name] then
        local finder = Text.suggester(node.name)
        for field in pairs(library) do finder.offer(field) end
        if finder.best then
          ctx.report("FX216", node, "'" .. node.object.name .. "." .. node.name .. "' does not exist", {
            hint = "did you mean '" .. node.object.name .. "." .. finder.best .. "'?",
          })
        end
      end
    end
  end)
end

function Variables.checkFile(ctx)
  checkLocals(ctx)
  checkLibraryFields(ctx)
end

function Variables.checkResource(resource)
  local defined = buildDefinitions(resource)
  for _, ctx in ipairs(resource.files) do
    if not ctx.isOrphan then checkGlobals(resource, ctx, defined) end
  end
end

return Variables
