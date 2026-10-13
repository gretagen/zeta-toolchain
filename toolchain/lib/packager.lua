-- packager.lua -- tarball creation, sha256 computation, and package.lua generation.
--
-- Converts a staged install tree (DESTDIR layout) into a Zeta-compatible
-- binary tarball with archive strip=1 format. Computes the sha256 checksum
-- of the output tarball and writes the package.lua manifest.

local packager = {}

local path = require("path")
local log  = require("log")

---------------------------------------------------------------------------
-- Private helpers (must be defined before the public API that uses them)
---------------------------------------------------------------------------

local function escape(s)
  return s:gsub('"', '\\"'):gsub("\n", "\\n")
end

local function escape_lua_string(s)
  return s:gsub("\\", "\\\\"):gsub("'", "\\'")
end

local function human_size(filepath)
  local f = io.open(filepath, "rb")
  if not f then return "? B" end
  local size = f:seek("end")
  f:close()
  if size >= 1024 * 1024 then
    return string.format("%.1f MiB", size / (1024 * 1024))
  elseif size >= 1024 then
    return string.format("%.0f KiB", size / 1024)
  end
  return string.format("%d B", size)
end

local function sha256_file(filepath)
  local f = io.popen("sha256sum " .. path.quote(filepath) .. " 2>/dev/null")
  if f then
    local line = f:read("*l")
    f:close()
    local hex = line and line:match("^(%x+)")
    if hex then return hex end
  end
  f = io.popen("shasum -a 256 " .. path.quote(filepath) .. " 2>/dev/null")
  if f then
    local line = f:read("*l")
    f:close()
    local hex = line and line:match("^(%x+)")
    if hex then return hex end
  end
  f = io.popen("openssl dgst -sha256 " .. path.quote(filepath) .. " 2>/dev/null")
  if f then
    local line = f:read("*l")
    f:close()
    local hex = line and line:match("=(%x+)")
    if hex then return hex end
  end
  error("sha256: no supported tool found (install sha256sum, shasum, or openssl)", 0)
end

local function write_atomic(filepath, content)
  local tmp = filepath .. ".tmp"
  local f, err = io.open(tmp, "wb")
  if not f then return nil, err end
  f:write(content)
  f:close()
  return os.rename(tmp, filepath)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- Payload filename extension for a given archive format.
function packager.archive_ext(recipe)
  local fmt = recipe.archive_format or "gz"
  if fmt == "xz" then return ".tar.xz" end
  return ".tar.gz"
end

-- Tar up the staging directory, strip=1 format.
-- Files in the tarball are rooted at "./" so Zeta's strip=1 produces clean
-- relative paths (usr/bin/foo, not ./usr/bin/foo).
function packager.create_tarball(stage_dir, dest_path, archive_format)
  log.step("packaging " .. path.basename(dest_path))
  path.mkdir_p(path.dirname(dest_path))

  local cmd
  if archive_format == "xz" then
    cmd = "tar -cJf " .. path.quote(dest_path)
      .. " -C " .. path.quote(stage_dir) .. " ."
  else
    cmd = "tar -czf " .. path.quote(dest_path)
      .. " -C " .. path.quote(stage_dir) .. " ."
  end

  if not path.run(cmd) then
    error(("failed to create tarball %s"):format(dest_path), 0)
  end

  local sha256 = sha256_file(dest_path)
  log.detail(("sha256: %s"):format(sha256))
  log.ok(("packaged %s (%s)"):format(path.basename(dest_path), human_size(dest_path)))

  return sha256
end

-- Generate a Zeta-compatible package.lua manifest and write it to pkg_dir.
-- The generated manifest uses archive mode (strip=1) and includes the
-- computed sha256 of the binary tarball. Optional fields (deps, files,
-- test) are included when present in the recipe.
function packager.write_manifest(recipe, tarball_sha256, pkg_dir, repo, local_urls)
  local repo = repo or "https://raw.githubusercontent.com/gretagen/zeta-packages/refs/heads/main"
  local lines = {}
  local function emit(fmt, ...)
    lines[#lines + 1] = string.format(fmt, ...)
  end

  emit("return {")
  emit('  name    = "%s",', recipe.name)
  emit('  version = "%s",', recipe.version)
  emit('  summary = "%s",', escape(recipe.summary))
  local ext = packager.archive_ext(recipe)
  if local_urls then
    -- Bare filename: the payload sits next to package.lua in the repo tree,
    -- for offline/local installs without a local_dir override.
    emit('  url     = "%s-%s%s",', recipe.name, recipe.version, ext)
  else
    emit('  url     = "%s/packages/%s/%s-%s%s",',
      repo, recipe.name, recipe.name, recipe.version, ext)
  end
  emit('  sha256  = "%s",', tarball_sha256)

  local runtime_deps = recipe.runtime_deps or recipe.deps
  if #runtime_deps > 0 then
    local dep_strs = {}
    for _, d in ipairs(runtime_deps) do
      dep_strs[#dep_strs + 1] = string.format('"%s"', escape(d))
    end
    emit('  deps    = { %s },', table.concat(dep_strs, ", "))
  else
    emit('  deps    = {},')
  end

  emit('  archive = { strip = 1 },')

  if recipe.files then
    local file_strs = {}
    for _, f in ipairs(recipe.files) do
      file_strs[#file_strs + 1] = string.format('"%s"', escape(f))
    end
    emit('  files   = { %s },', table.concat(file_strs, ", "))
  end

  if recipe.test then
    -- Generate a test function that substitutes ${DESTDIR} -> p.install_root.
    -- Splits the test command around each ${DESTDIR} and uses Lua's %q format
    -- so every string segment is properly quoted.
    emit("  test    = function(p)")
    local parts = {}
    local rem = recipe.test
    while true do
      local si, ei = rem:find("${DESTDIR}", 1, true)
      if not si then
        if rem ~= "" then parts[#parts + 1] = string.format("%q", rem) end
        break
      end
      if si > 1 then
        parts[#parts + 1] = string.format("%q", rem:sub(1, si - 1))
      end
      parts[#parts + 1] = "p.install_root"
      rem = rem:sub(ei + 1)
    end
    emit("    p:run(%s)", table.concat(parts, " .. "))
    emit("  end,")
  end

  emit("}")

  local content = table.concat(lines, "\n") .. "\n"
  local dest = path.join(pkg_dir, "package.lua")

  write_atomic(dest, content)
  log.ok("wrote package.lua")
  return dest
end

return packager
