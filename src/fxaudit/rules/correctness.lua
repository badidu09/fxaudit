--- FX3xx: bugs that are syntactically valid.
local Ast = require("fxaudit.ast")

local Correctness = {}

local COMPARISON = { ["=="] = true, ["~="] = true, ["<"] = true, ["<="] = true, [">"] = true, [">="] = true }
local MULTI_VALUE = { Call = true, MethodCall = true, Vararg = true }

local function hasCall(node)
  local found = false
  Ast.walk(node, function(n)
    if n.type == "Call" or n.type == "MethodCall" then found = true end
    return not found
  end)
  return found
end

--- Whether a comment sits on `line` or the next one, marking an empty block as deliberate.
local function commentNear(ctx, line)
  for _, comment in ipairs(ctx.chunk.comments) do
    if comment.line == line or comment.line == line + 1 then return true end
  end
  return false
end

--- Whether a block always ends the normal flow.
local function endsFlow(statement)
  local kind = statement.type
  if kind == "Return" or kind == "Break" or kind == "Goto" then return true end
  if kind == "CallStat" and statement.expr.type == "Call" and statement.expr.func.type == "Name"
    and statement.expr.func.name == "error" and not statement.expr.func.var then
    return true
  end
  if kind == "While" and Ast.unparen(statement.cond).type == "True" then
    local escapes = false
    local function scan(node, nestedLoop)
      Ast.children(node, function(child)
        if escapes or child.type == "Function" then return end
        if child.type == "Goto" or (child.type == "Break" and not nestedLoop) then
          escapes = true
          return
        end
        local loop = child.type == "While" or child.type == "Repeat"
          or child.type == "NumFor" or child.type == "GenFor"
        scan(child, nestedLoop or loop)
      end)
    end
    scan(statement, false)
    return not escapes
  end
  return false
end

local function checkBlock(ctx, body)
  for i = 1, #body - 1 do
    if endsFlow(body[i]) then
      local nextStatement = body[i + 1]
      -- A label is a jump target, so what follows may still run.
      if nextStatement.type ~= "Label" then
        ctx.report("FX302", nextStatement, "this code can never run: the previous statement at line " .. body[i].line .. " always exits")
      end
      break
    end
  end
end

