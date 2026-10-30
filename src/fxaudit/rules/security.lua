--- FX4xx: exploitable events, backdoors, exposed secrets, SQL injection.
local Ast = require("fxaudit.ast")
local Events = require("fxaudit.events")

local Security = {}

local function set(words)
  local out = {}
  for word in words:gmatch("%S+") do out[word] = true end
  return out
end

-- Operations changing the economy, permissions or a player's state.
local ECONOMY_SINKS = set([[
  addMoney removeMoney setMoney addAccountMoney removeAccountMoney setAccountMoney
  AddMoney RemoveMoney SetMoney addInventoryItem removeInventoryItem setInventoryItem
  AddItem RemoveItem GiveItem addWeapon removeWeapon GiveWeaponToPed
  setJob SetJob setGroup SetGroup SetPermission AddPermission SetMetaData
]])

local IDENTITY_SINKS = set("DropPlayer GetPlayerFromId GetPlayer")

local SQL_METHODS = set([[
  query execute insert update scalar single prepare rawExecute transaction
  fetchAll fetchScalar fetchSync
]])

-- Sanitizers whose result is bounded regardless of the input.
local BOUNDING_CALLS = set("math.min math.max math.clamp lib.math.clamp")

local YIELD_CALLS = set("Wait Citizen.Wait Citizen.Await Await")

local SECRET_NAME_PARTS = { "password", "passwd", "apikey", "api_key", "secret", "webhook", "token", "licensekey" }
local PLACEHOLDERS = { "your", "xxx", "change", "example", "placeholder", "insert", "here", "http://", "none", "default" }

local MALWARE_MARKERS = { "cipher%-panel", "ciphercheats", "blum%-panel", "blumpanel" }

local CLIENT_VALUE_NAMES = set("price amount money cost reward salary payment cash total")

local function isSql(node)
  local short = Ast.shortCallName(node)
  if not short or not SQL_METHODS[short] then return false end
  local name = Ast.callName(node) or ""
  return name:find("MySQL", 1, true) ~= nil or name:find("oxmysql", 1, true) ~= nil
    or name:find("ghmattimysql", 1, true) ~= nil
end

--- Whether an expression builds its text at runtime from non-constant parts.
local function isDynamicString(expr)
  expr = Ast.unparen(expr)
  if expr.type == "Binop" and expr.op == ".." then
    local dynamic = false
    local function scan(node)
      node = Ast.unparen(node)
      if node.type == "Binop" and node.op == ".." then
        scan(node.left)
        scan(node.right)
      elseif node.type ~= "String" and node.type ~= "Number" then
        -- SCREAMING_CASE names are conventionally constants such as table names.
        if not (node.type == "Name" and node.name:match("^[A-Z_][A-Z0-9_]*$")) then dynamic = true end
      end
    end
    scan(expr)
    return dynamic
  end
  if expr.type == "Call" and Ast.path(expr.func) == "string.format" then return #expr.args > 1 end
  if expr.type == "MethodCall" and expr.method == "format" then return #expr.args > 0 end
  return false
end

