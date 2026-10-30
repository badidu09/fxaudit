local t = require("spec.harness")
local Parser = require("fxaudit.parser")

local function clean(source)
  local chunk = Parser.parse(source)
  if #chunk.errors > 0 then
    error("unexpected syntax error: " .. chunk.errors[1].message .. " at line " .. chunk.errors[1].line, 2)
  end
  return chunk
end

local function messages(source)
  local chunk = Parser.parse(source)
  local out = {}
  for i, e in ipairs(chunk.errors) do out[i] = e.message end
  return out, chunk
end

t.describe("parser", function()
  t.describe("valid code", function()
    t.it("parses every Lua 5.4 statement", function()
      local chunk = clean([[
        local a <const>, b <close> = 1, nil
        local function f(x, ...) return x, ... end
        function M.a.b:c(y) return self, y end
        a2, b2 = 1, 2
        do local z end
        while true do break end
        repeat local q = 1 until q == 1
        for i = 1, 10, 2 do print(i) end
        for k, v in pairs({}) do print(k, v) end
        if a then elseif b then else end
        goto done
        ::done::
        return f(1)
      ]])
      t.eq(#chunk.body, 13)
      t.eq(chunk.body[1].names[1].attrib, "const")
      t.eq(chunk.body[3].isMethod, true)
    end)

    t.it("respects operator precedence", function()
      local e = clean("x = 1 + 2 * 3 ^ 2 .. 'a'").body[1].values[1]
      t.eq(e.op, "..")
      t.eq(e.left.op, "+")
      t.eq(e.left.right.op, "*")
      t.eq(e.left.right.right.op, "^")
    end)

    t.it("applies 'not' before comparison", function()
      local e = clean("x = not a == b").body[1].values[1]
      t.eq(e.op, "==")
      t.eq(e.left.type, "Unop")
    end)

    t.it("parses CfxLua extensions", function()
      local chunk = clean([[
        local h = `adder`
        local n = t?.a?.b
        local m = t?[1]
        x += 1
        x ..= "s"
        if a != b then end
        local p, q in t
        local s = { .a, .b }
        /* block */
      ]])
      t.eq(chunk.body[1].values[1].type, "Hash")
      t.eq(chunk.body[2].values[1].safe, true)
      t.eq(chunk.body[4].compound, "+")
      t.eq(chunk.body[6].clauses[1].cond.op, "~=")
      t.eq(chunk.body[7].unpackFrom.name, "t")
      t.eq(chunk.body[8].values[1].fields[1].name, "a")
    end)

    t.it("keeps defer usable as an identifier", function()
      local chunk = clean("local defer = 1\ndefer = 2\ndefer(3)\ndefer print(1) end")
      t.eq(chunk.body[2].type, "Assign")
      t.eq(chunk.body[3].type, "CallStat")
      t.eq(chunk.body[4].type, "Defer")
    end)

    t.it("parses call sugar and string methods", function()
      local chunk = clean([[
        fx_version 'cerulean'
        my_data 'one' { two = 42 }
        local u = ("x"):upper()
        f{ 1, [2] = 3, a = 4; 5 }
      ]])
      t.eq(chunk.body[2].expr.func.type, "Call")
      t.eq(chunk.body[3].values[1].type, "MethodCall")
    end)

    t.it("accepts a BOM and a shebang", function()
      clean("\239\187\191local a = 1")
      clean("#!/usr/bin/env lua\nlocal a = 1")
    end)
  end)

  t.describe("error reporting", function()
    t.it("reports every error of a file, not only the first", function()
      local list = messages([[
        local a = = 1
        local b = 2
        if b = 2 then
        end
        print((1)
        local c = 3
      ]])
      t.eq(#list >= 3, true, "error count " .. #list)
    end)

    t.it("names the line of an unclosed block", function()
      local list = messages("function f()\n  if x then\n    y()\n")
      t.truthy(list[1]:find("'if' opened at line 2"), list[1])
    end)

    t.it("explains '=' used in a condition", function()
      t.truthy(messages("if a = 1 then end")[1]:find("use '=='"))
      t.truthy(messages("while a = 1 do end")[1]:find("use '=='"))
    end)

    t.it("explains 'else if'", function()
      t.truthy(messages("if a then else if b then end end")[1]:find("elseif"))
    end)

    t.it("rejects misplaced break, vararg and return", function()
      t.truthy(messages("break")[1]:find("inside a loop"))
      t.truthy(messages("function f() return ... end")[1]:find("vararg"))
      t.truthy(messages("function f() return 1 print(2) end")[1]:find("last statement"))
      t.truthy(messages("while a do function g() break end end")[1]:find("inside a loop"))
    end)

    t.it("reports a surplus 'end'", function()
      t.truthy(messages("local a = 1\nend")[1]:find("one 'end' too many"))
    end)

    t.it("detects statements that do nothing", function()
      t.truthy(messages("a.b")[1]:find("does nothing"))
      t.truthy(messages("a == 1")[1]:find("did you mean '='"))
    end)

    t.it("rejects assignment to a call", function()
      t.truthy(messages("f() = 1")[1]:find("function call"))
    end)

    t.it("reports a missing comma between table fields", function()
      t.truthy(messages("local t = {\n a = 1\n b = 2\n}")[1]:find("missing ','"))
    end)

    t.it("reports a reserved word used as a name", function()
      t.truthy(messages("local end = 1")[1]:find("reserved word"))
    end)

    t.it("still produces an AST for the valid part", function()
      local _, chunk = messages("local a = 1\nlocal b = = 2\nlocal c = 3")
      t.eq(chunk.body[1].names[1].name, "a")
      t.eq(chunk.body[#chunk.body].names[1].name, "c")
    end)

    t.it("never loops forever on garbage", function()
      messages(string.rep("end ) ] } = ", 500))
      messages(string.rep("function ( ", 100))
    end)
  end)
end)
