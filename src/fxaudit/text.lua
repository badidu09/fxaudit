--- Text helpers.
local Text = {}

--- Edit distance counting a swap of adjacent letters as one edit, giving up
-- (returning limit + 1) beyond `limit`.
function Text.distance(a, b, limit)
  if a == b then return 0 end
  local la, lb = #a, #b
  if math.abs(la - lb) > limit then return limit + 1 end
  local beforePrevious
  local previous = {}
  for j = 0, lb do previous[j] = j end
  for i = 1, la do
    local current = { [0] = i }
    local best = i
    local ca = a:byte(i)
    for j = 1, lb do
      local cb = b:byte(j)
      local cost = ca == cb and 0 or 1
      local value = math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
      if beforePrevious and j > 1 and ca == b:byte(j - 1) and a:byte(i - 1) == cb then
        value = math.min(value, beforePrevious[j - 2] + 1)
      end
      current[j] = value
      if value < best then best = value end
    end
    if best > limit then return limit + 1 end
    beforePrevious, previous = previous, current
  end
  return previous[lb]
end

--- Allowed typo distance for a name: short names only tolerate one edit.
function Text.tolerance(name)
  if #name <= 2 then return 0 end
  if #name <= 5 then return 1 end
  return 2
end

--- Creates a closest-name finder: feed it candidates, then read `.best`.
function Text.suggester(name)
  local lowered = name:lower()
  local limit = Text.tolerance(name)
  local finder = { best = nil, score = limit + 1 }
  function finder.offer(candidate)
    if candidate == name then return end
    local d = Text.distance(lowered, candidate:lower(), limit)
    -- A case-only difference beats any real edit.
    local score = d == 0 and -1 or d
    if score < finder.score or (score == finder.score and finder.best and candidate < finder.best) then
      finder.best, finder.score = candidate, score
    end
  end
  return finder
end

return Text
