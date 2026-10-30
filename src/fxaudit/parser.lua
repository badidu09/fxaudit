--- Recursive-descent parser producing an AST with source positions.
-- Recovers after each syntax error by resynchronizing on the next statement,
-- so that one file reports all of its errors instead of only the first one.
--
-- Every node has `type`, `line` and `col`. Statements: Local, Assign, CallStat,
-- Do, While, Repeat, If, NumFor, GenFor, FunctionStat, LocalFunction, Return,
-- Break, Goto, Label, Defer. Expressions: Nil, True, False, Number, String, Hash,
-- Vararg, Function, Name, Index, Call, MethodCall, Binop, Unop, Table, Paren.

local Lexer = require("fxaudit.lexer")

local Parser = {}

local MAX_ERRORS = 100

local BINARY_PRIORITY = {
  ["or"] = { 1, 1 }, ["and"] = { 2, 2 },
  ["<"] = { 3, 3 }, [">"] = { 3, 3 }, ["<="] = { 3, 3 }, [">="] = { 3, 3 },
  ["~="] = { 3, 3 }, ["!="] = { 3, 3 }, ["=="] = { 3, 3 },
  ["|"] = { 4, 4 }, ["~"] = { 5, 5 }, ["&"] = { 6, 6 },
  ["<<"] = { 7, 7 }, [">>"] = { 7, 7 },
  [".."] = { 9, 8 },
  ["+"] = { 10, 10 }, ["-"] = { 10, 10 },
  ["*"] = { 11, 11 }, ["/"] = { 11, 11 }, ["//"] = { 11, 11 }, ["%"] = { 11, 11 },
  ["^"] = { 14, 13 },
}
local UNARY_PRIORITY = 12

local COMPOUND = {
  ["+="] = "+", ["-="] = "-", ["*="] = "*", ["/="] = "/", ["//="] = "//", ["%="] = "%",
  ["^="] = "^", ["&="] = "&", ["|="] = "|", ["<<="] = "<<", [">>="] = ">>", ["..="] = "..",
}

local BLOCK_END = { ["end"] = true, ["else"] = true, ["elseif"] = true, ["until"] = true }

local STATEMENT_START = {
  ["if"] = true, ["while"] = true, ["for"] = true, ["function"] = true, ["local"] = true,
  ["return"] = true, ["do"] = true, ["repeat"] = true, ["break"] = true, ["goto"] = true,
}

-- Raised (and caught by the statement loop) to unwind to a resynchronization point.
local SYNC = {}

