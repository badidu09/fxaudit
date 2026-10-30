--- Tokenizer for Lua 5.4 and the CfxLua dialect used by FiveM.
-- Never raises: malformed input is reported in `errors` and scanning continues,
-- so that a single typo does not hide the rest of the file's diagnostics.

local Lexer = {}

local KEYWORDS = {}
for word in ([[and break do else elseif end false for function goto if in local
    nil not or repeat return then true until while]]):gmatch("%a+") do
  KEYWORDS[word] = true
end

-- Longest operators first: matching is greedy by length.
local OPERATORS = {
  [3] = { ["..."] = true, ["..="] = true, ["<<="] = true, [">>="] = true, ["//="] = true },
  [2] = {
    ["=="] = true, ["~="] = true, ["!="] = true, ["<="] = true, [">="] = true,
    ["<<"] = true, [">>"] = true, ["//"] = true, [".."] = true, ["::"] = true,
    ["+="] = true, ["-="] = true, ["*="] = true, ["/="] = true, ["%="] = true,
    ["^="] = true, ["&="] = true, ["|="] = true, ["?."] = true, ["?["] = true,
    ["?:"] = true,
  },
  [1] = {
    ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["%"] = true,
    ["^"] = true, ["#"] = true, ["&"] = true, ["~"] = true, ["|"] = true,
    ["<"] = true, [">"] = true, ["="] = true, ["("] = true, [")"] = true,
    ["{"] = true, ["}"] = true, ["["] = true, ["]"] = true, [";"] = true,
    [":"] = true, [","] = true, ["."] = true,
  },
}

local ESCAPES = {
  a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v",
  ["\\"] = "\\", ['"'] = '"', ["'"] = "'", ["\n"] = "\n",
}

