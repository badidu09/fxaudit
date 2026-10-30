local t = require("spec.harness")
local S = require("spec.support")

t.describe("performance", function()
  t.describe("FX500 loop-without-wait", function()
    t.it("flags a loop that never yields", function()
      local f = S.of("FX500", "CreateThread(function() while true do print(1) end end)")
      t.eq(#f, 1)
      t.eq(f[1].severity, "critical")
      t.eq(f[1].confidence, "high")
    end)

    t.it("accepts every way of yielding", function()
      t.eq(S.count("FX500", "while true do Wait(0) end"), 0)
      t.eq(S.count("FX500", "while true do Citizen.Wait(0) end"), 0)
      t.eq(S.count("FX500", "while true do MySQL.query.await('x') end"), 0)
    end)

    t.it("accepts a wait in a nested block", function()
      t.eq(S.count("FX500", "local a = 1\nwhile true do if a then Wait(1) else Wait(2) end end"), 0)
    end)

    t.it("accepts loops that exit", function()
      t.eq(S.count("FX500", "while true do if f() then break end end\nfunction f() end"), 0)
    end)

    t.it("does not count a wait inside a nested function", function()
      t.eq(S.count("FX500", "while true do local g = function() Wait(1) end\nprint(g) end"), 1)
    end)

    t.it("lowers confidence when a called function may wait", function()
      t.eq(S.of("FX500", "local function tick() end\nwhile true do tick() end")[1].confidence, "medium")
    end)

    t.it("handles repeat until false", function()
      t.eq(S.count("FX500", "repeat print(1) until false"), 1)
    end)
  end)

  t.it("FX501 flags permanent ticks on the client only", function()
    t.eq(S.count("FX501", "while true do Wait(0) end", "client"), 1)
    t.eq(S.count("FX501", "while true do Wait(500) end", "client"), 0)
    t.eq(S.count("FX501", "local s = 1\nwhile true do Wait(s) end", "client"), 0)
    t.eq(S.count("FX501", "while true do Wait(0) end", "server"), 0)
  end)

  t.it("FX502 flags GetPlayerPed(-1)", function()
    t.eq(S.count("FX502", "print(GetPlayerPed(-1))", "client"), 1)
    t.eq(S.count("FX502", "print(GetPlayerPed(2))", "client"), 0)
  end)

  t.it("FX503 flags constant GetHashKey", function()
    t.eq(S.of("FX503", "print(GetHashKey('adder'))")[1].hint, "write `adder`")
    t.eq(S.count("FX503", "local n = 'a'\nprint(GetHashKey(n))"), 0)
  end)

  t.it("FX504 flags slow distance natives", function()
    t.eq(S.count("FX504", "print(Vdist(1, 2, 3, 4, 5, 6))", "client"), 1)
  end)

  t.it("FX505 flags concatenation in loops", function()
    t.eq(S.count("FX505", "local s = ''\nfor i = 1, 3 do s = s .. i end\nprint(s)"), 1)
    t.eq(S.count("FX505", "local s = ''\nfor i = 1, 3 do s ..= i end\nprint(s)"), 1)
    t.eq(S.count("FX505", "for i = 1, 3 do local s = 'a' .. i\nprint(s) end"), 0)
  end)

  t.it("FX506 flags fast broadcasts", function()
    t.eq(S.count("FX506", "while true do Wait(100)\nTriggerClientEvent('a', -1) end"), 1)
    t.eq(S.count("FX506", "while true do Wait(5000)\nTriggerClientEvent('a', -1) end"), 0)
  end)

  t.it("FX507 flags queries in loops, once each", function()
    t.eq(S.count("FX507", "for i = 1, 2 do MySQL.query('x', { i }) end"), 1)
    t.eq(S.count("FX507", "for i = 1, 2 do for j = 1, 2 do MySQL.query('x', { i, j }) end end"), 1)
    t.eq(S.count("FX507", "MySQL.query('x')"), 0)
  end)
end)

t.describe("leaks", function()
  t.it("FX600 flags handlers in loops", function()
    t.eq(S.count("FX600", "while true do Wait(1)\nAddEventHandler('a', print) end"), 1)
    t.eq(S.count("FX600", "AddEventHandler('a', print)"), 0)
    t.eq(S.count("FX600", "for i = 1, 2 do RegisterNetEvent('a:' .. i, print) end"), 0)
    t.eq(S.count("FX600", "for i = 1, 2 do RegisterNetEvent('a', print) print(i) end"), 1)
  end)

  t.it("FX600 resets at function boundaries", function()
    t.eq(S.count("FX600", "for i = 1, 2 do print(function() AddEventHandler('a', print) end, i) end"), 0)
  end)

  t.it("FX601 flags handlers in handlers", function()
    t.eq(S.count("FX601", "AddEventHandler('a', function() AddEventHandler('b', print) end)"), 1)
    t.eq(S.count("FX601", "local function f() AddEventHandler('b', print) end\nf()"), 0)
  end)

  t.it("FX602 flags threads in loops", function()
    t.eq(S.count("FX602", "while true do Wait(1)\nCreateThread(print) end"), 1)
    t.eq(S.count("FX602", "for i = 1, 2 do CreateThread(print) print(i) end"), 0)
  end)

  t.describe("FX603 player-table-not-cleaned", function()
    t.it("flags a table that grows forever", function()
      t.eq(S.count("FX603", "local T = {}\nRegisterNetEvent('a', function() local src = source\nT[src] = 1 end)"), 1)
    end)

    t.it("accepts a cleaned table", function()
      t.eq(S.count("FX603", "local T = {}\nRegisterNetEvent('a', function() T[source] = 1 end)\nAddEventHandler('playerDropped', function() T[source] = nil end)"), 0)
    end)

    t.it("accepts a conditional clear", function()
      t.eq(S.count("FX603", "local T = {}\nlocal function f() local n = 1\nT[source] = n > 0 and n or nil end\nf()"), 0)
    end)

    t.it("ignores tables local to a function", function()
      t.eq(S.count("FX603", "local function f() local T = {}\nT[source] = 1\nreturn T end\nf()"), 0)
    end)

    t.it("only applies to the server", function()
      t.eq(S.count("FX603", "local T = {}\nlocal function f(src) T[src] = 1 end\nf(1)", "client"), 0)
    end)
  end)

  t.it("FX604 balances requests per resource", function()
    t.eq(S.count("FX604", "RequestModel(1)", "client"), 1)
    t.eq(S.count("FX604", "RequestModel(1)\nSetModelAsNoLongerNeeded(1)", "client"), 0)
    t.eq(S.count("FX604", "local function load(m) RequestModel(m) end\nload(1)", "client"), 0)
    local extra = { files = { { path = "b.lua", source = "SetModelAsNoLongerNeeded(1)", side = "client" } } }
    t.eq(S.count("FX604", "RequestModel(1)", "client", extra), 0)
  end)

  t.it("FX605 flags undestroyed DUIs", function()
    t.eq(S.count("FX605", "print(CreateDui('a', 1, 1))", "client"), 1)
  end)

  t.it("FX606 asks for a cleanup", function()
    t.eq(S.count("FX606", "print(AddBlipForCoord(1, 2, 3))", "client"), 1)
    t.eq(S.count("FX606", "print(AddBlipForCoord(1, 2, 3))\nAddEventHandler('onResourceStop', print)", "client"), 0)
  end)

  t.it("FX607 flags focus never released", function()
    t.eq(S.count("FX607", "SetNuiFocus(true, true)", "client"), 1)
    t.eq(S.count("FX607", "SetNuiFocus(true, true)\nSetNuiFocus(false, false)", "client"), 0)
  end)
end)

t.describe("events", function()
  local client = function(source)
    return { files = { { path = "c.lua", source = source, side = "client" } } }
  end

  t.it("FX800 flags a network event without RegisterNetEvent", function()
    t.eq(S.count("FX800", "AddEventHandler('r:a', print)", "server", client("TriggerServerEvent('r:a')")), 1)
    t.eq(S.count("FX800", "RegisterNetEvent('r:a')\nAddEventHandler('r:a', print)", "server", client("TriggerServerEvent('r:a')")), 0)
    t.eq(S.count("FX800", "RegisterNetEvent('r:a', print)", "server", client("TriggerServerEvent('r:a')")), 0)
  end)

  t.it("FX801 flags an event of the resource without handler", function()
    local f = S.of("FX801", "RegisterNetEvent('r:save', print)", "server", client("TriggerServerEvent('r:sav')"))
    t.eq(#f, 1)
    t.eq(f[1].hint, "did you mean 'r:save'?")
  end)

  t.it("FX801 ignores other resources' events", function()
    t.eq(S.count("FX801", "print(1)", "server", client("TriggerServerEvent('other:x')")), 0)
    t.eq(S.count("FX801", "RegisterNetEvent('r:save', print)", "server", client("TriggerServerEvent('esx:x')")), 0)
  end)

  t.it("FX802 flags RegisterServerEvent", function()
    t.eq(S.count("FX802", "RegisterServerEvent('a')"), 1)
  end)

  t.it("FX803 flags a missing target", function()
    t.eq(S.count("FX803", "TriggerClientEvent('a')"), 1)
    t.eq(S.count("FX803", "TriggerClientEvent('a', -1)"), 0)
  end)

  t.it("FX804 flags exports called with a dot", function()
    t.eq(S.count("FX804", "exports.res.fn(1)"), 1)
    t.eq(S.count("FX804", "exports['res'].fn(1)"), 1)
    t.eq(S.count("FX804", "exports.res:fn(1)"), 0)
  end)

  t.it("FX805 checks exports of scanned resources", function()
    local project = { exportsOf = function(name)
      if name == "known" then return { getThing = true } end
    end }
    t.eq(S.of("FX805", "exports.known:getThin()", "server", { project = project })[1].hint, "did you mean 'getThing'?")
    t.eq(S.count("FX805", "exports.known:getThing()", "server", { project = project }), 0)
    t.eq(S.count("FX805", "exports.unknown:x()", "server", { project = project }), 0)
  end)
end)
