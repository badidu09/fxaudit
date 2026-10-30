--- Helpers shared by rule specs.
local Analyzer = require("fxaudit.analyzer")

local Support = {}

--- Analyzes one source and returns its findings.
function Support.findings(source, side, extra)
  local input = extra or {}
  input.name = input.name or "test"
  input.files = input.files or {}
  table.insert(input.files, 1, { path = "main.lua", source = source, side = side or "server" })
  return Analyzer.analyzeResource(input).findings
end

--- Returns the findings of rule `id`.
function Support.of(id, source, side, extra)
  local out = {}
  for _, finding in ipairs(Support.findings(source, side, extra)) do
    if finding.rule == id then out[#out + 1] = finding end
  end
  return out
end

--- Number of findings of rule `id`.
function Support.count(id, source, side, extra)
  return #Support.of(id, source, side, extra)
end

return Support