--- Follows client-controlled values through one handler, in source order.
local function analyzeHandler(ctx, handler, reported)
  local func = handler.func
  if not func or not func.paramVars then return end

  local tainted, validated = {}, {}
  for i, var in ipairs(func.paramVars) do
    if i > handler.skip then tainted[var] = true end
  end

  --- Returns the first unvalidated tainted variable in `expr`.
  local function mention(expr)
    expr = Ast.unparen(expr)
    local kind = expr.type
    if kind == "Name" then
      if expr.var and tainted[expr.var] and not validated[expr.var] then return expr.var end
    elseif kind == "Index" then
      -- Config.Items[item] reads a server-owned value: only the object carries taint.
      return mention(expr.object)
    elseif kind == "Binop" then
      return mention(expr.left) or mention(expr.right)
    elseif kind == "Unop" then
      return mention(expr.operand)
    elseif kind == "Call" then
      local path = Ast.path(expr.func)
      if path and BOUNDING_CALLS[path] then return nil end
      for _, arg in ipairs(expr.args) do
        local found = mention(arg)
        if found then return found end
      end
    elseif kind == "MethodCall" then
      local found = mention(expr.object)
      if found then return found end
      for _, arg in ipairs(expr.args) do
        found = mention(arg)
        if found then return found end
      end
    elseif kind == "Table" then
      for _, field in ipairs(expr.fields) do
        local found = mention(field.value)
        if found then return found end
      end
    end
    return nil
  end

  --- A real check compares, indexes or passes the value; `if x then` proves nothing.
  local function validate(expr, boolContext)
    expr = Ast.unparen(expr)
    local kind = expr.type
    if kind == "Name" then
      if expr.var and not boolContext then validated[expr.var] = true end
    elseif kind == "Index" then
      validate(expr.object, false)
      if not expr.dotted then validate(expr.key, false) end
    elseif kind == "Binop" then
      local logical = expr.op == "and" or expr.op == "or"
      validate(expr.left, logical and boolContext)
      validate(expr.right, logical and boolContext)
    elseif kind == "Unop" then
      validate(expr.operand, expr.op == "not" and boolContext)
    elseif kind == "Call" then
      for _, arg in ipairs(expr.args) do validate(arg, false) end
    elseif kind == "MethodCall" then
      validate(expr.object, false)
      for _, arg in ipairs(expr.args) do validate(arg, false) end
    end
  end

  local visitBody

  local function checkCall(node)
    local short = Ast.shortCallName(node)
    if not short then return end
    local args = node.args

    if ECONOMY_SINKS[short] or short == "ExecuteCommand" then
      for _, arg in ipairs(args) do
        local var = mention(arg)
        if var and not reported[node] then
          reported[node] = true
          ctx.report("FX400", node, "'" .. var.name .. "' comes from the client (event '" .. handler.event .. "') and reaches " .. short .. " without validation", {
            hint = "check its type and bounds, or recompute the value on the server from your config",
          })
          break
        end
      end
    elseif IDENTITY_SINKS[short] and handler.kind == "net" then
      local var = args[1] and mention(args[1])
      if var and var.kind == "param" and not reported[node] then
        reported[node] = true
        ctx.report("FX411", node, "'" .. var.name .. "' is a player id sent by the client (event '" .. handler.event .. "') and is used by " .. short .. " without validation", {
          hint = "use 'source' for the caller; for a target, check the caller's permission and the distance first",
          confidence = "medium",
        })
      end
    elseif (short == "load" or short == "loadstring") and args[1] then
      local var = mention(args[1])
      if var and not reported[node] then
        reported[node] = true
        ctx.report("FX404", node, "'" .. var.name .. "' comes from the client (event '" .. handler.event .. "') and is executed as code")
      end
    elseif isSql(node) and args[1] and isDynamicString(args[1]) then
      local var = mention(args[1])
      if var and not reported[node] then
        reported[node] = true
        ctx.report("FX410", node, "'" .. var.name .. "' comes from the client and is concatenated into a SQL query", {
          hint = "use a placeholder: MySQL.query('... WHERE id = ?', { value })",
        })
      end
    end

    if short == "assert" or short == "type" then
      for _, arg in ipairs(args) do validate(arg, false) end
    end
  end

  local function visitExpr(expr)
    if not expr then return end
    Ast.walk(expr, function(node)
      if node.type == "Function" then
        visitBody(node.body)
        return false
      elseif node.type == "Call" or node.type == "MethodCall" then
        checkCall(node)
      elseif node.type == "Binop" and node.op == "and" then
        validate(node.left, true)
      end
    end)
  end

  local function propagate(var, value)
    if value and mention(value) then
      tainted[var] = true
      validated[var] = nil
    else
      tainted[var] = nil
    end
  end

  local function visitStatement(statement)
    local kind = statement.type
    if kind == "Local" then
      for _, value in ipairs(statement.values) do visitExpr(value) end
      for i, var in ipairs(statement.vars or {}) do propagate(var, statement.values[i]) end
    elseif kind == "Assign" then
      for _, value in ipairs(statement.values) do visitExpr(value) end
      for i, target in ipairs(statement.targets) do
        if target.type == "Name" and target.var then propagate(target.var, statement.values[i]) end
      end
    elseif kind == "CallStat" then
      visitExpr(statement.expr)
    elseif kind == "If" then
      for _, clause in ipairs(statement.clauses) do
        visitExpr(clause.cond)
        validate(clause.cond, true)
        visitBody(clause.body)
      end
      if statement.orelse then visitBody(statement.orelse) end
    elseif kind == "While" or kind == "Repeat" then
      visitExpr(statement.cond)
      validate(statement.cond, true)
      visitBody(statement.body)
    elseif kind == "NumFor" then
      visitExpr(statement.start)
      visitExpr(statement.stop)
      visitBody(statement.body)
    elseif kind == "GenFor" then
      for _, expr in ipairs(statement.exprs) do visitExpr(expr) end
      visitBody(statement.body)
    elseif kind == "Do" or kind == "Defer" then
      visitBody(statement.body)
    elseif kind == "Return" then
      for _, value in ipairs(statement.values) do visitExpr(value) end
    elseif kind == "LocalFunction" or kind == "FunctionStat" then
      visitBody(statement.func.body)
    end
  end

  visitBody = function(body)
    for _, statement in ipairs(body) do visitStatement(statement) end
  end

  visitBody(func.body)
