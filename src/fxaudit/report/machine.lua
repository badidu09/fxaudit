--- JSON and SARIF reports.
local Json = require("fxaudit.json")
local Registry = require("fxaudit.rules.registry")
local Score = require("fxaudit.score")

local Machine = {}

local SARIF_LEVELS = { critical = "error", high = "error", medium = "warning", low = "note", info = "note" }
local SECURITY_SEVERITY = { critical = "9.5", high = "8.0", medium = "5.0", low = "2.0", info = "0.1" }

--- JSON report with a stable schema, for scripts and dashboards.
function Machine.json(results, version)
  local resources = {}
  for _, resource in ipairs(results) do
    local findings = {}
    for _, f in ipairs(resource.findings) do
      findings[#findings + 1] = {
        rule = f.rule, name = f.name, category = f.category, severity = f.severity,
        confidence = f.confidence, file = f.file, line = f.line, column = f.col,
        message = f.message, hint = f.hint,
      }
    end
    resources[#resources + 1] = {
      name = resource.name, score = Score.compute(resource.findings), findings = Json.array(findings),
    }
  end
  return Json.encode({ tool = "fxaudit", version = version, resources = Json.array(resources) }) .. "\n"
end

--- SARIF 2.1.0 report: GitHub turns it into code scanning alerts on pull requests.
function Machine.sarif(results, version)
  local rules, ruleIndex = {}, {}
  for _, id in ipairs(Registry.order) do
    local rule = Registry.get(id)
    rules[#rules + 1] = {
      id = id, name = rule.name,
      shortDescription = { text = rule.description },
      defaultConfiguration = { level = SARIF_LEVELS[rule.severity] },
      properties = { ["security-severity"] = SECURITY_SEVERITY[rule.severity], tags = Json.array({ rule.category }) },
    }
    ruleIndex[id] = #rules - 1
  end

  local sarifResults = {}
  for _, resource in ipairs(results) do
    for _, f in ipairs(resource.findings) do
      sarifResults[#sarifResults + 1] = {
        ruleId = f.rule, ruleIndex = ruleIndex[f.rule],
        level = SARIF_LEVELS[f.severity],
        message = { text = f.hint and (f.message .. ". " .. f.hint) or f.message },
        locations = Json.array({ {
          physicalLocation = {
            artifactLocation = { uri = (f.file:gsub("^%./", "")) },
            region = { startLine = math.max(f.line or 1, 1), startColumn = math.max(f.col or 1, 1) },
          },
        } }),
      }
    end
  end

  return Json.encode({
    ["$schema"] = "https://json.schemastore.org/sarif-2.1.0.json",
    version = "2.1.0",
    runs = Json.array({ {
      tool = { driver = {
        name = "fxaudit", version = version, informationUri = "https://github.com/badidu09/fxaudit",
        rules = Json.array(rules),
      } },
      results = Json.array(sarifResults),
    } }),
  }) .. "\n"
end

return Machine
