local t = require("spec.harness")
local Parser = require("fxaudit.parser")
local Scope = require("fxaudit.scope")
local Known = require("fxaudit.data.known")

local function analyze(source)
  return Scope.analyze(Parser.parse(source))
end

local function var(info, name)
  for _, v in ipairs(info.vars) do
    if v.name == name then return v end
  end
end

t.describe("scope", function()
  t.it("binds locals and leaves the rest global", function()
    local info = analyze("local a = 1\nprint(a, b)\nc = 2")
    t.eq(var(info, "a").reads, 1)
    t.eq(#info.globals, 3)
    t.eq(info.globals[3].name, "c")
    t.eq(info.globals[3].write, true)
  end)

  t.it("does not see a local in its own initializer", function()
    local info = analyze("local a = a")
    t.eq(var(info, "a").reads, 0)
    t.eq(info.globals[1].name, "a")
  end)

  t.it("lets a local function call itself", function()
    local info = analyze("local function f() f() end")
    t.eq(var(info, "f").reads, 0)
    t.eq(var(info, "f").selfReads, 1)
    t.eq(#info.globals, 0)
  end)

  t.it("lets 'until' see the loop body locals", function()
    local info = analyze("repeat local x = 1 until x")
    t.eq(var(info, "x").reads, 1)
  end)

  t.it("closes block scopes", function()
    local info = analyze("do local x = 1 end\nprint(x)")
    t.eq(var(info, "x").reads, 0)
    t.eq(info.globals[2].name, "x")
  end)

  t.it("tracks shadowing and redefinition", function()
    local info = analyze("local a = 1\nlocal function f(a) return a end\nf(a)\nlocal b\nlocal b")
    t.eq(info.vars[3].shadows.line, 1)
    t.eq(info.vars[#info.vars].redefines.line, 4)
  end)

  t.it("declares self for methods", function()
    local info = analyze("local M = {}\nfunction M:f() return self end")
    t.eq(#info.globals, 0)
    t.eq(var(info, "self").reads, 1)
  end)

  t.it("flags writes inside functions", function()
    local info = analyze("x = 1\nfunction f() y = 2 end")
    t.eq(info.globals[1].inFunction, false)
    t.eq(info.globals[3].name, "y")
    t.eq(info.globals[3].inFunction, true)
  end)

  t.it("marks function definitions", function()
    local info = analyze("function f() end")
    t.eq(info.globals[1].isDefinition, true)
  end)

  t.it("rejects writes to const and close", function()
    local info = analyze("local a <const> = 1\na = 2\nlocal b <close> = nil\nb = 3")
    t.eq(#info.problems, 2)
    t.truthy(info.problems[1].message:find("<const>"))
  end)

  t.it("resolves goto and labels", function()
    local info = analyze([[
      for i = 1, 2 do
        if i then goto continue end
        ::continue::
      end
      goto nowhere
      function f() goto continue end
      ::a:: ::a::
    ]])
    t.eq(#info.problems, 3)
  end)

  t.it("handles in-unpacking and compound assignment", function()
    local info = analyze("local t = {}\nlocal a, b in t\na += 1\nz += 1")
    t.eq(var(info, "t").reads, 1)
    t.eq(var(info, "a").hasInit, true)
    t.eq(info.globals[1].compound, "+")
  end)
end)

t.describe("known globals", function()
  t.it("knows Lua, runtime and natives", function()
    t.truthy(Known.exists("print", "client"))
    t.truthy(Known.exists("CreateThread", "server"))
    t.truthy(Known.exists("PlayerPedId", "client"))
    t.truthy(Known.exists("N_0x1234abcd", "client"))
    t.truthy(Known.exists("DropPlayer", "server"))
  end)

  t.it("rejects unknown names", function()
    t.eq(Known.exists("TriggerServerEvnet", "client"), false)
  end)

  t.it("detects natives used on the wrong side", function()
    t.eq(Known.wrongSide("PlayerPedId", "server"), "client")
    t.eq(Known.wrongSide("DropPlayer", "client"), "server")
    t.eq(Known.wrongSide("TriggerClientEvent", "client"), "server")
    t.eq(Known.wrongSide("source", "client"), "server")
    t.eq(Known.wrongSide("GetPlayerPed", "server"), nil)
    t.eq(Known.wrongSide("PlayerPedId", "shared"), nil)
  end)
end)
