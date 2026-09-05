-- recipe.lua -- loading and validation of declarative .recipe files.
--
-- A recipe is a Lua file returning a table. It is purely data — no functions,
-- no side effects. The recipe describes *what* to build; zeta-makepkg handles
-- the *how*. This keeps recipes readable, reviewable, and safe to execute.
--
--   return {
--     name         = "mypkg",
--     version      = "1.2.3",
--     summary      = "Short description",
--     url          = "https://.../mypkg-1.2.3.tar.gz",
--     sha256       = nil,            -- optional source checksum
--     deps         = { "libfoo" },
--     build_system = "meson",       -- autotools | cmake | meson | make | cargo | custom
--     configure_args = { ... },     -- optional extra args
--     build_script  = "build.sh",   -- required for custom
--     archive_format = "xz",        -- "gz" (default) | "xz" for payloads >100 MiB gzipped
--     post_install  = "ln -sfn ../sbin/xtables-legacy-multi usr/bin/iptables-xml",
--     test         = "test -f ${DESTDIR}/usr/bin/mypkg",
--     files        = { "usr/bin/mypkg" },
--   }
--
-- post_install: an optional shell command run once after `make install`
-- (and after clean_stage, before the test), with CWD at the stage root.
-- Use it to repair packaging defects upstream installs into the stage,
-- e.g. absolute symlinks, which Zeta's unpack refuses to commit. ${DESTDIR}
-- is substituted with the stage path when referenced.

local recipe = {}

local path = require("path")
local log  = require("log")

local KNOWN_KEYS = {
  name = true, version = true, summary = true, url = true,
  sha256 = true, deps = true, build_system = true,
  configure_args = true, build_script = true, test = true, files = true,
  archive_format = true, runtime_deps = true, clean_stage = true,
  post_install = true,
}

local BUILD_SYSTEMS = {
  autotools = true, cmake = true, meson = true,
  make = true, cargo = true, custom = true,
}

local HEX64 = "^" .. string.rep("%x", 64) .. "$"

---------------------------------------------------------------------------
-- Normalization & validation
---------------------------------------------------------------------------

