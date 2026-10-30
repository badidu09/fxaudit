--- Turns paths on disk into analyzed resources.
local Analyzer = require("fxaudit.analyzer")
local Manifest = require("fxaudit.manifest")
local Glob = require("fxaudit.glob")
local Fs = require("fxaudit.fs")
local Parser = require("fxaudit.parser")
local Scope = require("fxaudit.scope")
local Globals = require("fxaudit.data.globals")
local Registry = require("fxaudit.rules.registry")
local EventRules = require("fxaudit.rules.events")
local Variables = require("fxaudit.rules.variables")

local Project = {}

local SKIPPED_DIRECTORIES = { ".git", "node_modules", ".fxap", ".github", ".vscode" }

local VALID_FX_VERSIONS = { cerulean = true, bodacious = true, adamant = true }
local VALID_GAMES = { gta5 = true, rdr3 = true, common = true }

local function isSkipped(relative)
  for _, name in ipairs(SKIPPED_DIRECTORIES) do
    if relative:find("^" .. name:gsub("%p", "%%%0") .. "/") or relative:find("/" .. name:gsub("%p", "%%%0") .. "/") then
      return true
    end
  end
  return false
end

--- Groups scanned files by the resource folder containing them.
local function discover(root, listed)
  local roots = {}
  for _, path in ipairs(listed) do
    local dir, base = path:match("^(.*)/([^/]+)$")
    if dir and (base == "fxmanifest.lua" or base == "__resource.lua") then
      roots[#roots + 1] = { dir = dir, manifestPath = path, legacy = base == "__resource.lua" }
    end
  end
  -- Deepest first, so that a file belongs to its nearest manifest. Both manifest
  -- kinds in a single folder resolve to fxmanifest.lua, which takes precedence.
  table.sort(roots, function(a, b)
    if #a.dir ~= #b.dir then return #a.dir > #b.dir end
    if a.dir ~= b.dir then return a.dir < b.dir end
    return a.legacy == false and b.legacy == true
  end)
  local unique, seen = {}, {}
  for _, entry in ipairs(roots) do
    if not seen[entry.dir] then
      seen[entry.dir] = true
      entry.files = {}
      unique[#unique + 1] = entry
    end
  end

  local loose = {}
  for _, path in ipairs(listed) do
    local owner
    for _, entry in ipairs(unique) do
      if path:sub(1, #entry.dir + 1) == entry.dir .. "/" then
        owner = entry
        break
      end
    end
    if owner then
      local relative = path:sub(#owner.dir + 2)
      if not isSkipped(relative) then owner.files[#owner.files + 1] = relative end
    elseif not isSkipped(path:sub(#root + 2)) then
      loose[#loose + 1] = path
    end
  end
  return unique, loose
end

local function isProtected(source)
  -- Escrowed files start with FXAP, compiled chunks with the Lua signature.
  return source:sub(1, 4) == "FXAP" or source:sub(1, 4) == "\27Lua"
end

--- Expands a manifest entry against the resource's files.
local function expand(entry, files)
  local path = Glob.normalize(entry.value)
  local matches = {}
  if Glob.isGlob(path) then
    for _, file in ipairs(files) do
      if Glob.matches(path, file) then matches[#matches + 1] = file end
    end
  else
    for _, file in ipairs(files) do
      if file == path then matches[1] = file; break end
    end
  end
  return matches
end

--- Explains a missing web file: source checkouts often do not contain the built UI.
local function buildHint(path)
  if path:find("build/", 1, true) or path:find("dist/", 1, true) then
    return "this looks like compiled UI output: build it, or download a release of this resource"
  end
  return nil
end

--- Reads the manifest and assigns a side to each script.
local function loadResource(entry, context)
  local name = entry.dir:match("([^/]+)$") or entry.dir
  local manifestSource = Fs.read(entry.manifestPath) or ""
  local manifest = Manifest.parse(manifestSource)
  local manifestName = entry.manifestPath:match("([^/]+)$")

  local input = {
    name = name, dir = entry.dir, manifest = manifest, files = {}, findings = {},
    importedGlobals = {}, unresolvedImports = {},
    customGlobals = context.customGlobals, project = context.project,
  }

  local function finding(id, at, message, options)
    options = options or {}
    local rule = Registry.get(id)
    input.findings[#input.findings + 1] = {
      rule = id, name = rule.name, category = rule.category,
      severity = options.severity or rule.severity, confidence = options.confidence or "high",
      file = entry.dir .. "/" .. (options.file or manifestName), line = at and at.line or 1, col = at and at.col or 1,
      message = message, hint = options.hint, resource = name,
    }
  end

  for _, e in ipairs(manifest.errors) do
    finding("FX711", e, "manifest syntax error: " .. e.message)
  end
  for _, d in ipairs(manifest.dynamic) do
    finding("FX711", d, "this manifest statement cannot be read without running it, so its files may be missing from this analysis", {
      severity = "low", confidence = "medium",
    })
  end

  if entry.legacy then
    finding("FX700", nil, "__resource.lua is abandoned", { hint = "rename it fxmanifest.lua and declare fx_version and game" })
  else
    local fxVersion = manifest.values.fx_version
    if not fxVersion then
      finding("FX701", nil, "fx_version is missing", { hint = "add: fx_version 'cerulean'" })
    elseif not VALID_FX_VERSIONS[fxVersion] then
      finding("FX701", manifest.positions.fx_version, "unknown fx_version '" .. fxVersion .. "'", { hint = "use 'cerulean'" })
    end
    local games = manifest.lists.games
    if not games or #games == 0 then
      finding("FX702", nil, "game is missing", { hint = "add: game 'gta5'" })
    else
      for _, game in ipairs(games) do
        if not VALID_GAMES[game.value] then
          finding("FX702", game, "unknown game '" .. game.value .. "'", { hint = "use 'gta5', 'rdr3' or 'common'" })
        end
      end
    end
  end

  if manifest.values.lua54 then
    finding("FX708", manifest.positions.lua54, "lua54 is no longer needed: all Lua scripts run on 5.4")
  end
  if manifest.values.resource_manifest_version then
    finding("FX708", manifest.positions.resource_manifest_version, "resource_manifest_version is deprecated", { hint = "use fx_version" })
  end

  local assigned = {}
  local sides = { client_scripts = "client", server_scripts = "server", shared_scripts = "shared" }

  local function addScript(relative, side)
    local existing = assigned[relative]
    if existing then
      -- The same file on both sides behaves as a shared script.
      if existing.side ~= side then existing.side = "shared" end
      return
    end
    local full = entry.dir .. "/" .. relative
    local source = Fs.read(full)
    if source then
      if isProtected(source) then
        finding("FX710", nil, "this file is escrow-protected or precompiled: it was NOT analyzed", { file = relative })
        assigned[relative] = { side = side, protected = true }
      else
        local file = { path = full, source = source, side = side }
        input.files[#input.files + 1] = file
        assigned[relative] = file
      end
    end
  end

  for listName, side in pairs(sides) do
    for _, script in ipairs(manifest.lists[listName] or {}) do
      local value = script.value
      local importedResource, importedFile = value:match("^@([^/]+)/(.+)$")
      if importedResource then
        context.resolveImport(input, importedResource, importedFile, script, finding)
      elseif value:match("^https?://") then
        finding("FX703", script, "scripts cannot be loaded from a URL", { severity = "medium" })
      elseif value:lower():match("%.lua$") or Glob.isGlob(value) then
        local matches = expand(script, entry.files)
        if #matches == 0 then
          if Glob.isGlob(value) then
            finding("FX704", script, "'" .. value .. "' matches no file")
          else
            finding("FX703", script, "'" .. value .. "' does not exist in this resource")
          end
        end
        for _, relative in ipairs(matches) do
          if relative:lower():match("%.lua$") then addScript(relative, side) end
        end
      elseif #expand(script, entry.files) == 0 then
        finding("FX703", script, "'" .. value .. "' does not exist in this resource")
      end
    end
  end

  -- Files, UI pages and loading screens.
  local declared = manifest.lists.files or {}
  for _, entryFile in ipairs(declared) do
    if #expand(entryFile, entry.files) == 0 then
      if Glob.isGlob(entryFile.value) then
        finding("FX704", entryFile, "'" .. entryFile.value .. "' matches no file", { hint = buildHint(entryFile.value) })
      else
        finding("FX703", entryFile, "'" .. entryFile.value .. "' does not exist in this resource", { hint = buildHint(entryFile.value) })
      end
    end
  end

  for _, directive in ipairs({ "ui_page", "loadscreen" }) do
    local page = manifest.values[directive]
    if page and not page:match("^https?://") then
      local position = manifest.positions[directive]
      local normalized = Glob.normalize(page)
      local exists = false
      for _, file in ipairs(entry.files) do
        if file == normalized then exists = true; break end
      end
      if not exists then
        finding("FX703", position, directive .. " '" .. page .. "' does not exist in this resource", { hint = buildHint(page) })
      end
      local listed = false
      for _, entryFile in ipairs(declared) do
        if Glob.normalize(entryFile.value) == normalized or Glob.matches(entryFile.value, normalized) then
          listed = true
          break
        end
      end
      if not listed then
        finding("FX705", position, directive .. " '" .. page .. "' is not listed in files: clients will not receive it", {
          hint = "add it to files { ... }",
        })
      end
    end
  end

  -- Lua files the manifest never loads. Those declared in `files` are client data
  -- (often `require`d through a helper), and config-like folders are loaded at runtime.
  for _, relative in ipairs(entry.files) do
    if relative:lower():match("%.lua$") and not assigned[relative]
      and relative ~= "fxmanifest.lua" and relative ~= "__resource.lua" then
      local inFiles = false
      for _, entryFile in ipairs(declared) do
        if Glob.matches(entryFile.value, relative) then inFiles = true; break end
      end
      local source = Fs.read(entry.dir .. "/" .. relative)
      if source and not isProtected(source) then
        local side = relative:lower():find("client") and "client"
          or relative:lower():find("server") and "server" or "unknown"
        input.files[#input.files + 1] = {
          path = entry.dir .. "/" .. relative, source = source, side = side, isOrphan = true,
        }
        if not inFiles then
          finding("FX707", nil, "'" .. relative .. "' is not referenced by the manifest: it is never loaded directly", {
            file = relative, confidence = "medium",
          })
        end
      elseif source then
        finding("FX710", nil, "this file is escrow-protected or precompiled: it was NOT analyzed", { file = relative })
      end
    end
  end

  -- Dependencies, ignoring the /server:, /onesync and similar constraints.
  for _, dep in ipairs(manifest.lists.dependencies or {}) do
    if dep.value:sub(1, 1) ~= "/" and context.knowsResource and not context.knowsResource(dep.value) then
      finding("FX706", dep, "dependency '" .. dep.value .. "' was not found in the scanned folders", {
        hint = "it must start before this resource, or this resource will refuse to start",
        confidence = "low",
      })
    end
  end

  return input
end

--- Scans paths and returns the analyzed resources.
-- @param paths list of files or directories
-- @param options `{ globals = { name = true } }`
function Project.scan(paths, options)
  options = options or {}
  local entries, looseFiles = {}, {}

  for _, raw in ipairs(paths) do
    local path = Fs.normalize(raw)
    if Fs.isDirectory(path) then
      local found, loose = discover(path, Fs.listFiles(path))
      for _, entry in ipairs(found) do entries[#entries + 1] = entry end
      for _, file in ipairs(loose) do
        if file:lower():match("%.lua$") then looseFiles[#looseFiles + 1] = file end
      end
    elseif Fs.exists(path) then
      looseFiles[#looseFiles + 1] = path
    else
      error("path not found: " .. raw, 0)
    end
  end

  local byName, byFolder = {}, {}
  for _, entry in ipairs(entries) do
    local name = entry.dir:match("([^/]+)$") or entry.dir
    byName[name] = entry
    byFolder[name] = entry
    -- A resource can stand in for another with `provide`.
    local source = Fs.read(entry.manifestPath) or ""
    entry.parsedManifest = Manifest.parse(source)
    for _, provided in ipairs(entry.parsedManifest.lists.provides or {}) do
      byName[provided.value] = byName[provided.value] or entry
    end
  end

  local exportsCache = {}
  local project = {}
  --- Returns the exports of a scanned resource, or nil if it is not fully known.
  -- A resource standing in through `provide` may expose them through a bridge: unknown.
  function project.exportsOf(name)
    local entry = byFolder[name]
    if not entry then return nil end
    if exportsCache[entry] ~= nil then return exportsCache[entry] or nil end
    local exported = {}
    for _, list in ipairs({ "exports", "server_exports" }) do
      for _, item in ipairs(entry.parsedManifest.lists[list] or {}) do exported[item.value] = true end
    end
    for _, relative in ipairs(entry.files) do
      if relative:lower():match("%.lua$") then
        local source = Fs.read(entry.dir .. "/" .. relative)
        if source then
          if isProtected(source) then
            -- Exports hidden in a protected file cannot be listed: stay silent.
            exportsCache[entry] = false
            return nil
          end
          local chunk = Parser.parse(source)
          Scope.analyze(chunk)
          EventRules.collectExports(chunk, exported)
          -- Dynamic names such as exports(name, fn) make the list incomplete.
          if source:find("exports%(%s*[%a_]") then
            exportsCache[entry] = false
            return nil
          end
        end
      end
    end
    exportsCache[entry] = exported
    return exported
  end

  local context = {
    project = project, customGlobals = options.globals or {},
    knowsResource = #entries > 1 and function(name) return byName[name] ~= nil end or nil,
  }

  --- Handles `@resource/file.lua`: reads the real file when scanned, else uses known names.
  function context.resolveImport(input, resourceName, file, script, finding)
    local target = byName[resourceName]
    local known = Globals.imports[resourceName .. "/" .. file]
    if known then
      for _, name in ipairs(known) do input.importedGlobals[name] = true end
    end
    if target then
      local source = Fs.read(target.dir .. "/" .. file)
      if not source then
        finding("FX709", script, "'" .. script.value .. "' does not exist in resource '" .. resourceName .. "'")
        return
      end
      if isProtected(source) then return end
      local chunk = Parser.parse(source)
      local info = Scope.analyze(chunk)
      for _, ref in ipairs(info.globals) do
        if ref.write then input.importedGlobals[ref.name] = true end
      end
      Variables.explicitGlobals(chunk, function(name) input.importedGlobals[name] = true end)
    elseif not known then
      input.unresolvedImports[#input.unresolvedImports + 1] = script.value
    end
  end

  local results = {}
  for _, entry in ipairs(entries) do
    results[#results + 1] = Analyzer.analyzeResource(loadResource(entry, context))
  end

  if #looseFiles > 0 then
    local files = {}
    for _, path in ipairs(looseFiles) do
      local source = Fs.read(path)
      if source and not isProtected(source) then
        local lowered = path:lower()
        local side = lowered:find("client") and "client" or lowered:find("server") and "server" or "unknown"
        files[#files + 1] = { path = path, source = source, side = side, isOrphan = true }
      end
    end
    if #files > 0 then
      results[#results + 1] = Analyzer.analyzeResource({
        name = "(no manifest)", files = files, customGlobals = options.globals, project = project,
      })
    end
  end

  return results
end

return Project
