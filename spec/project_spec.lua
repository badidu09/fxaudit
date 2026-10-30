local t = require("spec.harness")
local Manifest = require("fxaudit.manifest")
local Glob = require("fxaudit.glob")

t.describe("manifest", function()
  t.it("reads directives without executing anything", function()
    local m = Manifest.parse([[
      fx_version 'cerulean'
      games { 'gta5', 'rdr3' }
      author 'me'
      shared_script '@ox_lib/init.lua'
      client_scripts { 'a.lua', 'client/*.lua' }
      server_script 'b.lua'
      my_data 'one' { two = 42 }
      data_file 'HANDLING_FILE' 'x.meta'
      os.execute('never run')
    ]])
    t.eq(m.values.fx_version, "cerulean")
    t.eq(#m.lists.games, 2)
    t.eq(m.lists.shared_scripts[1].value, "@ox_lib/init.lua")
    t.eq(m.lists.client_scripts[2].value, "client/*.lua")
    t.eq(m.lists.server_scripts[1].value, "b.lua")
    t.eq(m.values.author, "me")
    t.eq(m.values.my_data, "one")
  end)

  t.it("flags statements it cannot evaluate", function()
    local m = Manifest.parse("for i = 1, 2 do client_script('a') end")
    t.eq(#m.dynamic, 1)
    local n = Manifest.parse("local list = {}\nclient_scripts(list)")
    t.eq(#n.dynamic, 1)
  end)

  t.it("reports syntax errors", function()
    t.eq(#Manifest.parse("client_scripts { 'a' ").errors, 1)
  end)
end)

t.describe("glob", function()
  t.it("keeps * inside a directory", function()
    t.truthy(Glob.matches("*.lua", "a.lua"))
    t.eq(Glob.matches("*.lua", "dir/a.lua"), false)
    t.truthy(Glob.matches("client/*.lua", "client/a.lua"))
    t.eq(Glob.matches("client/*.lua", "client/sub/a.lua"), false)
  end)

  t.it("lets ** cross directories", function()
    t.truthy(Glob.matches("**/*.lua", "a.lua"))
    t.truthy(Glob.matches("**/*.lua", "d1/a.lua"))
    t.truthy(Glob.matches("**/*.lua", "d1/d2/a.lua"))
    t.truthy(Glob.matches("**.lua", "d1/a.lua"))
    t.truthy(Glob.matches("web/**/*", "web/a/b.html"))
    t.truthy(Glob.matches("**/cl_*.lua", "d/cl_a.lua"))
    t.eq(Glob.matches("**/cl_*.lua", "d/sv_a.lua"), false)
  end)

  t.it("escapes pattern characters", function()
    t.truthy(Glob.matches("a-b.lua", "a-b.lua"))
    t.eq(Glob.matches("a.lua", "axlua"), false)
  end)
end)