function recipe.normalize(raw)
  if type(raw) ~= "table" then
    error("recipe must return a table", 2)
  end

  -- name (required, must be a valid package name)
  local name = raw.name
  if type(name) ~= "string" or not path.sanitize_name(name) then
    error("recipe: missing or invalid package name", 2)
  end

  -- version (required, non-empty)
  local version = raw.version
  if type(version) ~= "string" or version == "" then
    error(("recipe %q: version is required and must be a non-empty string"):format(name), 2)
  end

  -- summary (required)
  local summary = raw.summary
  if type(summary) ~= "string" or summary == "" then
    error(("recipe %q: summary is required"):format(name), 2)
  end

  -- url (required, must be a string)
  local url = raw.url
  if type(url) ~= "string" or url == "" then
    error(("recipe %q: url is required"):format(name), 2)
  end

  -- sha256 (optional, must be 64 hex chars if present)
  local sha256 = nil
  if raw.sha256 ~= nil then
    if type(raw.sha256) ~= "string" or not raw.sha256:lower():match(HEX64) then
      error(("recipe %q: sha256 must be exactly 64 hex characters or nil"):format(name), 2)
    end
    sha256 = raw.sha256:lower()
  end

  -- deps (optional, list of strings)
  local deps = {}
  if raw.deps ~= nil then
    if type(raw.deps) ~= "table" then
      error(("recipe %q: deps must be a list of strings"):format(name), 2)
    end
    for _, d in ipairs(raw.deps) do
      if type(d) ~= "string" or d == "" then
        error(("recipe %q: each dep must be a non-empty string"):format(name), 2)
      end
      deps[#deps + 1] = d
    end
  end

  -- runtime_deps (optional, list of strings): shipped dependency set for the
  -- runtime manifest. Falls back to deps when absent.
  local runtime_deps = nil
  if raw.runtime_deps ~= nil then
    if type(raw.runtime_deps) ~= "table" then
      error(("recipe %q: runtime_deps must be a list of strings"):format(name), 2)
    end
    runtime_deps = {}
    for _, d in ipairs(raw.runtime_deps) do
      if type(d) ~= "string" or d == "" then
        error(("recipe %q: each runtime_dep must be a non-empty string"):format(name), 2)
      end
      runtime_deps[#runtime_deps + 1] = d
    end
  end

  -- build_system (required, must be valid)
  local build_system = raw.build_system
  if type(build_system) ~= "string" or not BUILD_SYSTEMS[build_system] then
    error(("recipe %q: build_system must be one of: %s"):format(
      name, table.concat(sorted_keys(BUILD_SYSTEMS), ", ")), 2)
  end

  -- configure_args (optional, list of strings)
  local configure_args = {}
  if raw.configure_args ~= nil then
    if type(raw.configure_args) ~= "table" then
      error(("recipe %q: configure_args must be a list of strings"):format(name), 2)
    end
    for _, a in ipairs(raw.configure_args) do
      configure_args[#configure_args + 1] = tostring(a)
    end
  end

  -- build_script (required for custom, ignored otherwise)
  local build_script = nil
  if raw.build_script ~= nil then
    if type(raw.build_script) ~= "string" or raw.build_script == "" then
      error(("recipe %q: build_script must be a non-empty string"):format(name), 2)
    end
    build_script = raw.build_script
  end
  if build_system == "custom" and not build_script then
    error(("recipe %q: build_script is required when build_system is 'custom'"):format(name), 2)
  end

  -- test (optional, shell command string)
  local test_cmd = nil
  if raw.test ~= nil then
    if type(raw.test) ~= "string" or raw.test == "" then
      error(("recipe %q: test must be a non-empty shell command string"):format(name), 2)
    end
    test_cmd = raw.test
  end

  -- post_install (optional, shell command string run from the stage root)
  local post_install = nil
  if raw.post_install ~= nil then
    if type(raw.post_install) ~= "string" or raw.post_install == "" then
      error(("recipe %q: post_install must be a non-empty shell command string"):format(name), 2)
    end
    post_install = raw.post_install
  end

  -- files (optional, whitelist of relative paths)
  local files = nil
  if raw.files ~= nil then
    if type(raw.files) ~= "table" then
      error(("recipe %q: files must be a list of relative paths"):format(name), 2)
    end
    files = {}
    for _, f in ipairs(raw.files) do
      if type(f) ~= "string" or f == "" then
        error(("recipe %q: each files entry must be a non-empty string"):format(name), 2)
      end
      local rel = f:gsub("^/*", ""):gsub("/+$", "")
      if rel == "" then
        error(("recipe %q: files entry %q is invalid"):format(name, f), 2)
      end
      files[#files + 1] = rel
    end
  end

  -- archive_format (optional; "gz" default, "xz" for large payloads)
  local archive_format = raw.archive_format
  if archive_format ~= nil then
    if archive_format ~= "gz" and archive_format ~= "xz" then
      error(("recipe %q: archive_format must be \"gz\" or \"xz\""):format(name), 2)
    end
  end

  -- clean_stage (optional; defaults to true). Set false to keep files that
  -- clean_stage would normally strip (systemd units, init scripts, os-release).
  -- Only for packages whose payload contains sealed, content-addressed trees
  -- (e.g. a Nix store closure) where deletion would corrupt registered hashes.
  local clean_stage = raw.clean_stage ~= false

  -- Flag unknown fields
  for k in pairs(raw) do
    if not KNOWN_KEYS[k] then
      log.warn(("recipe %q: unknown field %q (ignored)"):format(name, tostring(k)))
    end
  end

  return {
    name          = name,
    version       = version,
    summary       = summary,
    url           = url,
    sha256        = sha256,
    deps          = deps,
    runtime_deps  = runtime_deps,
    build_system  = build_system,
    configure_args = configure_args,
    build_script   = build_script,
    archive_format = archive_format,
    test          = test_cmd,
    post_install  = post_install,
    files         = files,
    clean_stage   = clean_stage,
  }
end

---------------------------------------------------------------------------
-- Loading
---------------------------------------------------------------------------

function recipe.load(filepath)
  local f, err = io.open(filepath, "rb")
  if not f then
    return nil, ("cannot open recipe %q: %s"):format(filepath, tostring(err))
  end
  local src = f:read("*a")
  f:close()

  -- Recipes run in a minimal environment — they're pure data, but we still
  -- lock down globals to prevent accidental side effects.
  local env = {}
  local chunk
  if setfenv then
    chunk, err = loadstring(src, "@" .. filepath)
    if chunk then setfenv(chunk, env) end
  else
    chunk, err = load(src, "@" .. filepath, "t", env)
  end
  if not chunk then
    return nil, ("recipe %q: syntax error: %s"):format(filepath, tostring(err))
  end

  local ok, raw = pcall(chunk)
  if not ok then
    return nil, ("recipe %q: runtime error: %s"):format(filepath, tostring(raw))
  end

  local ok2, normalized = pcall(recipe.normalize, raw)
  if not ok2 then
    return nil, ("recipe %q: " .. tostring(normalized)):format(filepath)
  end

  log.ok(("loaded recipe %s-%s"):format(normalized.name, normalized.version))
  -- Resolve to absolute path so recipe.dir works even when invoked with a
  -- relative path (e.g. "zeta-makepkg foo.recipe" from the recipes dir).
  local abs = filepath
  if not filepath:match("^/") then
    local cwd = os.getenv("PWD") or "."
    abs = cwd .. "/" .. filepath
  end
  normalized.dir = abs:match("^(.*)[/\\][^/\\]*$") or "."
  return normalized
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

return recipe
