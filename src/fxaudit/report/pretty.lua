--- Human-readable console report.
local Fs = require("fxaudit.fs")
local Registry = require("fxaudit.rules.registry")
local Score = require("fxaudit.score")

local Pretty = {}

local COLORS = {
  critical = "\27[1;97;41m", high = "\27[1;31m", medium = "\27[33m", low = "\27[36m", info = "\27[90m",
  dim = "\27[2m", bold = "\27[1m", green = "\27[32m", reset = "\27[0m",
}

local LABELS = { critical = "CRITICAL", high = "HIGH", medium = "MEDIUM", low = "LOW", info = "INFO" }

--- Returns the given line of a file, reading each file only once.
local function lineReader()
  local cache = {}
  return function(path, number)
    local lines = cache[path]
    if lines == nil then
      lines = {}
      local content = Fs.read(path)
      if content then
        for line in (content .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
      end
      cache[path] = lines
    end
    return lines[number]
  end
end

--- Renders the report as a string.
-- @param results list of `{ name, findings }`, already filtered
-- @param options `{ color, relativeTo, totalFiles, quiet }`
function Pretty.render(results, options)
  local out = {}
  local function paint(name, text)
    if options.color then return COLORS[name] .. text .. COLORS.reset end
    return text
  end
  local function emit(text) out[#out + 1] = text end

  local readLine = lineReader()
  local totals = { critical = 0, high = 0, medium = 0, low = 0, info = 0 }
  local scored = {}

  for _, resource in ipairs(results) do
    for _, finding in ipairs(resource.findings) do
      totals[finding.severity] = totals[finding.severity] + 1
    end
    scored[#scored + 1] = { name = resource.name, score = Score.compute(resource.findings), count = #resource.findings }
  end

  if not options.quiet then
    for _, resource in ipairs(results) do
      if #resource.findings > 0 then
        emit(paint("bold", resource.name) .. paint("dim", "  (" .. #resource.findings .. " finding" .. (#resource.findings > 1 and "s" or "") .. ")"))
        local currentFile
        for _, finding in ipairs(resource.findings) do
          if finding.file ~= currentFile then
            currentFile = finding.file
            emit("  " .. paint("dim", Pretty.relative(finding.file, options.relativeTo)))
          end
          local confidence = finding.confidence ~= "high" and paint("dim", " (" .. finding.confidence .. " confidence)") or ""
          emit(string.format("    %s %s %s  %s%s",
            paint("dim", string.format("%d:%d", finding.line, finding.col or 1)),
            paint(finding.severity, LABELS[finding.severity]),
            paint("dim", finding.rule),
            finding.message, confidence))
          local source = readLine(finding.file, finding.line)
          if source and #source < 200 and source:find("%S") then
            local indent = source:match("^%s*")
            emit("      " .. paint("dim", "| " .. source:sub(#indent + 1)))
          end
          if finding.hint then
            emit("      " .. paint("green", "> " .. finding.hint))
          end
        end
        emit("")
      end
    end
  end

  table.sort(scored, function(a, b)
    if a.score ~= b.score then return a.score < b.score end
    return a.name < b.name
  end)

  if #scored > 1 then
    emit(paint("bold", "Scores (lowest first)"))
    for _, entry in ipairs(scored) do
      emit(string.format("  %3d/100  %s", entry.score, entry.name))
    end
    emit("")
  end

  local parts = {}
  for _, severity in ipairs(Registry.SEVERITIES) do
    if totals[severity] > 0 then
      parts[#parts + 1] = paint(severity, totals[severity] .. " " .. severity)
    end
  end

  local summary = #results .. " resource" .. (#results > 1 and "s" or "")
    .. ", " .. (options.totalFiles or 0) .. " Lua file" .. ((options.totalFiles or 0) > 1 and "s" or "") .. ": "
  if #parts == 0 then
    emit(summary .. paint("green", "no findings"))
  else
    emit(summary .. table.concat(parts, ", "))
  end
  if #scored == 1 then
    emit("Score: " .. paint("bold", scored[1].score .. "/100"))
  end

  return table.concat(out, "\n") .. "\n"
end

--- Removes a leading base path, for shorter output.
function Pretty.relative(path, base)
  if base and base ~= "" and path:sub(1, #base + 1) == base .. "/" then
    return path:sub(#base + 2)
  end
  return path
end

return Pretty
