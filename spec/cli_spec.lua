local t = require("spec.harness")
local Cli = require("fxaudit.cli")
local Config = require("fxaudit.config")
local Json = require("fxaudit.json")
local Score = require("fxaudit.score")

local EXAMPLE = "examples/vulnerable-resource"

local function run(...)
  local out, err = {}, {}
  local code = Cli.run({ ... }, {
    write = function(text) out[#out + 1] = text end,
    err = function(text) err[#err + 1] = text end,
    supportsColor = false,
  })
  return code, table.concat(out), table.concat(err)
end

t.describe("cli", function()
  t.it("finds every planted problem in the example", function()
    local code, output = run("scan", EXAMPLE, "--all", "--format", "json")
    t.eq(code, 1)
    for _, id in ipairs({
      "FX200", "FX201", "FX215", "FX216", "FX301", "FX306", "FX311", "FX400", "FX401", "FX402",
      "FX404", "FX408", "FX410", "FX412", "FX500", "FX501", "FX502", "FX603", "FX607", "FX703", "FX705", "FX708",
    }) do
      t.truthy(output:find('"rule": "' .. id .. '"', 1, true), id .. " missing from the report")
    end
  end)

  t.it("prints a readable report with hints and a score", function()
    local code, output = run("scan", EXAMPLE)
    t.eq(code, 1)
    t.truthy(output:find("CRITICAL", 1, true))
    t.truthy(output:find("did you mean 'string.format'?", 1, true))
    t.truthy(output:find("Score: ", 1, true))
    t.truthy(output:find("server.lua", 1, true))
  end)

  t.it("produces valid SARIF structure", function()
    local _, output = run("scan", EXAMPLE, "-f", "sarif")
    t.truthy(output:find('"version": "2.1.0"', 1, true))
    t.truthy(output:find('"ruleId": "FX400"', 1, true))
    t.truthy(output:find('"startLine"', 1, true))
  end)

  t.it("applies filters", function()
    local _, only = run("scan", EXAMPLE, "--only", "FX400", "-f", "json", "--fail-on", "never")
    t.truthy(only:find('"FX400"', 1, true))
    t.eq(only:find('"FX500"', 1, true), nil)
    local _, disabled = run("scan", EXAMPLE, "--disable", "FX500", "-f", "json")
    t.eq(disabled:find('"rule": "FX500"', 1, true), nil)
    local _, severe = run("scan", EXAMPLE, "-s", "critical", "-f", "json")
    t.eq(severe:find('"severity": "low"', 1, true), nil)
  end)

  t.it("controls the exit code", function()
    t.eq((run("scan", EXAMPLE, "--fail-on", "never")), 0)
    t.eq((run("scan", EXAMPLE, "--fail-on", "critical")), 1)
    t.eq((run("scan", EXAMPLE, "--only", "FX708", "--fail-on", "high")), 0)
  end)

  t.it("applies the threshold to findings hidden from the report", function()
    t.eq((run("scan", EXAMPLE, "-s", "critical", "--fail-on", "low")), 1)
  end)

  t.it("reports usage errors with code 2", function()
    local code, _, err = run("scan", "--nope")
    t.eq(code, 2)
    t.truthy(err:find("unknown option", 1, true))
    t.eq((run("scan", "does/not/exist")), 2)
    t.eq((run("scan", EXAMPLE, "-f", "xml")), 2)
    t.eq((run("scan", EXAMPLE, "-s", "huge")), 2)
    t.eq((run("explain", "FX999")), 2)
  end)

  t.it("lists and explains rules", function()
    local _, list = run("rules")
    t.truthy(list:find("FX400", 1, true))
    local _, explanation = run("explain", "fx400")
    t.truthy(explanation:find("unvalidated-net-input", 1, true))
  end)
end)

t.describe("config", function()
  t.it("reads constants", function()
    local c = Config.parse([[return {
      globals = { "Mine" }, disable = { "FX203" }, severity = { FX200 = "low" },
      exclude = { "vendor/" }, min_severity = "medium", fail_on = "critical",
    }]])
    t.eq(c.globals.Mine, true)
    t.eq(c.disable.FX203, true)
    t.eq(c.severity.FX200, "low")
    t.eq(c.minSeverity, "medium")
    t.eq(c.failOn, "critical")
  end)

  t.it("refuses anything that would need executing", function()
    t.eq(pcall(Config.parse, "os.execute('x')\nreturn {}"), false)
    t.eq(pcall(Config.parse, "return { globals = os.execute('x') }"), false)
    t.eq(pcall(Config.parse, "return {"), false)
  end)
end)

t.describe("json", function()
  t.it("escapes and sorts", function()
    t.eq(Json.encode({ b = 1, a = 'x"\n' }), '{\n  "a": "x\\"\\n",\n  "b": 1\n}')
    t.eq(Json.encode(Json.array({})), "[]")
    t.eq(Json.encode({ 1, 2 }), "[\n  1,\n  2\n]")
  end)
end)

t.describe("score", function()
  t.it("is 100 without findings", function()
    t.eq(Score.compute({}), 100)
  end)

  t.it("punishes one critical more than many small remarks", function()
    local small = {}
    for i = 1, 30 do small[i] = { severity = "low", confidence = "high" } end
    t.truthy(Score.compute({ { severity = "critical", confidence = "high" } }) < Score.compute(small))
  end)

  t.it("trusts uncertain findings less", function()
    t.truthy(Score.compute({ { severity = "high", confidence = "low" } })
      > Score.compute({ { severity = "high", confidence = "high" } }))
  end)
end)
