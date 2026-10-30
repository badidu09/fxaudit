--- FX5xx: freezes and needless per-frame or per-iteration work.
local Ast = require("fxaudit.ast")
local Known = require("fxaudit.data.known")

local Performance = {}

local YIELDS = {
  Wait = true, ["Citizen.Wait"] = true, ["Citizen.Await"] = true, Await = true,
  ["coroutine.yield"] = true,
}

local FRAME_NATIVE_PREFIXES = { "Draw", "IsControl", "IsDisabledControl", "DisableControl", "SetText", "EnableControl" }

local function isSqlCall(node)
  local name = Ast.callName(node)
  if not name then return false end
  return name:find("^MySQL%.") ~= nil or name:find("oxmysql", 1, true) ~= nil
end

--- Summarizes a loop body, without entering nested functions.
local function inspectLoop(body)
  local summary = { yields = false, exits = false, userCalls = false, waits = {}, frameNatives = false, broadcast = nil }
  Ast.walk({ type = "Do", body = body }, function(node)
    if node.type == "Function" then return false end
    if node.type == "Break" or node.type == "Return" or node.type == "Goto" then
      summary.exits = true
    elseif node.type == "Call" or node.type == "MethodCall" then
      local path = node.type == "Call" and Ast.path(node.func) or nil
      if path and YIELDS[path] then
        summary.yields = true
        if path == "Wait" or path == "Citizen.Wait" then
          local arg = node.args[1] and Ast.unparen(node.args[1])
          summary.waits[#summary.waits + 1] = arg and arg.type == "Number" and arg.value or false
        end
      elseif node.type == "Call" and path and path:match("%.await$") then
        summary.yields = true
      elseif node.type == "MethodCall" or not path or not Known.exists(path, "any") then
        -- An unknown function may yield on our behalf.
        summary.userCalls = true
      end
      if path then
        for _, prefix in ipairs(FRAME_NATIVE_PREFIXES) do
          if path:sub(1, #prefix) == prefix then summary.frameNatives = true end
        end
        if path == "TriggerClientEvent" and node.args[2] then
          local target = Ast.unparen(node.args[2])
          if target.type == "Unop" and target.op == "-" and Ast.unparen(target.operand).type == "Number" then
            summary.broadcast = summary.broadcast or node
          end
        end
      end
    end
  end)
  return summary
end

local function checkInfiniteLoop(ctx, node, cond)
  cond = Ast.unparen(cond)
  local infinite = cond.type == "True" or cond.type == "Number"
  if node.type == "Repeat" then infinite = cond.type == "False" or cond.type == "Nil" end
  if not infinite then return end

  local summary = inspectLoop(node.body)
  if not summary.yields and not summary.exits then
    ctx.report("FX500", node, "this infinite loop never calls Wait: it freezes the " .. (ctx.side == "server" and "whole server" or "game"), {
      hint = "add Wait(...) inside the loop",
      -- A called function may wait; without one the freeze is certain.
      confidence = summary.userCalls and "medium" or "high",
    })
    return
  end

  if #summary.waits >= 1 then
    local fastest = math.huge
    local allConstant = true
    for _, value in ipairs(summary.waits) do
      if value == false then allConstant = false else fastest = math.min(fastest, value) end
    end
    if allConstant and fastest == 0 and #summary.waits == 1 and ctx.side ~= "server" then
      ctx.report("FX501", node, "this loop runs every frame, forever", {
        hint = summary.frameNatives
          and "drawing and key checks need Wait(0), but only while they are useful: sleep longer otherwise"
          or "use a longer Wait, or a zone, event or state bag instead of polling",
      })
    end
    if summary.broadcast and allConstant and fastest < 1000 then
      ctx.report("FX506", summary.broadcast, "this event goes to every player every " .. fastest .. " ms", {
        hint = "target the players concerned, batch the updates, or use a state bag",
      })
    end
  end
end

local function checkConcat(ctx, loopBody)
  Ast.walk({ type = "Do", body = loopBody }, function(node)
    if node.type == "Function" then return false end
    if node.type == "Assign" and #node.targets == 1 and node.targets[1].type == "Name" then
      local target, value = node.targets[1], node.values[1]
      if node.compound == ".." then
        ctx.report("FX505", node, "'" .. target.name .. "' is rebuilt at each iteration", { hint = "collect the parts, then table.concat them" })
      elseif value and value.type == "Binop" and value.op == ".." then
        local left = value
        while left.type == "Binop" and left.op == ".." do left = left.left end
        if left.type == "Name" and left.name == target.name then
          ctx.report("FX505", node, "'" .. target.name .. "' is rebuilt at each iteration", { hint = "collect the parts, then table.concat them" })
        end
      end
    end
  end)
end

local function checkQueries(ctx, loopBody)
  Ast.walk({ type = "Do", body = loopBody }, function(node)
    if node.type == "Function" then return false end
    if (node.type == "Call" or node.type == "MethodCall") and isSqlCall(node) then
      ctx.report("FX507", node, "a SQL query runs at each iteration of this loop", {
        hint = "fetch everything in a single query, using IN (...) or a batch",
      })
    end
  end)
end

function Performance.checkFile(ctx)
  Ast.walk(ctx.chunk, function(node)
    local kind = node.type
    if kind == "While" or kind == "Repeat" then
      checkInfiniteLoop(ctx, node, node.cond)
    end
    if kind == "While" or kind == "Repeat" or kind == "NumFor" or kind == "GenFor" then
      -- Nested loops are visited on their own: only look at this level's direct statements.
      local direct = {}
      for _, statement in ipairs(node.body) do
        if statement.type ~= "While" and statement.type ~= "Repeat"
          and statement.type ~= "NumFor" and statement.type ~= "GenFor" then
          direct[#direct + 1] = statement
        end
      end
      checkConcat(ctx, direct)
      checkQueries(ctx, direct)
    end
    if kind == "Call" then
      local path = Ast.path(node.func)
      if path == "GetPlayerPed" and ctx.side ~= "server" and node.args[1] then
        local arg = Ast.unparen(node.args[1])
        if arg.type == "Unop" and arg.op == "-" and arg.operand.type == "Number" and arg.operand.value == 1 then
          ctx.report("FX502", node, "GetPlayerPed(-1) can be replaced by PlayerPedId()")
        end
      elseif path == "GetHashKey" and node.args[1] and Ast.unparen(node.args[1]).type == "String" then
        local value = Ast.unparen(node.args[1]).value
        ctx.report("FX503", node, "this hash can be computed at compile time", { hint = "write `" .. value .. "`" })
      elseif path == "GetDistanceBetweenCoords" or path == "Vdist" or path == "Vdist2" then
        ctx.report("FX504", node, path .. " is slower than the vector syntax", { hint = "write #(a - b) with vectors" })
      end
    end
  end)
end

return Performance
