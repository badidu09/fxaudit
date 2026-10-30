--- Minimal filesystem access with no native dependency.
local Fs = {}

Fs.isWindows = package.config:sub(1, 1) == "\\"

--- Normalizes to forward slashes, without a trailing slash.
function Fs.normalize(path)
  local out = path:gsub("\\", "/")
  if #out > 1 and not out:match("^%a:/$") then out = out:gsub("/+$", "") end
  return out
end

function Fs.join(a, b)
  if a == "" or a == "." then return b end
  return Fs.normalize(a) .. "/" .. b
end

function Fs.read(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local content = file:read("a")
  file:close()
  return content
end

function Fs.exists(path)
  local file = io.open(path, "rb")
  if not file then return false end
  file:close()
  return true
end

--- Paths reach a shell, so anything that could break out of the quotes is refused.
local function shellQuote(path)
  if path:find('["%%`$\r\n!^&|<>;]') then
    error("unsupported characters in path: " .. path, 0)
  end
  return '"' .. path .. '"'
end

--- Whether `path` is a directory.
function Fs.isDirectory(path)
  if Fs.isWindows then
    local pipe = io.popen('if exist ' .. shellQuote((path:gsub("/", "\\")) .. "\\") .. ' (echo yes)')
    if not pipe then return false end
    local out = pipe:read("a")
    pipe:close()
    return out:find("yes", 1, true) ~= nil
  end
  local ok = os.execute("test -d " .. shellQuote(path))
  return ok == true or ok == 0
end

--- Lists every file below `root`, recursively, with forward slashes.
function Fs.listFiles(root)
  local command
  if Fs.isWindows then
    -- chcp keeps accented folder names intact in the output of dir.
    command = 'chcp 65001>nul & dir /s /b /a-d ' .. shellQuote((root:gsub("/", "\\"))) .. ' 2>nul'
  else
    command = "find " .. shellQuote(root) .. " -type f 2>/dev/null"
  end
  local pipe = io.popen(command)
  if not pipe then error("cannot list files: io.popen is unavailable", 0) end
  local files = {}
  for line in pipe:lines() do
    line = line:gsub("\r$", "")
    if line ~= "" then files[#files + 1] = Fs.normalize(line) end
  end
  pipe:close()
  -- dir /b prints absolute paths: bring them back under the root the user gave.
  if Fs.isWindows and not root:match("^%a:") and not root:match("^/") then
    local cwd = io.popen("cd")
    local base = cwd and Fs.normalize((cwd:read("l") or ""):gsub("\r$", "")) or ""
    if cwd then cwd:close() end
    local absolute = root == "." and base or (base .. "/" .. Fs.normalize(root))
    for i, file in ipairs(files) do
      if file:sub(1, #absolute + 1) == absolute .. "/" then
        files[i] = Fs.normalize(root) .. file:sub(#absolute + 1)
      end
    end
  end
  table.sort(files)
  return files
end

return Fs