end

--- FX401: an event that pays out with no condition of any kind.
local function checkUnguarded(ctx, handler, reported)
  if handler.kind ~= "net" or not handler.func then return end
  local guarded, sink = false, nil
  Ast.walk(handler.func, function(node)
    if node.type == "If" or node.type == "While" then
      guarded = true
    elseif node.type == "Call" or node.type == "MethodCall" then
      local short = Ast.shortCallName(node)
      if short == "assert" then guarded = true end
      if short and ECONOMY_SINKS[short] and not sink then sink = node end
    elseif node.type == "Binop" and (node.op == "and" or node.op == "or") then
      guarded = true
    end
  end)
  if sink and not guarded and not reported[sink] then
    reported[sink] = true
    ctx.report("FX401", sink, "any client can trigger '" .. handler.event .. "' as often as it wants: there is no check before " .. Ast.shortCallName(sink), {
      hint = "start the action on the server, then check permission, distance and cooldown here",
    })
  end
end

--- FX402: `source` changes as soon as the handler yields.
local function checkSourceAfterYield(ctx, handler)
  if not handler.func then return end
  local yielded, done = false, false

  local function isYield(node)
    if node.type ~= "Call" and node.type ~= "MethodCall" then return false end
    local path = Ast.path(node.type == "Call" and node.func or node.object)
    if path and YIELD_CALLS[path] then return true end
    if node.type == "Call" and path and path:match("%.await$") then return true end
    return false
  end

  local function scan(node, nested)
    if done then return end
    Ast.children(node, function(child)
      if done then return end
      if child.type == "Name" and child.name == "source" and not child.var then
        if nested or yielded then
          done = true
          ctx.report("FX402", child, nested
            and "'source' is read inside a callback, which runs later: it may be another player by then"
            or "'source' is read after a yield: it may be another player by now", {
            hint = "copy it first: local src = source",
          })
        end
        return
      end
      scan(child, nested or child.type == "Function")
      if isYield(child) then yielded = true end
    end)
  end

  scan(handler.func, false)
end

local function checkHandlers(ctx, netEvents, reported)
  for _, handler in ipairs(ctx.eventScan.handlers) do
    if handler.kind == "local" and netEvents[handler.event] then handler.kind = "net" end
    if handler.kind == "net" or handler.kind == "callback" then
      analyzeHandler(ctx, handler, reported)
      checkUnguarded(ctx, handler, reported)
    end
    checkSourceAfterYield(ctx, handler)
  end
end

--- Collects the functions given as callbacks to PerformHttpRequest.
local function collectHttpCallbacks(chunk)
  local inside = {}
  Ast.walk(chunk, function(node)
    if node.type == "Call" then
      local path = Ast.path(node.func)
      if path == "PerformHttpRequest" or path == "PerformHttpRequestAwait" then
        for _, arg in ipairs(node.args) do
          if arg.type == "Function" then inside[arg] = true end
        end
      end
    end
  end)
  return inside
