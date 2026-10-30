--- Generic AST traversal helpers.
local Ast = {}

local function eachList(list, fn)
  if list then
    for _, item in ipairs(list) do fn(item) end
  end
end

--- Calls `fn` on each direct child node of `node`, in source order.
function Ast.children(node, fn)
  local kind = node.type
  if kind == "Chunk" or kind == "Do" or kind == "Defer" then
    eachList(node.body, fn)
  elseif kind == "Local" then
    eachList(node.values, fn)
    if node.unpackFrom then fn(node.unpackFrom) end
  elseif kind == "Assign" then
    eachList(node.targets, fn)
    eachList(node.values, fn)
  elseif kind == "CallStat" then
    fn(node.expr)
  elseif kind == "While" then
    fn(node.cond)
    eachList(node.body, fn)
  elseif kind == "Repeat" then
    eachList(node.body, fn)
    fn(node.cond)
  elseif kind == "If" then
    for _, clause in ipairs(node.clauses) do
      fn(clause.cond)
      eachList(clause.body, fn)
    end
    eachList(node.orelse, fn)
  elseif kind == "NumFor" then
    fn(node.start)
    fn(node.stop)
    if node.step then fn(node.step) end
    eachList(node.body, fn)
  elseif kind == "GenFor" then
    eachList(node.exprs, fn)
    eachList(node.body, fn)
  elseif kind == "FunctionStat" then
    fn(node.target)
    fn(node.func)
  elseif kind == "LocalFunction" then
    fn(node.func)
  elseif kind == "Return" then
    eachList(node.values, fn)
  elseif kind == "Function" then
    eachList(node.body, fn)
  elseif kind == "Index" then
    fn(node.object)
    if not node.dotted then fn(node.key) end
  elseif kind == "Call" then
    fn(node.func)
    eachList(node.args, fn)
  elseif kind == "MethodCall" then
    fn(node.object)
    eachList(node.args, fn)
  elseif kind == "Binop" then
    fn(node.left)
    fn(node.right)
  elseif kind == "Unop" then
    fn(node.operand)
  elseif kind == "Paren" then
    fn(node.expr)
  elseif kind == "Table" then
    for _, field in ipairs(node.fields) do
      if field.kind == "keyed" then fn(field.key) end
      fn(field.value)
    end
  end
end

--- Depth-first walk. `enter` may return false to skip a node's children.
function Ast.walk(node, enter, leave)
  if enter(node) ~= false then
    Ast.children(node, function(child) Ast.walk(child, enter, leave) end)
  end
  if leave then leave(node) end
end

--- Strips parentheses: `((x))` gives `x`.
function Ast.unparen(node)
  while node and node.type == "Paren" do node = node.expr end
  return node
end

--- Returns the dotted path of an expression (`a.b.c`), or nil if it has a dynamic part.
function Ast.path(node)
  node = Ast.unparen(node)
  if not node then return nil end
  if node.type == "Name" then return node.name end
  if node.type == "Index" then
    local base = Ast.path(node.object)
    if not base then return nil end
    if node.dotted then return base .. "." .. node.name end
    if node.key.type == "String" then return base .. "." .. node.key.value end
  end
  return nil
end

--- Returns the name a call targets: `Foo`, `a.b.Foo`; `obj:Foo` gives `obj:Foo`
-- when the object is a plain path and `?:Foo` otherwise.
function Ast.callName(node)
  if node.type == "Call" then
    return Ast.path(node.func)
  elseif node.type == "MethodCall" then
    return (Ast.path(node.object) or "?") .. ":" .. node.method
  end
  return nil
end

--- Last segment of a call name: `a.b.Foo` and `a:Foo` both give `Foo`.
function Ast.shortCallName(node)
  if node.type == "MethodCall" then return node.method end
  if node.type == "Call" then
    local f = Ast.unparen(node.func)
    if f.type == "Name" then return f.name end
    if f.type == "Index" and f.dotted then return f.name end
    if f.type == "Index" and f.key.type == "String" then return f.key.value end
  end
  return nil
end

--- True for the literal constants of the language.
function Ast.isConstant(node)
  node = Ast.unparen(node)
  local kind = node.type
  return kind == "Nil" or kind == "True" or kind == "False" or kind == "Number"
    or kind == "String" or kind == "Hash" or kind == "Table" or kind == "Function"
end

--- Structural equality of two side-effect-free expressions.
function Ast.sameExpr(a, b)
  a, b = Ast.unparen(a), Ast.unparen(b)
  if a.type ~= b.type then return false end
  local kind = a.type
  if kind == "Name" then return a.name == b.name end
  if kind == "Number" or kind == "String" or kind == "Hash" then return a.value == b.value end
  if kind == "Nil" or kind == "True" or kind == "False" then return true end
  if kind == "Index" then
    return Ast.sameExpr(a.object, b.object) and Ast.sameExpr(a.key, b.key)
  end
  if kind == "Binop" then
    return a.op == b.op and Ast.sameExpr(a.left, b.left) and Ast.sameExpr(a.right, b.right)
  end
  if kind == "Unop" then
    return a.op == b.op and Ast.sameExpr(a.operand, b.operand)
  end
  return false
end

return Ast
