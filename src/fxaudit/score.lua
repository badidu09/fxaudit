--- Turns findings into a 0-100 score, so that a founder can compare resources.
local Score = {}

local WEIGHTS = { critical = 40, high = 12, medium = 3, low = 0.5, info = 0 }
local CONFIDENCE = { high = 1, medium = 0.6, low = 0.25 }

--- The score decays with the total penalty: it never quite reaches 0, and a
-- hundred small remarks cannot outweigh what a single critical issue costs.
function Score.compute(findings)
  local penalty = 0
  for _, finding in ipairs(findings) do
    penalty = penalty + (WEIGHTS[finding.severity] or 0) * (CONFIDENCE[finding.confidence] or 1)
  end
  return math.floor(100 * 0.99 ^ penalty + 0.5)
end

return Score
