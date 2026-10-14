-- closure.lua -- verify a staged package's runtime library closure.
--
-- Every ELF object in the stage declares NEEDED sonames. Each one must be
-- satisfied by one of:
--   (a) the package's own payload (the recipe's files whitelist is applied
--       first -- dropped files do not count as shipped),
--   (b) the package's declared runtime dependency closure, resolved
--       transitively through the local zeta database
--       (/var/db/zeta/{packages,dependencies}/<name>/{meta.lua,files}),
--   (c) the host base system: a soname that exists in the loader cache but
--       is owned by no zeta package (bootstrap files) is accepted as
--       ambient.
--
-- Anything else is a packaging bug of the rofi-1.7.8 kind, where the
-- manifest omitted libxcb-imdkit and the shipped binary could not start:
-- "error while loading shared libraries". The check is skipped (with a
-- note) on builders that have no zeta database, e.g. foreign chroots.

local closure = {}

local path = require("path")
local log  = require("log")

local DB_DIRS = { "/var/db/zeta/packages", "/var/db/zeta/dependencies" }

local function capture_lines(cmd)
  local out = {}
  local text = path.capture(cmd)
  if not text then return out end
  for line in text:gmatch("([^\n]*)\n") do
    if line ~= "" then out[#out + 1] = line end
  end
  return out
end

local function is_elf(file)
  local f = io.open(file, "rb")
  if not f then return false end
  local magic = f:read(4)
  f:close()
  return magic == "\127ELF"
end

-- NEEDED sonames of an ELF object, via readelf (no execution involved).
local function elf_needed(file)
  local out = {}
  for _, line in ipairs(capture_lines("readelf -d " .. path.quote(file))) do
    local soname = line:match("Shared library:%s+%[(.-)%]")
    if soname then out[#out + 1] = soname end
  end
  return out
end

-- Basenames shipped by the stage (post-whitelist), mapped to true.
local function shipped_basenames(stage_dir, whitelist)
  local keep = nil
  if whitelist then
    keep = {}
    for _, w in ipairs(whitelist) do keep[w] = true end
  end
  local shipped = {}
  for _, file in ipairs(capture_lines(
      "find " .. path.quote(stage_dir) .. " \\( -type f -o -type l \\) -print")) do
    local rel = file:sub(#stage_dir + 2)
    if not keep or keep[rel] then
      shipped[file:match("([^/]+)$")] = true
    end
  end
  return shipped
end

-- A needed soname is covered by an exact basename or a dot-extended one
-- ("libfoo.so.1" is covered by a shipped "libfoo.so.1" entry -- the real
-- "libfoo.so.1.2.3" alone must NOT cover it, or broken payloads would
-- pass without the runtime linker name being present).
local function soname_covered(names, soname)
  if names[soname] then return true end
  for name in pairs(names) do
    if name:sub(1, #soname + 1) == soname .. "." then return true end
  end
  return false
end

-- Load one database entry's meta (deps) and file basenames.
local function db_entry(name)
  for _, dir in ipairs(DB_DIRS) do
    local base = path.join(dir, name)
    if path.exists(base) then
      local deps = {}
      local chunk = loadfile(path.join(base, "meta.lua"))
      if chunk then
        local ok, meta = pcall(chunk)
        if ok and type(meta) == "table" and type(meta.deps) == "table" then
          for _, d in ipairs(meta.deps) do deps[#deps + 1] = d end
        end
      end
      local files = {}
      local f = io.open(path.join(base, "files"), "rb")
      if f then
        for line in f:lines() do
          -- nix store paths are nix-internal: the system loader resolves
          -- NEEDED sonames through ldconfig and never loads from
          -- /nix/store, so those files must not claim ownership of
          -- system sonames (they shadowed the real providers).
          if line ~= "" and line:sub(1, 5) ~= "nix/" then
            files[line:match("([^/]+)$")] = true
          end
        end
        f:close()
      end
      return { deps = deps, files = files }
    end
  end
  return nil
end

-- Map every zeta-owned basename to its owning package (first owner wins).
local function db_owners()
  local owners = {}
  for _, dir in ipairs(DB_DIRS) do
    for _, name in ipairs(capture_lines("ls -1 " .. path.quote(dir))) do
      local entry = db_entry(name)
      if entry then
        for base in pairs(entry.files) do
          if not owners[base] then owners[base] = name end
        end
      end
    end
  end
  return owners
end

-- Transitive dependency closure of the declared runtime deps, following
-- meta.lua deps through the database.
local function declared_closure(declared)
  local seen = {}
  local queue = {}
  for _, d in ipairs(declared) do
    if not seen[d] then
      seen[d] = true
      queue[#queue + 1] = d
    end
  end
  while #queue > 0 do
    local name = table.remove(queue, 1)
    local entry = db_entry(name)
    if entry then
      for _, d in ipairs(entry.deps) do
        if not seen[d] then
          seen[d] = true
          queue[#queue + 1] = d
        end
      end
    end
  end
  return seen
end

-- Soname exists in the host loader cache?
local function on_host(soname)
  return #capture_lines("ldconfig -p | grep -F " .. path.quote(soname)) > 0
end

-- closure.verify(recipe, stage_dir) -> true | nil, err
function closure.verify(recipe, stage_dir)
  if not path.exists(DB_DIRS[1]) then
    log.detail("no zeta database -- skipping dependency closure check")
    return true
  end

  local declared = recipe.runtime_deps or recipe.deps or {}
  local shipped = shipped_basenames(stage_dir, recipe.files)
  local owners = db_owners()
  local reachable = declared_closure(declared)

  -- Collect the union of NEEDED sonames over the stage's ELF objects.
  local needed = {}
  for _, file in ipairs(capture_lines(
      "find " .. path.quote(stage_dir) .. " -type f -print")) do
    if is_elf(file) then
      for _, soname in ipairs(elf_needed(file)) do
        needed[soname] = true
      end
    end
  end

  local missing, undeclared = {}, {}
  for soname in pairs(needed) do
    if not soname_covered(shipped, soname) then
      local owner = owners[soname]
      if not owner then
        -- owners[] keys are exact basenames; the provider may ship the
        -- soname as a dot-extended filename, so probe those forms too.
        -- Rank candidates: pure numeric version forms (libfoo.so.1.2.3)
        -- beat incidental siblings (libstdc++.so.6.0.36-gdb.py), then
        -- package name breaks ties so the answer is reproducible --
        -- pairs() order is arbitrary and was flipping the verdict.
        local best_name
        for base, name in pairs(owners) do
          if base:sub(1, #soname + 1) == soname .. "." then
            local rest = base:sub(#soname + 2)
            local numeric = rest:match("^%d[%d%.]*$") ~= nil
            if not best_name
                or (numeric and not best_name[2])
                or (numeric == best_name[2] and name < best_name[1]) then
              best_name = { name, numeric }
            end
          end
        end
        if best_name then owner = best_name[1] end
      end
      if owner then
        if not reachable[owner] then
          undeclared[#undeclared + 1] = ("%s (provided by undeclared %s)")
            :format(soname, owner)
        end
      elseif not on_host(soname) then
        missing[#missing + 1] = soname
      end
    end
  end

  table.sort(missing)
  table.sort(undeclared)
  if #missing > 0 or #undeclared > 0 then
    local parts = {}
    if #missing > 0 then
      parts[#parts + 1] = ("missing shared libraries: %s"):format(table.concat(missing, ", "))
    end
    if #undeclared > 0 then
      parts[#parts + 1] = ("undeclared providers: %s"):format(table.concat(undeclared, "; "))
    end
    return nil, ("dependency closure check failed -- %s"):format(table.concat(parts, " / "))
  end
  return true
end

return closure
