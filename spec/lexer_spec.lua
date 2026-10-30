local t = require("spec.harness")
local Lexer = require("fxaudit.lexer")

local function kinds(source)
  local tokens = Lexer.tokenize(source)
  local out = {}
  for i = 1, #tokens - 1 do out[i] = tokens[i].type .. ":" .. tostring(tokens[i].value) end
  return table.concat(out, " ")
end

t.describe("lexer", function()
  t.it("reads keywords, names and operators", function()
    t.eq(kinds("local x = 1 .. y"), "keyword:local name:x op:= number:1 op:.. name:y")
  end)

  t.it("reads CfxLua operators", function()
    t.eq(kinds("a += 1 b != c d?.e f?[g]"),
      "name:a op:+= number:1 name:b op:!= name:c name:d op:?. name:e name:f op:?[ name:g op:]")
  end)

  t.it("reads compile-time hashes", function()
    t.eq(kinds("`adder`"), "hash:adder")
  end)

  t.it("collects line, block and C comments", function()
    local tokens, comments = Lexer.tokenize("a -- one\n--[[ two\nthree ]] b /* four\n*/ c")
    t.eq(#comments, 3)
    t.eq(comments[1].text, " one")
    t.eq(comments[2].endLine, 3)
    t.eq(tokens[3].line, 4)
    t.eq(tokens[3].value, "c")
  end)

  t.it("decodes string escapes", function()
    local tokens = Lexer.tokenize('"a\\n\\65\\x42\\u{43}\\z\n       d"')
    t.eq(tokens[1].value, "a\nABCd")
  end)

  t.it("reads long strings and skips the first newline", function()
    local tokens = Lexer.tokenize("[==[\nx]]y]==]")
    t.eq(tokens[1].value, "x]]y")
  end)

  t.it("reads every number form", function()
    local tokens = Lexer.tokenize("3 3.5 .5 1e3 0xFF 0x1p4")
    t.eq(tokens[1].value, 3)
    t.eq(tokens[3].value, 0.5)
    t.eq(tokens[5].value, 255)
    t.eq(tokens[6].value, 16.0)
  end)

  t.it("tracks lines across CRLF", function()
    local tokens = Lexer.tokenize("a\r\nb\r\n\r\nc")
    t.eq(tokens[2].line, 2)
    t.eq(tokens[3].line, 4)
  end)

  t.it("keeps scanning after errors", function()
    local tokens, _, errors = Lexer.tokenize('local s = "oops\nlocal y = 3x\n@ local z')
    t.eq(#errors, 3)
    t.truthy(errors[1].message:find("unfinished string"))
    t.truthy(errors[2].message:find("malformed number"))
    t.truthy(errors[3].message:find("unexpected character"))
    t.eq(tokens[#tokens - 1].value, "z")
  end)

  t.it("explains pasted smart quotes", function()
    local _, _, errors = Lexer.tokenize("print(\u{201C}x\u{201D})")
    t.truthy(errors[1].message:find("smart quote"))
  end)

  t.it("reports unfinished comments and hashes", function()
    local _, _, a = Lexer.tokenize("/* never closed")
    t.truthy(a[1].message:find("unfinished comment"))
    local _, _, b = Lexer.tokenize("`adder\n")
    t.truthy(b[1].message:find("backtick"))
    local _, _, c = Lexer.tokenize("--[[ never closed")
    t.truthy(c[1].message:find("long comment"))
  end)
end)
