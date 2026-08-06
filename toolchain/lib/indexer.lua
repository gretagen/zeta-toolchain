-- indexer.lua -- generates packages/index.lua from all package.lua manifests.
--
-- Scans <output>/packages/ for every subdirectory containing a package.lua.
-- Each manifest is loaded in a sandboxed environment (no io, os, etc.) and
-- its name, version, and summary are extracted. The resulting index is
-- written as a Lua list, sorted by package name.

local indexer = {}

local path = require("path")
local log  = require("log")

---------------------------------------------------------------------------
-- Sandboxed manifest loading
---------------------------------------------------------------------------

-- Load a package.lua file and extract { name, version, summary }.
-- Runs in a locked-down environment — the manifest cannot access io, os,
-- require, or any global state. Only pure table constructors are allowed.
local function load_manifest_meta(filepath)
  local f, err = io.open(filepath, "rb")
  if not f then return nil, err end
  local src = f:read("*a")
  f:close()

  local env = {}
  local chunk
  if setfenv then
    chunk, err = loadstring(src, "@" .. filepath)
    if chunk then setfenv(chunk, env) end
  else
    chunk, err = load(src, "@" .. filepath, "t", env)
  end
  if not chunk then
    return nil, ("%s: syntax error: %s"):format(filepath, tostring(err))
  end

  local ok, raw = pcall(chunk)
  if not ok or type(raw) ~= "table" then
    return nil, ("%s: must return a table"):format(filepath)
  end

  local meta = {
    name    = type(raw.name)    == "string" and raw.name    or nil,
    version = type(raw.version) == "string" and raw.version or nil,
    summary = type(raw.summary) == "string" and raw.summary or nil,
  }

  if not meta.name then
    return nil, ("%s: missing or invalid name"):format(filepath)
  end

  return meta
end

---------------------------------------------------------------------------
-- Index generation
---------------------------------------------------------------------------

-- Scan <packages_dir> for all subdirectories containing package.lua and
-- write a sorted index.lua. Returns the path to the written index.
function indexer.generate(packages_dir)
  if not path.exists(packages_dir) then
    log.warn("packages directory not found: " .. packages_dir)
    return nil
  end

  log.step("generating index for " .. packages_dir)

  -- Collect all package.lua files.
  local f = io.popen("find " .. path.quote(packages_dir)
    .. " -mindepth 2 -maxdepth 2 -name package.lua"
    .. " -type f 2>/dev/null | sort")
  if not f then
    error(("cannot scan %s"):format(packages_dir), 0)
  end

  local entries = {}
  for filepath in f:lines() do
    local meta, err = load_manifest_meta(filepath)
    if meta then
      entries[#entries + 1] = meta
    else
      log.warn(tostring(err))
    end
  end
  f:close()

  -- Sort by name.
  table.sort(entries, function(a, b) return a.name < b.name end)

  -- Write index.lua
  local index_path = path.join(packages_dir, "index.lua")
  local lines = { "return {" }

  for _, e in ipairs(entries) do
    lines[#lines + 1] = string.format(
      '  { name = %q, version = %q, summary = %q },',
      e.name,
      e.version or "",
      e.summary or ""
    )
  end

  lines[#lines + 1] = "}"

  local tmp = index_path .. ".tmp"
  local out, err = io.open(tmp, "wb")
  if not out then
    error(("cannot write %s: %s"):format(tmp, tostring(err)), 0)
  end
  out:write(table.concat(lines, "\n") .. "\n")
  out:close()

  os.rename(tmp, index_path)
  log.ok(("index updated (%d packages)"):format(#entries))
  return index_path
end

return indexer
