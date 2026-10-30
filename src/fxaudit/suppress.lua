--- Inline suppressions:
--   -- fxaudit-ignore FX200 FX203     this line, or the next one if alone on its line
--   -- fxaudit-ignore                 every rule, same placement
--   -- fxaudit-ignore-file FX202      the whole file
local Suppress = {}

local function parseIds(text)
  local ids, count = {}, 0
  for id in text:gmatch("FX%d%d%d") do
    ids[id] = true
    count = count + 1
  end
  return count > 0 and ids or true
end

function Suppress.parse(comments)
  local state = { lines = {}, file = nil }
  for _, comment in ipairs(comments) do
    local fileRest = comment.text:match("fxaudit%-ignore%-file(.*)")
    if fileRest then
      local ids = parseIds(fileRest)
      if ids == true or state.file == true then
        state.file = true
      else
        state.file = state.file or {}
        for id in pairs(ids) do state.file[id] = true end
      end
    else
      local rest = comment.text:match("fxaudit%-ignore(.*)")
      if rest then
        local ids = parseIds(rest)
        -- A comment applies to its own line and to the following one.
        state.lines[comment.endLine] = ids
        state.lines[comment.endLine + 1] = ids
      end
    end
  end
  return state
end

function Suppress.isSuppressed(state, id, line)
  if state.file == true or (state.file and state.file[id]) then return true end
  local ids = state.lines[line]
  return ids == true or (ids and ids[id]) or false
end

return Suppress
