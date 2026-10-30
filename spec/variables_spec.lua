local t = require("spec.harness")
local S = require("spec.support")

t.describe("variables", function()
  t.describe("FX200 undefined-global", function()
    t.it("flags an unknown global", function()
      local f = S.of("FX200", "print(nope)")
      t.eq(#f, 1)
      t.eq(f[1].line, 1)
    end)

    t.it("accepts Lua, runtime and natives", function()
      t.eq(S.count("FX200", "print(GetPlayerPed(1), CreateThread, json, Citizen, source)"), 0)
    end)

    t.it("suggests a fix for typos", function()
      local f = S.of("FX200", "TriggerServerEvnet('a')", "client")
      t.eq(f[1].hint, "did you mean 'TriggerServerEvent'?")
    end)

    t.it("suggests the right case", function()
      t.eq(S.of("FX200", "getPlayerPed(1)", "server")[1].hint, "did you mean 'GetPlayerPed'?")
    end)

    t.it("resolves globals defined in another file of the same side", function()
      local extra = { files = { { path = "b.lua", source = "Shared = 1", side = "server" } } }
      t.eq(S.count("FX200", "print(Shared)", "server", extra), 0)
    end)

    t.it("resolves globals from shared files on both sides", function()
      local extra = { files = { { path = "c.lua", source = "Config = {}", side = "shared" } } }
      t.eq(S.count("FX200", "print(Config)", "client", extra), 0)
    end)

    t.it("does not resolve a server global from a client file", function()
      local extra = { files = { { path = "s.lua", source = "OnlyServer = 1", side = "server" } } }
      t.eq(S.count("FX200", "print(OnlyServer)", "client", extra), 1)
    end)

    t.it("accepts imported and configured globals", function()
      t.eq(S.count("FX200", "print(lib)", "server", { importedGlobals = { lib = true } }), 0)
      t.eq(S.count("FX200", "print(Mine)", "server", { customGlobals = { Mine = true } }), 0)
    end)

    t.it("sees _G and rawset definitions", function()
      t.eq(S.count("FX200", "_G.A = 1\nrawset(_G, 'B', 2)\nprint(A, B)"), 0)
    end)

    t.it("ignores presence tests", function()
      t.eq(S.count("FX200", "if Maybe then end\nlocal x = type(Other)\nlocal y = Third or 1\nprint(x, y)"), 0)
    end)

    t.it("lowers confidence when an import is unresolved", function()
      local f = S.of("FX200", "print(zzzzqqq)", "server", { unresolvedImports = { "@foo/bar.lua" } })
      t.eq(f[1].confidence, "low")
      t.truthy(f[1].hint:find("@foo/bar.lua"))
    end)
  end)

  t.describe("FX201 global-leak", function()
    t.it("flags a global created in a function", function()
      local f = S.of("FX201", "local function f() leaked = 1; print(leaked) end\nf()")
      t.eq(#f, 1)
      t.truthy(f[1].message:find("leaks"))
    end)

    t.it("accepts a global declared at top level", function()
      t.eq(S.count("FX201", "State = nil\nlocal function f() State = 1 end\nf()"), 0)
    end)

    t.it("reports each name once", function()
      t.eq(S.count("FX201", "function a() x = 1; x = 2 end\nfunction b() x = 3 end"), 1)
    end)

    t.it("downgrades names shared with other files", function()
      local extra = { files = { { path = "b.lua", source = "print(Shared)", side = "server" } } }
      local f = S.of("FX201", "function a() Shared = 1 end", "server", extra)
      t.eq(f[1].severity, "low")
    end)
  end)

  t.it("FX202 flags a top-level global used in one file only", function()
    t.eq(S.count("FX202", "Lonely = 1\nprint(Lonely)"), 1)
    local extra = { files = { { path = "b.lua", source = "print(Lonely)", side = "server" } } }
    t.eq(S.count("FX202", "Lonely = 1", "server", extra), 0)
  end)

  t.it("FX203 flags an unused local", function()
    t.eq(S.count("FX203", "local a = 1"), 1)
    t.eq(S.count("FX203", "local _a = 1\nlocal _ = 2\nlocal b = 3\nprint(b)"), 0)
  end)

  t.it("FX204 only flags trailing parameters", function()
    local f = S.of("FX204", "local function f(a, b, c) return b end\nf()")
    t.eq(#f, 1)
    t.truthy(f[1].message:find("'c'"))
  end)

  t.it("FX205 flags a local function only used by itself", function()
    t.eq(S.count("FX205", "local function f() f() end"), 1)
    t.eq(S.count("FX205", "local function f() end\nf()"), 0)
  end)

  t.it("FX206 flags write-only locals", function()
    t.eq(S.count("FX206", "local a = 1\na = 2"), 1)
  end)

  t.it("FX207 flags shadowing", function()
    t.eq(S.count("FX207", "local a = 1\nprint(a)\ndo local a = 2\nprint(a) end"), 1)
  end)

  t.it("FX208 flags redefinitions", function()
    t.eq(S.count("FX208", "local a = 1\nprint(a)\nlocal a = 2\nprint(a)"), 1)
  end)

  t.it("FX209 flags locals that are always nil", function()
    t.eq(S.count("FX209", "local a\nprint(a)"), 1)
    t.eq(S.count("FX209", "local a\na = 1\nprint(a)"), 0)
    t.eq(S.count("FX209", "local a, b = f()\nprint(a, b)\nfunction f() end"), 0)
  end)

  t.it("FX210 flags reads before the first write", function()
    t.eq(S.count("FX210", "local a\nprint(a)\na = 1"), 1)
    t.eq(S.count("FX210", "local a\nlocal function f() print(a) end\na = 1\nf()"), 0)
    t.eq(S.count("FX210", "local a\nfor i = 1, 2 do print(a); a = i end"), 0)
  end)

  t.it("FX211 flags use before the local declaration", function()
    local f = S.of("FX211", "local function f() return later end\nlocal later = 1\nprint(f(), later)")
    t.eq(#f, 1)
    t.truthy(f[1].message:find("line 2"))
  end)

  t.it("FX212 flags loop variable writes", function()
    t.eq(S.count("FX212", "for i = 1, 2 do i = 3 end"), 1)
  end)

  t.it("FX213 flags overwritten builtins", function()
    t.eq(S.count("FX213", "print = nil"), 1)
    t.eq(S.count("FX213", "function GetPlayerPed() end"), 1)
    t.eq(S.count("FX213", "Mine = 1"), 0)
  end)

  t.it("FX214 flags unused loop variables", function()
    t.eq(S.count("FX214", "for k, v in pairs({}) do print(v) end"), 1)
    t.eq(S.count("FX214", "for _, v in pairs({}) do print(v) end"), 0)
  end)

  t.it("FX215 flags functions of the other side", function()
    local f = S.of("FX215", "PlayerPedId()", "server")
    t.eq(#f, 1)
    t.eq(S.count("FX200", "PlayerPedId()", "server"), 0)
    t.eq(S.count("FX215", "DropPlayer(1, 'x')", "client"), 1)
    t.eq(S.count("FX215", "PlayerPedId()", "shared"), 0)
    t.eq(S.count("FX215", "print(source)", "client"), 0)
  end)

  t.it("FX216 flags library typos without flagging extensions", function()
    t.eq(S.of("FX216", "string.fromat('x')")[1].hint, "did you mean 'string.format'?")
    t.eq(S.count("FX216", "Citizen.Wiat(1)"), 1)
    t.eq(S.count("FX216", "print(table.contains, math.flor)"), 1)
    t.eq(S.count("FX216", "function string.fromat() end\nstring.fromat()"), 0)
    t.eq(S.count("FX216", "local string = {}\nprint(string.fromat)"), 0)
  end)

  t.describe("suppression", function()
    t.it("honors same-line and previous-line comments", function()
      t.eq(S.count("FX203", "local a = 1 -- fxaudit-ignore FX203"), 0)
      t.eq(S.count("FX203", "-- fxaudit-ignore\nlocal a = 1"), 0)
      t.eq(S.count("FX203", "local a = 1 -- fxaudit-ignore FX999"), 1)
    end)

    t.it("honors file-wide comments", function()
      t.eq(S.count("FX203", "-- fxaudit-ignore-file FX203\nlocal a = 1\nlocal b = 2"), 0)
    end)
  end)
end)
