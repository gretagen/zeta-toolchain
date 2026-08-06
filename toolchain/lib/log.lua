-- log.lua -- always-verbose colored logging for zeta-makepkg.
--
-- Every operation is printed so the user sees exactly what is happening.
-- Colors are disabled when TERM=dumb or NO_COLOR is set.

local log = {}

local function wants_color()
  local t = os.getenv("TERM")
  if not t or t == "" or t == "dumb" then return false end
  if os.getenv("NO_COLOR") then return false end
  return true
end

local COLOR = wants_color()

local C = {
  reset  = "\27[0m",
  cyan   = "\27[36m",
  green  = "\27[32m",
  yellow = "\27[33m",
  red    = "\27[31m",
  dim    = "\27[2m",
}

local function paint(color, s)
  if not COLOR then return s end
  return C[color] .. s .. C.reset
end

function log.step(msg)
  print(paint("cyan", "==> " .. msg))
end

function log.ok(msg)
  print(paint("green", " ok  " .. msg))
end

function log.warn(msg)
  io.stderr:write(paint("yellow", "warn ") .. msg .. "\n")
end

function log.error(msg)
  io.stderr:write(paint("red", "error") .. " " .. msg .. "\n")
end

function log.info(msg)
  print("  -  " .. msg)
end

function log.detail(msg)
  print(paint("dim", "  .  " .. msg))
end

function log.fatal(msg)
  log.error(msg)
  os.exit(1)
end

return log
