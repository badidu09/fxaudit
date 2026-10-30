--- Command-line interface. `Cli.run` returns an exit code instead of exiting,
-- which keeps it testable:
--   0 nothing at or above the failure threshold, 1 findings at or above it, 2 usage error.
local Project = require("fxaudit.project")
local Config = require("fxaudit.config")
local Registry = require("fxaudit.rules.registry")
local Pretty = require("fxaudit.report.pretty")
local Machine = require("fxaudit.report.machine")
local Fs = require("fxaudit.fs")

local Cli = { VERSION = "0.1.0" }

local USAGE = [[
fxaudit ]] .. Cli.VERSION .. [[ - static analyzer for FiveM resources

Usage:
  fxaudit scan [paths...] [options]    Analyze resources (default path: current folder)
  fxaudit rules                        List every rule
  fxaudit explain <FXnnn>              Explain a rule
  fxaudit --version

Options:
  -f, --format <pretty|json|sarif>     Report format (default: pretty)
  -o, --output <file>                  Write the report to a file
  -s, --min-severity <level>           Hide findings below this level (default: low)
      --fail-on <level|never>          Exit with code 1 from this level (default: high)
      --only <FXnnn,...>               Only report these rules
      --disable <FXnnn,...>            Do not report these rules
      --all                            Also show info-level findings
  -c, --config <file>                  Config file (default: .fxaudit.lua)
  -q, --quiet                          Print the summary only
      --no-color                       Disable colors
  -h, --help                           Show this help

Levels: critical, high, medium, low, info
Nothing is executed: fxaudit only reads your files.
]]

local function splitList(text)
  local out = {}
  for item in text:gmatch("[^,%s]+") do out[item:upper()] = true end
  return out
end