--- Tokenizes `source`.
-- @param source string
-- @return table tokens each `{ type, value, line, col, endLine, pos, endPos }`;
--   types are name, keyword, op, number, string, hash and eof
-- @return table comments each `{ text, line, endLine }`
-- @return table errors each `{ message, line, col }`
function Lexer.tokenize(source)
  local tokens, comments, errors = {}, {}, {}
  local pos, line, lineStart = 1, 1, 1
  local len = #source

  local function fail(message, atLine, atCol)
    errors[#errors + 1] = { message = message, line = atLine or line, col = atCol or (pos - lineStart + 1) }
  end

  local function push(kind, value, startPos, startLine, startCol, extra)
    local token = extra or {}
    token.type, token.value = kind, value
    token.pos, token.endPos = startPos, pos - 1
    token.line, token.col, token.endLine = startLine, startCol, line
    tokens[#tokens + 1] = token
  end

  --- Advances over a newline at `pos`, treating CRLF and LFCR as one break.
  local function newline()
    local c, nextC = source:sub(pos, pos), source:sub(pos + 1, pos + 1)
    pos = pos + (((nextC == "\n" or nextC == "\r") and nextC ~= c) and 2 or 1)
    line = line + 1
    lineStart = pos
  end

  --- Reads a long bracket at `pos`, if there is one. Returns its body or nil.
  local function readLongBracket(what)
    local equals = source:match("^%[(=*)%[", pos)
    if not equals then return nil end
    local startLine, startCol = line, pos - lineStart + 1
    pos = pos + #equals + 2
    if source:sub(pos, pos) == "\r" or source:sub(pos, pos) == "\n" then newline() end
    local closer = "]" .. equals .. "]"
    local bodyStart = pos
    while pos <= len do
      local c = source:sub(pos, pos)
      if c == "]" and source:sub(pos, pos + #closer - 1) == closer then
        local body = source:sub(bodyStart, pos - 1)
        pos = pos + #closer
        return body
      elseif c == "\n" or c == "\r" then
        newline()
      else
        pos = pos + 1
      end
    end
    fail("unfinished long " .. what .. " (it starts here and is never closed)", startLine, startCol)
    return source:sub(bodyStart)
  end

  local function readQuoted(quote)
    local startLine, startCol = line, pos - lineStart + 1
    local parts = {}
    pos = pos + 1
    while true do
      local c = source:sub(pos, pos)
      if c == "" or c == "\n" or c == "\r" then
        fail("unfinished string (missing closing " .. quote .. ")", startLine, startCol)
        break
      elseif c == quote then
        pos = pos + 1
        break
      elseif c == "\\" then
        local e = source:sub(pos + 1, pos + 1)
        if e == "\r" or e == "\n" then
          pos = pos + 1
          newline()
          parts[#parts + 1] = "\n"
        elseif ESCAPES[e] then
          parts[#parts + 1] = ESCAPES[e]
          pos = pos + 2
        elseif e == "x" then
          local hex = source:match("^%x%x", pos + 2)
          if hex then
            parts[#parts + 1] = string.char(tonumber(hex, 16))
            pos = pos + 4
          else
            fail("invalid \\x escape: two hexadecimal digits are required")
            pos = pos + 2
          end
        elseif e == "z" then
          pos = pos + 2
          while true do
            local w = source:sub(pos, pos)
            if w == "\n" or w == "\r" then newline()
            elseif w == " " or w == "\t" or w == "\f" or w == "\v" then pos = pos + 1
            else break end
          end
        elseif e:match("%d") then
          local digits = source:match("^%d%d?%d?", pos + 1)
          local code = tonumber(digits)
          if code > 255 then
            fail("invalid decimal escape: \\" .. digits .. " is greater than 255")
          else
            parts[#parts + 1] = string.char(code)
          end
          pos = pos + 1 + #digits
        elseif e == "u" then
          local hex = source:match("^{(%x+)}", pos + 2)
          local code = hex and tonumber(hex, 16)
          if code and code <= 0x7FFFFFFF then
            parts[#parts + 1] = utf8.char(code)
            pos = pos + 4 + #hex
          else
            fail("invalid \\u escape: expected \\u{XXX}")
            pos = pos + 2
          end
        else
          fail("invalid escape sequence '\\" .. e .. "'")
          pos = pos + 2
        end
      else
        parts[#parts + 1] = c
        pos = pos + 1
      end
    end
    return table.concat(parts)
  end

  local function readNumber()
    local start = pos
    local hex = source:match("^0[xX]", pos)
    local pattern = hex and "^[%x%.]" or "^[%d%.]"
    if hex then pos = pos + 2 end
    while true do
      local c = source:sub(pos, pos)
      local exponent = hex and c:match("[pP]") or (not hex and c:match("[eE]"))
      if exponent then
        pos = pos + 1
        if source:sub(pos, pos):match("[+-]") then pos = pos + 1 end
      elseif c:match(pattern) then
        pos = pos + 1
      else
        break
      end
    end
    -- Anything glued to the literal, like `3x`, is a malformed number.
    local trailing = source:match("^[%w_]+", pos)
    if trailing then pos = pos + #trailing end
    local raw = source:sub(start, pos - 1)
    local value = tonumber(raw)
    if not value then fail("malformed number '" .. raw .. "'", line, start - lineStart + 1) end
    return value, raw
  end

  while true do
    local c = source:sub(pos, pos)
    while c == " " or c == "\t" or c == "\n" or c == "\r" or c == "\f" or c == "\v" do
      if c == "\n" or c == "\r" then newline() else pos = pos + 1 end
      c = source:sub(pos, pos)
    end

    local startPos, startLine, startCol = pos, line, pos - lineStart + 1

    if pos > len then
      push("eof", "<eof>", startPos, startLine, startCol)
      break
    end

    local two = source:sub(pos, pos + 1)

    if two == "--" then
      pos = pos + 2
      local text = readLongBracket("comment")
      if not text then
        local stop = source:find("[\r\n]", pos) or (len + 1)
        text = source:sub(pos, stop - 1)
        pos = stop
      end
      comments[#comments + 1] = { text = text, line = startLine, endLine = line }
    elseif two == "/*" then
      local stop = source:find("*/", pos + 2, true)
      if not stop then fail("unfinished comment /* ... */", startLine, startCol) end
      local bodyEnd = stop and stop - 1 or len
      local text = source:sub(pos + 2, bodyEnd)
      pos = pos + 2
      while pos <= bodyEnd do
        local b = source:sub(pos, pos)
        if b == "\n" or b == "\r" then newline() else pos = pos + 1 end
      end
      pos = stop and stop + 2 or len + 1
      comments[#comments + 1] = { text = text, line = startLine, endLine = line }
    elseif c:byte() >= 0x80 then
      -- A high byte outside a string is almost always pasted from a web page.
      local stop = pos
      while stop <= len and source:byte(stop) >= 0x80 do stop = stop + 1 end
      fail("unexpected non-ASCII character '" .. source:sub(pos, stop - 1)
        .. "' (often a smart quote or non-breaking space pasted from the web)")
      pos = stop
    elseif c:match("[%a_]") then
      local word = source:match("^[%w_]+", pos)
      pos = pos + #word
      push(KEYWORDS[word] and "keyword" or "name", word, startPos, startLine, startCol)
    elseif c:match("%d") or (c == "." and source:sub(pos + 1, pos + 1):match("%d")) then
      local value, raw = readNumber()
      push("number", value, startPos, startLine, startCol, { raw = raw })
    elseif c == '"' or c == "'" then
      local value = readQuoted(c)
      push("string", value, startPos, startLine, startCol, { quote = c })
    elseif c == "`" then
      local stop = source:find("`", pos + 1, true)
      local lineEnd = source:find("[\r\n]", pos + 1) or (len + 1)
      if stop and stop < lineEnd then
        local value = source:sub(pos + 1, stop - 1)
        pos = stop + 1
        push("hash", value, startPos, startLine, startCol)
      else
        fail("unfinished compile-time hash (missing closing backtick)")
        pos = lineEnd
      end
    elseif c == "[" and source:match("^%[=*%[", pos) then
      local value = readLongBracket("string")
      push("string", value, startPos, startLine, startCol, { long = true })
    else
      local matched
      for size = 3, 1, -1 do
        local candidate = source:sub(pos, pos + size - 1)
        if OPERATORS[size][candidate] then
          matched = candidate
          break
        end
      end
      if matched then
        pos = pos + #matched
        push("op", matched, startPos, startLine, startCol)
      else
        fail("unexpected character '" .. c .. "'")
        pos = pos + 1
      end
    end
  end

  return tokens, comments, errors
end

return Lexer