--- Parses `source`.
-- @return table chunk `{ type = "Chunk", body, comments, errors, source }`;
--   each error is `{ message, line, col, kind }`
function Parser.parse(source)
  if source:sub(1, 3) == "\239\187\191" then source = "   " .. source:sub(4) end
  -- A shebang line is valid at the very start of a chunk.
  if source:sub(1, 1) == "#" then source = "--" .. source:sub(3) end

  local tokens, comments, lexErrors = Lexer.tokenize(source)
  local errors = {}
  for _, e in ipairs(lexErrors) do
    errors[#errors + 1] = { message = e.message, line = e.line, col = e.col, kind = "syntax" }
  end

  local index = 1
  local token = tokens[1]
  local functionState = { vararg = true, loops = 0 }

  local function advance()
    local previous = token
    if index < #tokens then index = index + 1 end
    token = tokens[index]
    return previous
  end

  local function peek(offset)
    return tokens[math.min(index + (offset or 1), #tokens)]
  end

  local function check(kind, value)
    return token.type == kind and (value == nil or token.value == value)
  end

  local function isOp(value) return token.type == "op" and token.value == value end
  local function isKeyword(value) return token.type == "keyword" and token.value == value end

  local function describe(tok)
    if tok.type == "eof" then return "end of file" end
    if tok.type == "string" then return "a string" end
    if tok.type == "number" then return "'" .. tostring(tok.raw) .. "'" end
    return "'" .. tostring(tok.value) .. "'"
  end

  local function report(message, tok, kind)
    tok = tok or token
    errors[#errors + 1] = { message = message, line = tok.line, col = tok.col, kind = kind or "syntax" }
  end

  local function fail(message, tok)
    report(message, tok)
    error(SYNC, 0)
  end

  local function acceptOp(value)
    if isOp(value) then advance(); return true end
    return false
  end

  local function acceptKeyword(value)
    if isKeyword(value) then advance(); return true end
    return false
  end

  local function expectOp(value, context)
    if isOp(value) then return advance() end
    fail("expected '" .. value .. "'" .. (context and (" " .. context) or "") .. " but found " .. describe(token))
  end

  --- Expects the keyword closing a construct opened at `opener`.
  local function expectClose(value, what, opener)
    if isKeyword(value) then return advance() end
    local where = (opener and opener.line ~= token.line)
      and (" to close the '" .. what .. "' opened at line " .. opener.line) or ""
    fail("expected '" .. value .. "'" .. where .. " but found " .. describe(token))
  end

  local function node(kind, at, fields)
    fields = fields or {}
    fields.type, fields.line, fields.col = kind, at.line, at.col
    fields.pos = at.pos
    return fields
  end

  local function expectName(context)
    if token.type == "name" then return advance() end
    if token.type == "keyword" then
      fail("'" .. token.value .. "' is a reserved word and cannot be used as " .. context)
    end
    fail("expected " .. context .. " but found " .. describe(token))
  end

  local parseExpr, parseBlock, parseFunctionBody, parseStatement

  local function parseExprList()
    local list = { parseExpr() }
    while acceptOp(",") do list[#list + 1] = parseExpr() end
    return list
  end

  local function parseTable()
    local open = advance()
    local fields = {}
    local result = node("Table", open, { fields = fields })
    while not isOp("}") do
      if token.type == "eof" then
        fail("expected '}' to close the table opened at line " .. open.line .. " but found end of file")
      end
      local fieldToken = token
      if token.type == "name" and peek().type == "op" and peek().value == "=" then
        local key = advance()
        advance()
        fields[#fields + 1] = {
          kind = "named", name = key.value, line = key.line, col = key.col,
          key = node("String", key, { value = key.value }), value = parseExpr(),
        }
      elseif isOp("[") then
        advance()
        local key = parseExpr()
        expectOp("]", "to close the table key")
        expectOp("=", "after the table key")
        fields[#fields + 1] = {
          kind = "keyed", key = key, line = fieldToken.line, col = fieldToken.col, value = parseExpr(),
        }
      elseif isOp(".") and peek().type == "name" then
        -- CfxLua set constructor: { .a, .b } is { a = true, b = true }.
        advance()
        local key = advance()
        fields[#fields + 1] = {
          kind = "named", name = key.value, line = key.line, col = key.col,
          key = node("String", key, { value = key.value }), value = node("True", key),
        }
      else
        fields[#fields + 1] = { kind = "positional", line = fieldToken.line, col = fieldToken.col, value = parseExpr() }
      end
      if not (acceptOp(",") or acceptOp(";")) then
        if not isOp("}") then
          if token.type == "name" or token.type == "string" or token.type == "number" then
            fail("missing ',' between table fields (before " .. describe(token) .. ")")
          end
          fail("expected '}' to close the table opened at line " .. open.line .. " but found " .. describe(token))
        end
      end
    end
    advance()
    return result
  end

  local function parseCallArgs()
    if isOp("(") then
      local open = advance()
      if acceptOp(")") then return {} end
      local args = parseExprList()
      if not isOp(")") then
        fail("expected ')' to close the call opened at line " .. open.line .. " but found " .. describe(token))
      end
      advance()
      return args
    elseif isOp("{") then
      return { parseTable() }
    elseif token.type == "string" then
      local tok = advance()
      return { node("String", tok, { value = tok.value }) }
    end
    fail("expected function arguments but found " .. describe(token))
  end

  local function parsePrimary()
    if token.type == "name" then
      local tok = advance()
      return node("Name", tok, { name = tok.value })
    elseif isOp("(") then
      local open = advance()
      local inner = parseExpr()
      if not isOp(")") then
        fail("expected ')' to close the parenthesis opened at line " .. open.line .. " but found " .. describe(token))
      end
      advance()
      return node("Paren", open, { expr = inner })
    end
    fail("expected an expression but found " .. describe(token))
  end

  local function parseSuffixed()
    local expr = parsePrimary()
    while true do
      if isOp(".") or isOp("?.") then
        local safe = token.value == "?."
        local dot = advance()
        local key = expectName("a field name")
        expr = node("Index", dot, {
          object = expr, safe = safe, dotted = true, name = key.value,
          key = node("String", key, { value = key.value }), line = key.line, col = key.col,
        })
        expr.line, expr.col = key.line, key.col
      elseif isOp("[") or isOp("?[") then
        local safe = token.value == "?["
        local open = advance()
        local key = parseExpr()
        expectOp("]", "to close the index")
        expr = node("Index", open, { object = expr, safe = safe, key = key })
      elseif isOp(":") or isOp("?:") then
        local safe = token.value == "?:"
        advance()
        local method = expectName("a method name")
        if not (isOp("(") or isOp("{") or token.type == "string") then
          fail("expected '(' after method '" .. method.value .. "' (a ':' access must be a call)")
        end
        expr = node("MethodCall", method, { object = expr, method = method.value, safe = safe, args = parseCallArgs() })
      elseif isOp("(") or isOp("{") or token.type == "string" then
        local at = token
        expr = node("Call", { line = expr.line, col = expr.col, pos = at.pos }, { func = expr, args = parseCallArgs() })
      else
        return expr
      end
    end
  end

  local function parseSimple()
    local tok = token
    if tok.type == "number" then
      advance()
      return node("Number", tok, { value = tok.value, raw = tok.raw })
    elseif tok.type == "string" then
      advance()
      return node("String", tok, { value = tok.value })
    elseif tok.type == "hash" then
      advance()
      return node("Hash", tok, { value = tok.value })
    elseif isKeyword("nil") then
      advance()
      return node("Nil", tok)
    elseif isKeyword("true") then
      advance()
      return node("True", tok)
    elseif isKeyword("false") then
      advance()
      return node("False", tok)
    elseif isOp("...") then
      advance()
      if not functionState.vararg then
        report("cannot use '...' outside a vararg function", tok, "vararg")
      end
      return node("Vararg", tok)
    elseif isOp("{") then
      return parseTable()
    elseif isKeyword("function") then
      advance()
      return parseFunctionBody(tok, false)
    end
    return parseSuffixed()
  end

  local function parseSubExpr(limit)
    local tok = token
    local left
    if isKeyword("not") or isOp("-") or isOp("#") or isOp("~") then
      advance()
      local operand = parseSubExpr(UNARY_PRIORITY)
      left = node("Unop", tok, { op = tok.value, operand = operand })
    else
      left = parseSimple()
    end
    while (token.type == "op" or token.type == "keyword") and BINARY_PRIORITY[token.value]
      and BINARY_PRIORITY[token.value][1] > limit do
      local opToken = advance()
      local priority = BINARY_PRIORITY[opToken.value]
      local right = parseSubExpr(priority[2])
      left = node("Binop", { line = left.line, col = left.col, pos = left.pos }, {
        op = opToken.value == "!=" and "~=" or opToken.value,
        left = left, right = right, opLine = opToken.line, opCol = opToken.col,
      })
    end
    return left
  end

  parseExpr = function() return parseSubExpr(0) end

  --- Parses `(params) body end`. `at` is the `function` token.
  parseFunctionBody = function(at, isMethod)
    local params, vararg = {}, false
    if not isOp("(") then
      fail("expected '(' to start the function parameters but found " .. describe(token))
    end
    advance()
    if not isOp(")") then
      repeat
        if isOp("...") then
          advance()
          vararg = true
          break
        end
        local param = expectName("a parameter name")
        params[#params + 1] = { name = param.value, line = param.line, col = param.col }
      until not acceptOp(",")
    end
    expectOp(")", "to close the function parameters")

    local saved = functionState
    functionState = { vararg = vararg, loops = 0 }
    local ok, body = pcall(parseBlock)
    functionState = saved
    if not ok then error(body, 0) end
    local closing = expectClose("end", "function", at)
    return node("Function", at, {
      params = params, isVararg = vararg, isMethod = isMethod, body = body,
      endLine = closing.line,
    })
  end

  local function parseAttrib()
    if acceptOp("<") then
      local name = expectName("an attribute name")
      if name.value ~= "const" and name.value ~= "close" then
        report("unknown attribute '" .. name.value .. "' (expected 'const' or 'close')", name)
      end
      expectOp(">", "after the attribute")
      return name.value
    end
    return nil
  end

  local function parseIf()
    local at = advance()
    local clauses = {}

    local function clause(opener)
      local cond = parseExpr()
      if isOp("=") then
        fail("'=' assigns a value; use '==' to compare in a condition")
      end
      if not isKeyword("then") then
        fail("expected 'then' after the condition of the '" .. opener.value .. "' but found " .. describe(token))
      end
      advance()
      clauses[#clauses + 1] = { cond = cond, line = opener.line, col = opener.col, body = parseBlock() }
    end

    clause(at)
    local orelse
    while true do
      if isKeyword("elseif") then
        clause(advance())
      elseif isKeyword("else") then
        local elseToken = advance()
        if isKeyword("if") and token.line == elseToken.line then
          report("'else if' opens a new 'if' that needs its own 'end'; did you mean 'elseif'?", elseToken, "hint")
        end
        orelse = parseBlock()
        break
      else
        break
      end
    end
    expectClose("end", "if", at)
    return node("If", at, { clauses = clauses, orelse = orelse })
  end

  local function loopBody(at, what)
    functionState.loops = functionState.loops + 1
    local ok, body = pcall(parseBlock)
    functionState.loops = functionState.loops - 1
    if not ok then error(body, 0) end
    if what then expectClose("end", what, at) end
    return body
  end

  local function parseFor()
    local at = advance()
    local first = expectName("a loop variable name")
    if isOp("=") then
      advance()
      local start = parseExpr()
      expectOp(",", "after the initial value of the numeric 'for'")
      local stop = parseExpr()
      local step
      if acceptOp(",") then step = parseExpr() end
      if not isKeyword("do") then
        fail("expected 'do' in the numeric 'for' but found " .. describe(token))
      end
      advance()
      local body = loopBody(at, "for")
      return node("NumFor", at, {
        var = { name = first.value, line = first.line, col = first.col },
        start = start, stop = stop, step = step, body = body,
      })
    end
    local vars = { { name = first.value, line = first.line, col = first.col } }
    while acceptOp(",") do
      local name = expectName("a loop variable name")
      vars[#vars + 1] = { name = name.value, line = name.line, col = name.col }
    end
    if not isKeyword("in") then
      fail("expected '=' or 'in' in the 'for' but found " .. describe(token))
    end
    advance()
    local exprs = parseExprList()
    if not isKeyword("do") then
      fail("expected 'do' in the 'for' but found " .. describe(token))
    end
    advance()
    local body = loopBody(at, "for")
    return node("GenFor", at, { vars = vars, exprs = exprs, body = body })
  end

  local function parseFunctionStat()
    local at = advance()
    local nameToken = expectName("a function name")
    local target = node("Name", nameToken, { name = nameToken.value })
    local isMethod = false
    while isOp(".") or isOp(":") do
      local sep = advance()
      local key = expectName("a field name")
      target = node("Index", key, {
        object = target, dotted = true, name = key.value,
        key = node("String", key, { value = key.value }),
      })
      if sep.value == ":" then
        isMethod = true
        break
      end
    end
    local func = parseFunctionBody(at, isMethod)
    return node("FunctionStat", at, { target = target, func = func, isMethod = isMethod })
  end

  local function parseLocal()
    local at = advance()
    if isKeyword("function") then
      advance()
      local name = expectName("a function name")
      local result = node("LocalFunction", at, {
        name = { name = name.value, line = name.line, col = name.col },
      })
      result.func = parseFunctionBody(at, false)
      return result
    end
    local names = {}
    repeat
      local name = expectName("a variable name")
      names[#names + 1] = {
        name = name.value, line = name.line, col = name.col, attrib = parseAttrib(),
      }
    until not acceptOp(",")
    local values, unpackFrom = {}, nil
    if acceptOp("=") then
      values = parseExprList()
    elseif isKeyword("in") then
      -- CfxLua: `local a, b in t` is `local a, b = t.a, t.b`.
      advance()
      unpackFrom = parseExpr()
    end
    return node("Local", at, { names = names, values = values, unpackFrom = unpackFrom })
  end

  local function checkAssignable(expr)
    if expr.type ~= "Name" and expr.type ~= "Index" then
      local tok = { line = expr.line, col = expr.col }
      if expr.type == "Call" or expr.type == "MethodCall" then
        fail("cannot assign to a function call", tok)
      end
      fail("cannot assign to this expression", tok)
    end
    if expr.safe then fail("cannot assign through a safe-navigation access", expr) end
  end

  local function parseExprStatement()
    local at = token
    local first = parseSuffixed()
    if isOp("=") or isOp(",") then
      local targets = { first }
      while acceptOp(",") do targets[#targets + 1] = parseSuffixed() end
      if not isOp("=") then
        fail("expected '=' in the assignment but found " .. describe(token))
      end
      advance()
      for _, target in ipairs(targets) do checkAssignable(target) end
      return node("Assign", at, { targets = targets, values = parseExprList() })
    end
    if token.type == "op" and COMPOUND[token.value] then
      checkAssignable(first)
      local op = advance()
      return node("Assign", at, {
        targets = { first }, values = { parseExpr() }, compound = COMPOUND[op.value],
      })
    end
    if first.type == "Call" or first.type == "MethodCall" then
      return node("CallStat", at, { expr = first })
    end
    if isOp("==") then
      fail("'==' compares values and has no effect as a statement; did you mean '='?")
    end
    fail("this expression does nothing: expected a call or an assignment", at)
  end

  parseStatement = function()
    local at = token
    if at.type == "keyword" then
      local word = at.value
      if word == "if" then return parseIf() end
      if word == "while" then
        advance()
        local cond = parseExpr()
        if isOp("=") then fail("'=' assigns a value; use '==' to compare in a condition") end
        if not isKeyword("do") then
          fail("expected 'do' after the 'while' condition but found " .. describe(token))
        end
        advance()
        return node("While", at, { cond = cond, body = loopBody(at, "while") })
      end
      if word == "for" then return parseFor() end
      if word == "function" then return parseFunctionStat() end
      if word == "local" then return parseLocal() end
      if word == "do" then
        advance()
        local body = parseBlock()
        expectClose("end", "do", at)
        return node("Do", at, { body = body })
      end
      if word == "repeat" then
        advance()
        local body = loopBody(at)
        expectClose("until", "repeat", at)
        return node("Repeat", at, { body = body, cond = parseExpr() })
      end
      if word == "break" then
        advance()
        if functionState.loops == 0 then
          report("'break' is only valid inside a loop", at, "break")
        end
        return node("Break", at)
      end
      if word == "goto" then
        advance()
        local label = expectName("a label name")
        return node("Goto", at, { label = label.value })
      end
      fail("unexpected " .. describe(at) .. " at the start of a statement")
    end
    if isOp("::") then
      advance()
      local name = expectName("a label name")
      expectOp("::", "to close the label")
      return node("Label", at, { label = name.value })
    end
    -- `defer` is contextual: it remains usable as a plain identifier.
    if at.type == "name" and at.value == "defer" then
      local nextToken = peek()
      local isIdentifierUse = nextToken.type == "op" and (nextToken.value == "=" or nextToken.value == "."
        or nextToken.value == "(" or nextToken.value == "," or nextToken.value == "["
        or nextToken.value == ":" or nextToken.value == "{" or COMPOUND[nextToken.value])
      if not isIdentifierUse and nextToken.type ~= "string" then
        advance()
        local body = parseBlock()
        expectClose("end", "defer", at)
        return node("Defer", at, { body = body })
      end
    end
    return parseExprStatement()
  end

  --- Skips tokens until something that plausibly starts a statement.
  local function synchronize(startIndex)
    if index == startIndex and token.type ~= "eof" then advance() end
    while token.type ~= "eof" do
      if token.type == "keyword" and (STATEMENT_START[token.value] or BLOCK_END[token.value]) then
        return
      end
      if isOp(";") then
        advance()
        return
      end
      if token.line > tokens[math.max(index - 1, 1)].line and token.type == "name" then
        return
      end
      advance()
    end
  end

  parseBlock = function()
    local body = {}
    while token.type ~= "eof" and #errors < MAX_ERRORS do
      if token.type == "keyword" and BLOCK_END[token.value] then break end
      if isOp(";") then
        advance()
      elseif isKeyword("return") then
        local at = advance()
        local values = {}
        if not (token.type == "eof" or isOp(";")
          or (token.type == "keyword" and BLOCK_END[token.value])) then
          local startIndex = index
          local ok, err = pcall(function() values = parseExprList() end)
          if not ok then
            if err ~= SYNC then error(err, 0) end
            synchronize(startIndex)
          end
        end
        acceptOp(";")
        body[#body + 1] = node("Return", at, { values = values })
        if not (token.type == "eof" or (token.type == "keyword" and BLOCK_END[token.value])) then
          report("'return' must be the last statement of a block; wrap it in 'do return end' to return early")
        end
      else
        local startIndex = index
        local ok, result = pcall(parseStatement)
        if ok then
          body[#body + 1] = result
        else
          if result ~= SYNC then error(result, 0) end
          synchronize(startIndex)
        end
      end
    end
    return body
  end

  local body = parseBlock()
  while token.type ~= "eof" and #errors < MAX_ERRORS do
    report("unexpected " .. describe(token) .. ": no block is open here (one 'end' too many?)")
    advance()
    local more = parseBlock()
    for _, statement in ipairs(more) do body[#body + 1] = statement end
  end
  if #errors >= MAX_ERRORS then
    errors[#errors + 1] = { message = "too many syntax errors, stopping here", line = token.line, col = token.col, kind = "syntax" }
  end

  table.sort(errors, function(a, b)
    if a.line ~= b.line then return a.line < b.line end
    return a.col < b.col
  end)

  return { type = "Chunk", body = body, comments = comments, errors = errors, source = source, line = 1, col = 1 }
end

return Parser
