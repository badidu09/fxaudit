--- Test entry point. Run from the repository root: lua spec/run.lua
package.path = "src/?.lua;src/?/init.lua;./?.lua;" .. package.path

local t = require("spec.harness")

for _, name in ipairs({ "lexer", "parser", "scope", "variables", "correctness", "security", "runtime_rules", "project", "cli" }) do
  require("spec." .. name .. "_spec")
end

t.finish()
