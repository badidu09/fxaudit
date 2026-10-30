--- Lexical scope resolution.
-- Binds every Name node to its local variable (`node.var`) or marks it global,
-- and records how each variable is read and written.
--
-- A variable is `{ name, kind, line, col, reads, writes, selfReads, attrib, hasInit,
-- func, shadows, readNodes, writeNodes, inLoop, funcValue }`, with `kind` one of
-- local, function, param, self, loop.

local Scope = {}

local function newScope(parent, isFunction, func)
  return { parent = parent, vars = {}, labels = {}, isFunction = isFunction, func = func }
end

--- Analyzes a parsed chunk.
-- @return table `{ vars, globals, problems, functions }`. `globals` lists references
--   `{ name, node, write, inFunction, func, isDefinition }`; `problems` lists scope errors
--   `{ kind, node, message }`.
function Scope.analyze(chunk)
  local vars, globals, problems, functions = {}, {}, {}, {}

  local rootFunc = { node = chunk, depth = 0, loopDepth = 0 }
  local scope = newScope(nil, true, rootFunc)
  local func = rootFunc

  local function push(isFunction, f) scope = newScope(scope, isFunction, f or scope.func) end
  local function pop() scope = scope.parent end

  local function lookup(name)
    local s = scope
    while s do
      local var = s.vars[name]
      if var then return var end
      s = s.parent
    end
    return nil
  end

  local function declare(info, kind, attrib, hasInit)
    local previous = lookup(info.name)
    local sameScope = previous and scope.vars[info.name] == previous
    local var = {
      name = info.name, kind = kind, line = info.line, col = info.col,
      attrib = attrib, hasInit = hasInit,
      reads = 0, writes = 0, selfReads = 0, readNodes = {}, writeNodes = {},
      func = func, inLoop = func.loopDepth > 0,
      shadows = (not sameScope) and previous or nil,
      redefines = sameScope and previous or nil,
    }
    scope.vars[info.name] = var
    vars[#vars + 1] = var
    return var
  end

  local function isInside(fn, target)
    while fn do
      if fn.node == target then return true end
      fn = fn.parent
    end
    return false
  end

  local function resolveRead(node)
    local var = lookup(node.name)
    node.var = var
    if var then
      if var.funcValue and isInside(func, var.funcValue) then
        var.selfReads = var.selfReads + 1
      else
        var.reads = var.reads + 1
      end
      var.readNodes[#var.readNodes + 1] = { node = node, func = func, loopDepth = func.loopDepth }
    else
      globals[#globals + 1] = {
        name = node.name, node = node, write = false, inFunction = func.depth > 0, func = func,
      }
    end
  end

  local function resolveWrite(node, options)
    local var = lookup(node.name)
    node.var = var
    if var then
      var.writes = var.writes + 1
      var.writeNodes[#var.writeNodes + 1] = { node = node, func = func, loopDepth = func.loopDepth }
      if var.attrib == "const" or var.attrib == "close" then
        problems[#problems + 1] = {
          kind = "const", node = node,
          message = "cannot assign to '" .. var.name .. "': it is declared <" .. var.attrib .. "> at line " .. var.line,
        }
      end
    else
      globals[#globals + 1] = {
        name = node.name, node = node, write = true, inFunction = func.depth > 0, func = func,
        isDefinition = options and options.isDefinition, compound = options and options.compound,
      }
    end
  end

  local visit, visitBlock, visitFunction

  --- Registers labels up front: a goto may jump forward within its block.
  local function collectLabels(body)
    for _, statement in ipairs(body) do
      if statement.type == "Label" then
        local s, duplicate = scope, nil
        while s do
          if s.labels[statement.label] then duplicate = s.labels[statement.label]; break end
          if s.isFunction then break end
          s = s.parent
        end
        if duplicate then
          problems[#problems + 1] = {
            kind = "label", node = statement,
            message = "label '" .. statement.label .. "' is already defined at line " .. duplicate.line,
          }
        else
          scope.labels[statement.label] = statement
        end
      end
    end
  end

  visitBlock = function(body)
    collectLabels(body)
    for _, statement in ipairs(body) do visit(statement) end
  end

  visitFunction = function(node, selfInfo)
    local outer = func
    func = { node = node, parent = outer, depth = outer.depth + 1, loopDepth = 0 }
    functions[#functions + 1] = func
    node.scopeFunc = func
    push(true, func)
    if selfInfo then
      local var = declare(selfInfo, "self", nil, true)
      var.writes = 0
    end
    node.paramVars = {}
    for _, param in ipairs(node.params) do
      node.paramVars[#node.paramVars + 1] = declare(param, "param", nil, true)
    end
    visitBlock(node.body)
    pop()
    func = outer
  end

  local function visitExpr(node)
    local kind = node.type
    if kind == "Name" then
      resolveRead(node)
    elseif kind == "Function" then
      visitFunction(node)
    elseif kind == "Index" then
      visitExpr(node.object)
      if not node.dotted then visitExpr(node.key) end
    elseif kind == "Call" then
      visitExpr(node.func)
      for _, arg in ipairs(node.args) do visitExpr(arg) end
    elseif kind == "MethodCall" then
      visitExpr(node.object)
      for _, arg in ipairs(node.args) do visitExpr(arg) end
    elseif kind == "Binop" then
      visitExpr(node.left)
      visitExpr(node.right)
    elseif kind == "Unop" then
      visitExpr(node.operand)
    elseif kind == "Paren" then
      visitExpr(node.expr)
    elseif kind == "Table" then
      for _, field in ipairs(node.fields) do
        if field.kind == "keyed" then visitExpr(field.key) end
        visitExpr(field.value)
      end
    end
  end

  local function inLoop(body)
    func.loopDepth = func.loopDepth + 1
    body()
    func.loopDepth = func.loopDepth - 1
  end

  visit = function(node)
    local kind = node.type
    if kind == "Local" then
      for _, value in ipairs(node.values) do visitExpr(value) end
      if node.unpackFrom then visitExpr(node.unpackFrom) end
      node.vars = {}
      for i, info in ipairs(node.names) do
        local hasInit = node.values[i] ~= nil
          or (#node.values > 0 and (node.values[#node.values].type == "Call"
            or node.values[#node.values].type == "MethodCall"
            or node.values[#node.values].type == "Vararg"))
          or node.unpackFrom ~= nil
        local var = declare(info, "local", info.attrib, hasInit)
        if node.values[i] and node.values[i].type == "Function" then
          var.funcValue = node.values[i]
          var.kind = "function"
        end
        node.vars[i] = var
      end
    elseif kind == "LocalFunction" then
      local var = declare(node.name, "function", nil, true)
      var.funcValue = node.func
      node.var = var
      visitFunction(node.func)
    elseif kind == "Assign" then
      for _, value in ipairs(node.values) do visitExpr(value) end
      for _, target in ipairs(node.targets) do
        if target.type == "Name" then
          resolveWrite(target, { compound = node.compound })
        else
          visitExpr(target)
        end
      end
    elseif kind == "CallStat" then
      visitExpr(node.expr)
    elseif kind == "Do" or kind == "Defer" then
      push(false)
      visitBlock(node.body)
      pop()
    elseif kind == "While" then
      inLoop(function()
        visitExpr(node.cond)
        push(false)
        visitBlock(node.body)
        pop()
      end)
    elseif kind == "Repeat" then
      -- The `until` condition can see the locals of the loop body.
      inLoop(function()
        push(false)
        visitBlock(node.body)
        visitExpr(node.cond)
        pop()
      end)
    elseif kind == "If" then
      for _, clause in ipairs(node.clauses) do
        visitExpr(clause.cond)
        push(false)
        visitBlock(clause.body)
        pop()
      end
      if node.orelse then
        push(false)
        visitBlock(node.orelse)
        pop()
      end
    elseif kind == "NumFor" then
      visitExpr(node.start)
      visitExpr(node.stop)
      if node.step then visitExpr(node.step) end
      inLoop(function()
        push(false)
        node.varInfo = declare(node.var, "loop", nil, true)
        visitBlock(node.body)
        pop()
      end)
    elseif kind == "GenFor" then
      for _, expr in ipairs(node.exprs) do visitExpr(expr) end
      inLoop(function()
        push(false)
        node.varInfos = {}
        for i, info in ipairs(node.vars) do
          node.varInfos[i] = declare(info, "loop", nil, true)
        end
        visitBlock(node.body)
        pop()
      end)
    elseif kind == "FunctionStat" then
      local target = node.target
      if target.type == "Name" then
        resolveWrite(target, { isDefinition = true })
        if target.var and not target.var.funcValue then target.var.funcValue = node.func end
      else
        visitExpr(target)
      end
      local selfInfo = node.isMethod and { name = "self", line = node.line, col = node.col } or nil
      visitFunction(node.func, selfInfo)
    elseif kind == "Return" then
      for _, value in ipairs(node.values) do visitExpr(value) end
    elseif kind == "Goto" then
      local s, found = scope, false
      while s do
        if s.labels[node.label] then found = true; break end
        if s.isFunction then break end
        s = s.parent
      end
      if not found then
        problems[#problems + 1] = {
          kind = "goto", node = node,
          message = "no visible label '" .. node.label .. "' for this goto",
        }
      end
    end
  end

  visitBlock(chunk.body)

  return { vars = vars, globals = globals, problems = problems, functions = functions, root = rootFunc }
end

return Scope
