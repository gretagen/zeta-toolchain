-- path.lua -- minimal self-contained filesystem helpers for zeta-makepkg.
--
-- Deliberately avoids any external dependencies so the toolchain can run
-- without Zeta installed. All subprocess calls use plain os.execute.

local path = {}

---------------------------------------------------------------------------
-- String helpers
---------------------------------------------------------------------------

-- Join path components with a single separator. The first non-empty
-- component decides whether the result is absolute; later components are
-- treated as plain name pieces even if they carry a leading slash.
function path.join(...)
  local parts = {}
  local abs = false
  local first = true
  for i = 1, select("#", ...) do
    local part = tostring((select(i, ...)))
    if part == "/" then
      if first then abs = true end
    elseif part ~= "" then
      local p = part:gsub("^/+", ""):gsub("/+$", "")
      if p ~= "" then
        if first then abs = (part:match("^/") ~= nil) end
        parts[#parts + 1] = p
      end
    end
    first = false
  end
  if #parts == 0 then return "/" end
  local out = table.concat(parts, "/")
  if abs then out = "/" .. out end
  return out
end

function path.is_abs(p)
  return p:match("^/") ~= nil
end

function path.basename(p)
  p = p:gsub("/+$", "")
  return p:match("[^/]+$") or p
end

function path.dirname(p)
  p = p:gsub("/+$", "")
  if p == "" then return "." end
  local d = p:match("^(.*)/[^/]+$")
  if not d then return "." end
  if d == "" then return "/" end
  return d
end

-- Shell-quote a value for safe use in a command. Values containing only
-- "safe" characters are returned as-is; everything else is single-quoted.
function path.quote(s)
  if s == "" then return "''" end
  if s:match("^[%w%._%/+%-:=@,]+$") then return s end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

---------------------------------------------------------------------------
-- Filesystem helpers
---------------------------------------------------------------------------

-- Run a shell command, streaming output to the parent. Returns true on
-- exit status 0. Compatible with Lua 5.1 through 5.4.
function path.run(cmd)
  local a, b, c = os.execute(cmd)
  if type(a) == "number" then return a == 0 end
  return a == true and b == "exit" and c == 0
end

-- mkdir -p wrapper.
function path.mkdir_p(dir)
  if dir == "" or dir == "/" then return true end
  return path.run("mkdir -p " .. path.quote(dir))
end

-- True if a file or directory (or dangling symlink) exists.
function path.exists(p)
  local f = io.open(p, "rb")
  if f then
    f:close()
    return true
  end
  return path.run("test -e " .. path.quote(p) .. " -o -L " .. path.quote(p))
end

-- Package names must be tightly constrained (alphanumeric, dots, underscores,
-- plus, hyphen). No slashes, no leading dots, no other special characters.
function path.sanitize_name(name)
  if type(name) ~= "string" then return nil end
  if name == "" then return nil end
  if name:match("^%.") then return nil end
  if not name:match("^[%w%._+%-]+$") then return nil end
  return name
end

---------------------------------------------------------------------------
-- Download / tool detection
---------------------------------------------------------------------------

-- True if the given command is available on PATH.
function path.have(cmd)
  local f = io.popen("command -v " .. cmd .. " 2>/dev/null")
  if not f then return false end
  local out = f:read("*l")
  f:close()
  return out ~= nil and out ~= ""
end

-- Capture stdout of a command. Returns output string or nil on failure.
function path.capture(cmd)
  local f = io.popen(cmd .. " 2>/dev/null")
  if not f then return nil end
  local out = f:read("*a")
  f:close()
  return out
end

return path