end

local function checkDynamicCode(ctx, reported)
  local httpCallbacks = collectHttpCallbacks(ctx.chunk)
  local depth = 0
  Ast.walk(ctx.chunk, function(node)
    if httpCallbacks[node] then depth = depth + 1 end
    if node.type == "Call" and not reported[node] then
      local path = Ast.path(node.func)
      if (path == "load" or path == "loadstring") and node.args[1] and not node.func.var then
        local arg = Ast.unparen(node.args[1])
        if depth > 0 then
          ctx.report("FX404", node, "code received from an HTTP request is executed: whoever controls that server controls yours", {
            hint = "unless you wrote this yourself, treat this resource as compromised",
          })
        elseif arg.type ~= "String" then
          local fromResource = arg.type == "Call" and Ast.path(arg.func) == "LoadResourceFile"
          if not fromResource then
            ctx.report("FX403", node, "code is compiled from a value only known at runtime", {
              confidence = "medium", severity = "medium",
              hint = "check where this value comes from: it must never come from a player or the network",
            })
          end
        end
      end
    end
  end, function(node)
    if httpCallbacks[node] then depth = depth - 1 end
  end)
end

local function checkSystemCommands(ctx)
  Ast.walk(ctx.chunk, function(node)
    if node.type == "Call" then
      local path = Ast.path(node.func)
      if path == "os.execute" or path == "io.popen" then
        ctx.report("FX407", node, path .. " runs operating system commands; FiveM scripts have no legitimate need for it")
      end
    end
  end)
end

local function checkObfuscation(ctx)
  local escapes, firstLine, longestLine, lineNumber = 0, nil, 0, 0
  for line in (ctx.source .. "\n"):gmatch("(.-)\r?\n") do
    lineNumber = lineNumber + 1
    if #line > longestLine then longestLine = #line end
    local _, hex = line:gsub("\\x%x%x", "")
    local _, dec = line:gsub("\\%d%d?%d?", "")
    if hex + dec >= 8 then
      escapes = escapes + hex + dec
      firstLine = firstLine or lineNumber
    end
  end

  if escapes >= 40 then
    ctx.report("FX405", { line = firstLine, col = 1 }, escapes .. " escaped characters hide the text of this file's strings", {
      hint = "decode them before trusting this script; legitimate code rarely needs this",
    })
    return
  end

  local dynamicG, charCalls = nil, 0
  Ast.walk(ctx.chunk, function(node)
    if node.type == "Index" and not node.dotted and node.object.type == "Name"
      and (node.object.name == "_G" or node.object.name == "_ENV") and node.key.type ~= "String"
      and not node.object.var then
      dynamicG = dynamicG or node
    elseif node.type == "Call" and Ast.path(node.func) == "string.char" then
      charCalls = charCalls + 1
    end
  end)
  if dynamicG and charCalls >= 5 then
    ctx.report("FX405", dynamicG, "functions are looked up through _G with names assembled at runtime by string.char", {
      hint = "this pattern hides which functions are really called",
    })
  elseif longestLine > 20000 and not ctx.path:find("%.min%.") then
    ctx.report("FX405", { line = 1, col = 1 }, "this file has a line of " .. longestLine .. " characters: the code is minified or obfuscated", {
      confidence = "medium", severity = "medium",
    })
  end
end

local function isPlaceholder(value)
  local lowered = value:lower()
  for _, marker in ipairs(PLACEHOLDERS) do
    if lowered:find(marker, 1, true) then return true end
  end
  return false
end

local function looksLikeSecretName(name)
  local lowered = name:lower()
  for _, part in ipairs(SECRET_NAME_PARTS) do
    if lowered:find(part, 1, true) then return true end
  end
  return false
end