local function parseArguments(args)
  local options = { paths = {} }
  local i = 1

  local function value(flag)
    i = i + 1
    if args[i] == nil then error("missing value for " .. flag, 0) end
    return args[i]
  end

  while i <= #args do
    local a = args[i]
    if a == "-f" or a == "--format" then options.format = value(a)
    elseif a == "-o" or a == "--output" then options.output = value(a)
    elseif a == "-s" or a == "--min-severity" then options.minSeverity = value(a)
    elseif a == "--fail-on" then options.failOn = value(a)
    elseif a == "--only" then options.only = splitList(value(a))
    elseif a == "--disable" then options.disable = splitList(value(a))
    elseif a == "--all" then options.minSeverity = "info"
    elseif a == "-c" or a == "--config" then options.config = value(a)
    elseif a == "-q" or a == "--quiet" then options.quiet = true
    elseif a == "--no-color" then options.noColor = true
    elseif a:sub(1, 1) == "-" and a ~= "-" then error("unknown option: " .. a, 0)
    else options.paths[#options.paths + 1] = a end
    i = i + 1
  end
  return options
end

local function checkLevel(level, flag, allowNever)
  if allowNever and level == "never" then return end
  if not Registry.SEVERITY_RANK[level] then
    error("invalid level for " .. flag .. ": " .. tostring(level), 0)
  end
end

--- Applies severity overrides, disabled rules and thresholds.
local function filterFindings(results, config, options, minRank)
  for _, resource in ipairs(results) do
    local kept = {}
    for _, finding in ipairs(resource.findings) do
      finding.severity = config.severity[finding.rule] or finding.severity
      local keep = Registry.SEVERITY_RANK[finding.severity] >= minRank
        and not config.disable[finding.rule]
        and not (options.disable and options.disable[finding.rule])
        and not (options.only and not options.only[finding.rule])
      if keep then
        for _, pattern in ipairs(config.exclude) do
          if finding.file:find(pattern, 1, true) then keep = false; break end
        end
      end
      if keep then kept[#kept + 1] = finding end
    end
    resource.findings = kept
  end
end

local function scan(args, io_)
  local options = parseArguments(args)
  local config = Config.load(options.config or ".fxaudit.lua", options.config ~= nil)

  local format = options.format or "pretty"
  if format ~= "pretty" and format ~= "json" and format ~= "sarif" then
    error("invalid format: " .. format, 0)
  end
  local minSeverity = options.minSeverity or config.minSeverity or "low"
  local failOn = options.failOn or config.failOn or "high"
  checkLevel(minSeverity, "--min-severity")
  checkLevel(failOn, "--fail-on", true)

  local paths = #options.paths > 0 and options.paths or { "." }
  local results = Project.scan(paths, { globals = config.globals })

  local totalFiles = 0
  for _, resource in ipairs(results) do totalFiles = totalFiles + #resource.files end

  -- The failure threshold applies even to findings hidden from the report.
  filterFindings(results, config, options, math.min(
    Registry.SEVERITY_RANK[minSeverity],
    failOn == "never" and 5 or Registry.SEVERITY_RANK[failOn]))

  local failed = false
  if failOn ~= "never" then
    local threshold = Registry.SEVERITY_RANK[failOn]
    for _, resource in ipairs(results) do
      for _, finding in ipairs(resource.findings) do
        if Registry.SEVERITY_RANK[finding.severity] >= threshold then failed = true end
      end
    end
  end

  local minRank = Registry.SEVERITY_RANK[minSeverity]
  for _, resource in ipairs(results) do
    local visible = {}
    for _, finding in ipairs(resource.findings) do
      if Registry.SEVERITY_RANK[finding.severity] >= minRank then visible[#visible + 1] = finding end
    end
    resource.findings = visible
  end

  local report
  if format == "json" then
    report = Machine.json(results, Cli.VERSION)
  elseif format == "sarif" then
    report = Machine.sarif(results, Cli.VERSION)
  else
    report = Pretty.render(results, {
      color = not options.noColor and not options.output and io_.supportsColor,
      relativeTo = #paths == 1 and Fs.normalize(paths[1]) or nil,
      totalFiles = totalFiles, quiet = options.quiet,
    })
  end

  if options.output then
    local file, err = io.open(options.output, "wb")
    if not file then error("cannot write report: " .. tostring(err), 0) end
    file:write(report)
    file:close()
  else
    io_.write(report)
  end
  return failed and 1 or 0
end

local function listRules(io_)
  local currentCategory
  for _, id in ipairs(Registry.order) do
    local rule = Registry.get(id)
    if rule.category ~= currentCategory then
      currentCategory = rule.category
      io_.write("\n" .. currentCategory:upper() .. "\n")
    end
    io_.write(string.format("  %s  %-8s  %s\n", id, rule.severity, rule.name))
  end
  return 0
end

local function explain(id, io_)
  local rule = id and Registry.get(id:upper())
  if not rule then
    io_.err("unknown rule: " .. tostring(id) .. "\n")
    return 2
  end
  io_.write(string.format("%s %s\nCategory: %s\nDefault severity: %s\n\n%s\n\nTo silence it on one line: -- fxaudit-ignore %s\n",
    rule.id, rule.name, rule.category, rule.severity, rule.description, rule.id))
  return 0
end

--- Runs the CLI.
-- @param args list of arguments
-- @param io_ `{ write, err, supportsColor }`
-- @return number exit code
function Cli.run(args, io_)
  local command = args[1]
  if command == nil or command == "-h" or command == "--help" or command == "help" then
    io_.write(USAGE)
    return command == nil and 2 or 0
  end
  if command == "--version" or command == "-v" then
    io_.write("fxaudit " .. Cli.VERSION .. "\n")
    return 0
  end
  if command == "rules" then return listRules(io_) end
  if command == "explain" then return explain(args[2], io_) end

  -- `fxaudit ./resources` is accepted as a shortcut for `fxaudit scan ./resources`.
  local rest = {}
  local start = command == "scan" and 2 or 1
  for i = start, #args do rest[#rest + 1] = args[i] end

  local ok, result = pcall(scan, rest, io_)
  if not ok then
    io_.err("fxaudit: " .. tostring(result) .. "\n")
    return 2
  end
  return result
end

return Cli
