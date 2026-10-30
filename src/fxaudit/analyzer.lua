--- Runs the rules over a resource made of already-loaded sources.
local Parser = require("fxaudit.parser")
local Scope = require("fxaudit.scope")
local Registry = require("fxaudit.rules.registry")
local Suppress = require("fxaudit.suppress")

local Analyzer = {}

local RULE_MODULES = {
  "fxaudit.rules.variables",
}

local SYNTAX_KINDS = { syntax = "FX100", ["break"] = "FX101", vararg = "FX102", hint = "FX105" }
local SCOPE_KINDS = { label = "FX103", ["goto"] = "FX103", const = "FX104" }

--- Parses one file and prepares its context.
-- @param resource the resource accumulating findings
-- @param file `{ path, source, side, isOrphan }`
local function newContext(resource, file)
  local chunk = Parser.parse(file.source)
  local info = Scope.analyze(chunk)
  local suppressions = Suppress.parse(chunk.comments)

  local ctx = {
    path = file.path, source = file.source, side = file.side or "unknown",
    isOrphan = file.isOrphan, chunk = chunk, info = info, resource = resource,
  }

  --- Records a finding. `at` is any table with line and col.
  function ctx.report(id, at, message, options)
    options = options or {}
    local rule = Registry.get(id)
    if not rule then error("unknown rule " .. id) end
    if Suppress.isSuppressed(suppressions, id, at.line) then
      resource.suppressedCount = resource.suppressedCount + 1
      return
    end
    resource.findings[#resource.findings + 1] = {
      rule = id, name = rule.name, category = rule.category,
      severity = options.severity or rule.severity,
      confidence = options.confidence or "high",
      file = file.path, line = at.line, col = at.col,
      message = message, hint = options.hint, resource = resource.name,
    }
  end

  for _, e in ipairs(chunk.errors) do
    ctx.report(SYNTAX_KINDS[e.kind] or "FX100", e, e.message)
  end
  for _, problem in ipairs(info.problems) do
    ctx.report(SCOPE_KINDS[problem.kind], problem.node, problem.message)
  end

  return ctx
end

--- Analyzes one resource.
-- @param input `{ name, files, importedGlobals, unresolvedImports, customGlobals, isLibrary, manifest, project }`
-- @return table resource result with `findings`, sorted by file then position
function Analyzer.analyzeResource(input)
  local resource = {
    name = input.name or "?", findings = input.findings or {}, files = {}, suppressedCount = 0,
    importedGlobals = input.importedGlobals, unresolvedImports = input.unresolvedImports,
    customGlobals = input.customGlobals, isLibrary = input.isLibrary,
    manifest = input.manifest, project = input.project,
  }

  for _, file in ipairs(input.files) do
    resource.files[#resource.files + 1] = newContext(resource, file)
  end

  for _, moduleName in ipairs(RULE_MODULES) do
    local module = require(moduleName)
    if module.checkFile then
      for _, ctx in ipairs(resource.files) do module.checkFile(ctx) end
    end
    if module.checkResource then module.checkResource(resource) end
  end

  table.sort(resource.findings, function(a, b)
    if a.file ~= b.file then return a.file < b.file end
    if a.line ~= b.line then return (a.line or 0) < (b.line or 0) end
    if (a.col or 0) ~= (b.col or 0) then return (a.col or 0) < (b.col or 0) end
    return a.rule < b.rule
  end)

  return resource
end

return Analyzer