local function checkSecrets(ctx)
  local exposed = ctx.side == "client" or ctx.side == "shared"
  local reported = {}

  local function report(node, what)
    if reported[node] then return end
    reported[node] = true
    if exposed then
      ctx.report("FX408", node, what .. " in a " .. ctx.side .. " file: it is sent to every player", {
        hint = "move it to a server convar: 'set my_key ...' and GetConvar('my_key', '')",
      })
    else
      ctx.report("FX409", node, what .. " in the source code", {
        hint = "move it to a convar ('set', not 'sets' or 'setr'), so it stays out of your git history",
      })
    end
  end

  local function checkNamed(name, value)
    if not name or not value then return end
    value = Ast.unparen(value)
    if value.type == "String" and #value.value >= 8 and not value.value:find("%s")
      and looksLikeSecretName(name) and not isPlaceholder(value.value) then
      report(value, "'" .. name .. "' looks like a hardcoded secret")
    end
  end

  Ast.walk(ctx.chunk, function(node)
    if node.type == "String" then
      local value = node.value
      if value:find("discord%.com/api/webhooks/%d+/") or value:find("discordapp%.com/api/webhooks/%d+/") then
        report(node, "a Discord webhook URL is hardcoded")
      elseif value:find("^sk_live_%w+") or value:find("^ghp_%w+") or value:find("^xox[bap]%-%w+") then
        report(node, "an API key is hardcoded")
      else
        local lowered = value:lower()
        for _, marker in ipairs(MALWARE_MARKERS) do
          if lowered:find(marker) then
            ctx.report("FX406", node, "this string references a known FiveM backdoor infrastructure", {
              hint = "treat the resource as compromised: remove it, then audit your server and rotate your secrets",
            })
            break
          end
        end
      end
    elseif node.type == "Local" then
      for i, info in ipairs(node.names) do checkNamed(info.name, node.values[i]) end
    elseif node.type == "Assign" then
      for i, target in ipairs(node.targets) do
        local name = target.type == "Name" and target.name or (target.type == "Index" and target.name)
        checkNamed(name, node.values[i])
      end
    elseif node.type == "Table" then
      for _, field in ipairs(node.fields) do
        if field.kind == "named" then checkNamed(field.name, field.value) end
      end
    end
  end)
end

local function checkSqlConcatenation(ctx, reported)
  Ast.walk(ctx.chunk, function(node)
    if (node.type == "Call" or node.type == "MethodCall") and not reported[node] and isSql(node)
      and node.args[1] and isDynamicString(node.args[1]) then
      reported[node] = true
      ctx.report("FX410", node, "this SQL query is built by concatenation: any value reaching it can change the query", {
        severity = "high", confidence = "medium",
        hint = "use a placeholder: MySQL.query('... WHERE id = ?', { value })",
      })
    end
  end)
end

local function checkClientValues(ctx)
  if ctx.side ~= "client" then return end
  for _, trigger in ipairs(ctx.eventScan.triggers) do
    if trigger.side == "server" then
      for i = 2, #trigger.node.args do
        local arg = Ast.unparen(trigger.node.args[i])
        local name = (arg.type == "Name" and arg.name) or (arg.type == "Index" and arg.name) or nil
        if name and CLIENT_VALUE_NAMES[name:lower()] then
          ctx.report("FX412", arg, "'" .. name .. "' is sent to the server by event '" .. trigger.event .. "': a cheater can send any value", {
            hint = "send what the player wants (an item name), and let the server compute the price",
            confidence = "medium",
          })
        end
      end
    end
  end
end

function Security.checkResource(resource)
  -- A RegisterNetEvent in one file makes an AddEventHandler in another one client-callable.
  local netEvents = {}
  for _, ctx in ipairs(resource.files) do
    ctx.eventScan = ctx.eventScan or Events.scan(ctx.chunk)
    if ctx.side == "server" or ctx.side == "shared" or ctx.side == "unknown" then
      for event in pairs(ctx.eventScan.netRegistered) do netEvents[event] = true end
    end
  end

  for _, ctx in ipairs(resource.files) do
    local reported = {}
    if ctx.side == "server" or ctx.side == "shared" or ctx.side == "unknown" then
      checkHandlers(ctx, netEvents, reported)
    end
    checkDynamicCode(ctx, reported)
    checkSystemCommands(ctx)
    checkObfuscation(ctx)
    checkSecrets(ctx)
    checkSqlConcatenation(ctx, reported)
    checkClientValues(ctx)
  end
end

return Security