local function blocksOf(node)
  local kind = node.type
  if kind == "If" then
    local blocks = {}
    for _, clause in ipairs(node.clauses) do blocks[#blocks + 1] = clause.body end
    if node.orelse then blocks[#blocks + 1] = node.orelse end
    return blocks
  end
  if node.body then return { node.body } end
  return {}
end

local function checkEmpty(ctx, node)
  if node.type == "If" then
    for _, clause in ipairs(node.clauses) do
      if #clause.body == 0 and not commentNear(ctx, clause.line) then
        ctx.report("FX303", clause, "this branch is empty")
      end
    end
  elseif (node.type == "While" or node.type == "NumFor" or node.type == "GenFor")
    and #node.body == 0 and not commentNear(ctx, node.line) then
    ctx.report("FX303", node, "this loop has an empty body")
  end
end

local function checkAssignmentCount(ctx, node, targetCount, values)
  if #values == 0 or node.unpackFrom then return end
  local last = values[#values]
  if #values > targetCount then
    ctx.report("FX304", values[targetCount + 1], #values .. " values assigned to " .. targetCount .. " variable(s): the extra values are discarded")
  elseif #values < targetCount and not MULTI_VALUE[last.type] then
    ctx.report("FX304", node, #values .. " value(s) assigned to " .. targetCount .. " variables: the others become nil")
  end
end

local function constantTruth(expr)
  expr = Ast.unparen(expr)
  if expr.type == "Nil" or expr.type == "False" then return false end
  if expr.type == "True" or expr.type == "Number" or expr.type == "String"
    or expr.type == "Table" or expr.type == "Function" or expr.type == "Hash" then
    return true
  end
  return nil
end

local function checkConditions(ctx, node)
  if node.type == "If" then
    local seen = {}
    for _, clause in ipairs(node.clauses) do
      local truth = constantTruth(clause.cond)
      if truth ~= nil then
        ctx.report("FX305", clause.cond, "this condition is always " .. tostring(truth))
      end
      if not hasCall(clause.cond) then
        for _, previous in ipairs(seen) do
          if Ast.sameExpr(previous.cond, clause.cond) then
            ctx.report("FX307", clause.cond, "same condition as line " .. previous.line .. ": this branch can never run")
            break
          end
        end
      end
      seen[#seen + 1] = clause
    end
  elseif node.type == "While" then
    local truth = constantTruth(node.cond)
    if truth == false then
      ctx.report("FX305", node.cond, "this loop never runs: its condition is always false")
    end
  end
end

--- Flags `x == a or "b"` in a condition: the literal makes the whole test truthy.
local function checkOrLiteral(ctx, cond)
  Ast.walk(cond, function(node)
    if node.type == "Function" then return false end
    if node.type == "Binop" and node.op == "or" then
      local left, right = Ast.unparen(node.left), Ast.unparen(node.right)
      if (right.type == "String" or right.type == "Number") and left.type == "Binop"
        and (left.op == "==" or (left.op == "or" and Ast.unparen(left.right).type == "Binop")) then
        ctx.report("FX313", right, "this literal is always truthy, so the whole condition is true", {
          hint = "repeat the comparison: x == a or x == b",
        })
      end
    end
  end)
end

local function checkLiteralOperation(ctx, node)
  if node.type == "Binop" then
    local function bad(side)
      side = Ast.unparen(side)
      return side.type == "Nil" or side.type == "True" or side.type == "False"
    end
    if node.op == ".." and (bad(node.left) or bad(node.right)) then
      ctx.report("FX310", node, "concatenating nil or a boolean raises an error")
    elseif (node.op == "+" or node.op == "-" or node.op == "*" or node.op == "/" or node.op == "%"
      or node.op == "^" or node.op == "//") and (bad(node.left) or bad(node.right)) then
      ctx.report("FX310", node, "arithmetic on nil or a boolean raises an error")
    end
  elseif node.type == "Unop" and node.op == "#" then
    local operand = Ast.unparen(node.operand)
    if operand.type == "Number" or operand.type == "Nil" or operand.type == "True" or operand.type == "False" then
      ctx.report("FX310", node, "'#' on this value raises an error")
    end
  end
end

local function checkFormat(ctx, node)
  if node.type ~= "Call" or Ast.path(node.func) ~= "string.format" then return end
  local format = node.args[1]
  if not format or format.type ~= "String" then return end
  local last = node.args[#node.args]
  if MULTI_VALUE[last.type] and #node.args > 1 then return end
  local needed = 0
  for spec in format.value:gmatch("%%[%-+ #0]*%d*%.?%d*(.)") do
    if spec ~= "%" then needed = needed + 1 end
  end
  if #node.args - 1 < needed then
    ctx.report("FX314", node, "the format string requires " .. needed .. " value(s) but receives " .. (#node.args - 1))
  end
end

local function checkLocalCall(ctx, node)
  if node.type ~= "Call" or node.func.type ~= "Name" then return end
  local var = node.func.var
  if not var or not var.funcValue or var.writes > 0 then return end
  local func = var.funcValue
  if func.isVararg or func.isMethod then return end
  local count = #node.args
  local last = node.args[count]
  if last and MULTI_VALUE[last.type] then count = count - 1 end
  if count > #func.params then
    ctx.report("FX306", node, "'" .. var.name .. "' declares " .. #func.params .. " parameter(s) at line " .. var.line .. " but receives " .. count .. " argument(s)")
  end
end

local function checkRemoveInLoop(ctx, loop)
  if Ast.unparen(loop.start).type ~= "Number" then return end
  local step = loop.step and Ast.unparen(loop.step)
  if step and not (step.type == "Number" and step.value > 0) then return end
  local name = loop.var.name
  Ast.walk({ type = "Do", body = loop.body }, function(node)
    if node.type == "Function" then return false end
    if node.type == "Call" and Ast.path(node.func) == "table.remove" and node.args[2]
      and node.args[2].type == "Name" and node.args[2].name == name then
      ctx.report("FX312", node, "removing index '" .. name .. "' while iterating forward skips the next element", {
        hint = "iterate backwards: for " .. name .. " = #t, 1, -1 do",
      })
    end
  end)
end

function Correctness.checkFile(ctx)
  Ast.walk(ctx.chunk, function(node)
    local kind = node.type
    for _, body in ipairs(blocksOf(node)) do checkBlock(ctx, body) end

    if kind == "Binop" then
      if COMPARISON[node.op] and not hasCall(node.left) and Ast.sameExpr(node.left, node.right)
        and not (node.op == "~=" and Ast.unparen(node.left).type == "Name") then
        ctx.report("FX300", node, "this expression is compared with itself")
      end
      if node.op == "==" or node.op == "~=" then
        local left = node.left
        if left.type == "Unop" and left.op == "not" then
          ctx.report("FX311", node, "this compares (not x) with a value, because 'not' applies first", {
            hint = "write 'a ~= b' or 'not (a == b)'",
          })
        end
      end
    elseif kind == "Table" then
      local seen = {}
      for _, field in ipairs(node.fields) do
        local key
        if field.kind == "named" then
          key = "s:" .. field.name
        elseif field.kind == "keyed" then
          local k = Ast.unparen(field.key)
          if k.type == "String" then key = "s:" .. k.value
          elseif k.type == "Number" then key = "n:" .. tostring(k.value) end
        end
        if key then
          if seen[key] then
            ctx.report("FX301", field, "key already set at line " .. seen[key] .. ": the first value is lost")
          else
            seen[key] = field.line
          end
        end
      end
    elseif kind == "Local" then
      checkAssignmentCount(ctx, node, #node.names, node.values)
    elseif kind == "Assign" then
      if not node.compound then
        checkAssignmentCount(ctx, node, #node.targets, node.values)
        for i, target in ipairs(node.targets) do
          local value = node.values[i]
          if value and not hasCall(target) and Ast.sameExpr(target, value) then
            ctx.report("FX308", target, "this variable is assigned to itself")
          end
        end
      end
    elseif kind == "NumFor" then
      if node.step then
        local step = Ast.unparen(node.step)
        if step.type == "Number" and step.value == 0 then
          ctx.report("FX309", step, "a 'for' step of 0 raises an error")
        end
      end
      checkRemoveInLoop(ctx, node)
    end

    checkEmpty(ctx, node)
    checkConditions(ctx, node)
    if kind == "If" then
      for _, clause in ipairs(node.clauses) do checkOrLiteral(ctx, clause.cond) end
    elseif kind == "While" then
      checkOrLiteral(ctx, node.cond)
    end
    checkLiteralOperation(ctx, node)
    checkFormat(ctx, node)
    checkLocalCall(ctx, node)
  end)
end

return Correctness
