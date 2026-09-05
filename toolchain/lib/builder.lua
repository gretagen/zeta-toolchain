-- builder.lua -- source fetching, extraction, build dispatch, and test runner.
--
-- Handles the full build pipeline for a recipe:
--   1. fetch_source   — download to cache (or detect git)
--   2. extract_source — unpack tarball or clone git repo
--   3. run_build      — dispatch autotools/cmake/meson/make/cargo/custom
--   4. run_test       — execute post-build verification command
--
-- All subprocesses run in a minimal environment. Build tools (meson, cmake,
-- ninja, cargo, etc.) must be installed on the host system.

local builder = {}

local path = require("path")
local log  = require("log")

---------------------------------------------------------------------------
-- Utilities
---------------------------------------------------------------------------

local function find_downloader()
  if path.have("curl") then return "curl" end
  if path.have("wget") then return "wget" end
  return nil
end

local function download(url, dest)
  local dl = find_downloader()
  if not dl then
    error("no downloader found (install curl or wget)", 0)
  end
  log.detail("downloading " .. url)
  local tmp = dest .. ".part"
  local ok
  if dl == "curl" then
    ok = path.run("curl -L --fail --show-error -sS -o "
      .. path.quote(tmp) .. " " .. path.quote(url))
  else
    ok = path.run("wget -q -O " .. path.quote(tmp) .. " " .. path.quote(url))
  end
  if not ok then
    os.remove(tmp)
    error(("download failed: %s"):format(url), 0)
  end
  return os.rename(tmp, dest)
end

local function sha256_file(filepath)
  -- Prefer native tools for speed, fall back to openssl.
  local f = io.popen("sha256sum " .. path.quote(filepath) .. " 2>/dev/null")
  if f then
    local digest = f:read("*l")
    f:close()
    local hex = digest and digest:match("^(%x+)")
    if hex then return hex end
  end
  f = io.popen("shasum -a 256 " .. path.quote(filepath) .. " 2>/dev/null")
  if f then
    local digest = f:read("*l")
    f:close()
    local hex = digest and digest:match("^(%x+)")
    if hex then return hex end
  end
  f = io.popen("openssl dgst -sha256 " .. path.quote(filepath) .. " 2>/dev/null")
  if f then
    local digest = f:read("*l")
    f:close()
    local hex = digest and digest:match("=(%x+)")
    if hex then return hex end
  end
  error("sha256: no supported tool found (install sha256sum, shasum, or openssl)", 0)
end

local function get_nproc()
  local f = io.popen("nproc 2>/dev/null")
  if not f then return 1 end
  local n = tonumber(f:read("*l"))
  f:close()
  return (n and n > 0) and n or 1
end

-- After extracting a tarball, detect the source root:
-- if the extraction dir contains exactly one subdirectory, use that.
-- Otherwise use the extraction dir itself.
local function detect_source_dir(extract_dir)
  local f = io.popen("ls -1 " .. path.quote(extract_dir) .. " 2>/dev/null")
  if not f then return extract_dir end
  local entries = {}
  for line in f:lines() do
    if line ~= "" and line ~= "." and line ~= ".." then
      entries[#entries + 1] = line
    end
  end
  f:close()
  if #entries == 1 then
    local candidate = path.join(extract_dir, entries[1])
    -- If the single entry is a file (not a directory), use the parent dir
    -- so the builder can cd into it and reference the file directly.
    local check = io.popen("test -d " .. path.quote(candidate) .. " && echo dir || echo file")
    if check then
      local t = check:read("*l")
      check:close()
      if t == "file" then return extract_dir end
    end
    return candidate
  end
  return extract_dir
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- Fetch source into the cache directory. Returns the cached file path,
-- or nil if the URL is a git repository (signals "use git clone").
function builder.fetch_source(recipe, cache_dir, local_dir)
  local url = recipe.url

  -- Git repos are cloned, not cached as files.
  if url:match("%.git$") or url:match("^git://") or url:match("^git@") then
    log.detail("git source: will clone directly")
    return nil
  end

  local url_base = url:match("[^/]+$") or "source"
  local ext = ""
  for _, e in ipairs({ ".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst", ".tgz", ".txz", ".tbz2", ".tzst" }) do
    if url_base:lower():match(e:gsub("%.", "%%.") .. "$") then
      ext = e
      break
    end
  end
  local cache_file = path.join(cache_dir, recipe.name .. "-" .. recipe.version .. ext)

  if not path.exists(cache_file) then
    path.mkdir_p(cache_dir)

    if url:match("^https?://") then
      log.step("downloading " .. url)
      download(url, cache_file)
    elseif url:match("^file://") then
      local src = url:gsub("^file://", "")
      log.step("copying " .. src)
      if not path.run("cp " .. path.quote(src) .. " " .. path.quote(cache_file)) then
        error(("failed to copy %s"):format(src), 0)
      end
    elseif url:match("^/") then
      log.step("copying " .. url)
      if not path.run("cp " .. path.quote(url) .. " " .. path.quote(cache_file)) then
        error(("failed to copy %s"):format(url), 0)
      end
    else
      -- Bare filename: resolve relative to the recipe's directory.
      if local_dir then
        local src = path.join(local_dir, url)
        log.step("copying " .. src)
        if not path.run("cp " .. path.quote(src) .. " " .. path.quote(cache_file)) then
          error(("failed to copy %s"):format(src), 0)
        end
      else
        error(("unrecognised url scheme: %s"):format(url), 0)
      end
    end
  else
    log.info("using cached source: " .. path.basename(cache_file))
  end

  -- Optional source checksum verification.
  if recipe.sha256 then
    log.step("verifying source sha256")
    local computed = sha256_file(cache_file)
    if computed ~= recipe.sha256 then
      error(("source sha256 mismatch:\n  expected %s\n  got      %s"):format(
        recipe.sha256, computed), 0)
    end
    log.ok("source sha256 verified")
  end

  return cache_file
end

-- Extract a source tarball or clone a git repository into work_dir/src.
-- Returns the actual source root directory.
function builder.extract_source(recipe, cache_file, work_dir)
  local src_dir = path.join(work_dir, "src")

  if not cache_file then
    -- Git clone.
    path.mkdir_p(work_dir)
    log.step("cloning " .. recipe.url)
    if not path.run("git clone --depth 1 " .. path.quote(recipe.url)
      .. " " .. path.quote(src_dir)) then
      error(("git clone failed for %s"):format(recipe.url), 0)
    end
    log.ok("cloned " .. recipe.name)
    return src_dir
  end

  -- Tarball extraction.
  log.step("extracting " .. path.basename(cache_file))
  path.mkdir_p(src_dir)

  local fname = cache_file:lower()
  local cmd

  if fname:match("%.tar%.gz$") or fname:match("%.tgz$") then
    cmd = "tar -xzf " .. path.quote(cache_file) .. " -C " .. path.quote(src_dir) .. " --no-same-owner"
  elseif fname:match("%.tar%.xz$") or fname:match("%.txz$") then
    cmd = "tar -xJf " .. path.quote(cache_file) .. " -C " .. path.quote(src_dir) .. " --no-same-owner"
  elseif fname:match("%.tar%.bz2$") or fname:match("%.tbz2$") then
    cmd = "tar -xjf " .. path.quote(cache_file) .. " -C " .. path.quote(src_dir) .. " --no-same-owner"
  elseif fname:match("%.tar%.zst$") or fname:match("%.tzst$") then
    cmd = "tar --zstd -xf " .. path.quote(cache_file) .. " -C " .. path.quote(src_dir) .. " --no-same-owner"
  elseif fname:match("%.tar$") then
    cmd = "tar -xf " .. path.quote(cache_file) .. " -C " .. path.quote(src_dir) .. " --no-same-owner"
  else
    -- Unrecognised archive — try generic tar.
    cmd = "tar -xf " .. path.quote(cache_file) .. " -C " .. path.quote(src_dir) .. " --no-same-owner"
  end

  if not path.run(cmd) then
    error(("extraction failed for %s"):format(path.basename(cache_file)), 0)
  end

  local source_dir = detect_source_dir(src_dir)
  log.detail("source directory: " .. source_dir)
  return source_dir
end

-- Dispatch the build based on recipe.build_system.
-- Commands run from the source directory, installing into stage_dir.
function builder.run_build(recipe, source_dir, stage_dir, opts)
  opts = opts or {}
  path.mkdir_p(stage_dir)

  local name = recipe.name
  local bs   = recipe.build_system
  local args = recipe.configure_args or {}
  local args_str = ""
  if #args > 0 then
    args_str = " " .. table.concat(args, " ")
  end
  local njobs = opts.jobs or get_nproc()

  log.step(("building %s (%s)"):format(name, bs))

  local function run(cmd)
    log.detail("$ " .. cmd)
    if not path.run("cd " .. path.quote(source_dir) .. " && " .. cmd) then
      error(("build step failed: %s"):format(cmd), 0)
    end
  end

  if bs == "autotools" then
    run("./configure --prefix=/usr" .. args_str)
    run("make -j" .. njobs)
    run("make install DESTDIR=" .. path.quote(stage_dir))

  elseif bs == "cmake" then
    run("cmake -B build -DCMAKE_INSTALL_PREFIX=/usr" .. args_str)
    run("cmake --build build -j" .. njobs)
    run("DESTDIR=" .. path.quote(stage_dir) .. " cmake --install build")

  elseif bs == "meson" then
    run("meson setup build --prefix=/usr" .. args_str)
    run("ninja -C build")
    run("DESTDIR=" .. path.quote(stage_dir) .. " ninja -C build install")

  elseif bs == "make" then
    run("make -j" .. njobs .. args_str)
    run("make install DESTDIR=" .. path.quote(stage_dir))

  elseif bs == "cargo" then
    run("cargo build --release" .. args_str)
    local bin_dir = path.join(stage_dir, "usr/bin")
    path.mkdir_p(bin_dir)
    -- Cargo puts binaries in target/release/<name>. Also support kebab-case.
    local target = path.join(source_dir, "target", "release", name)
    if not path.exists(target) then
      -- Try kebab-case transformation: underscores → hyphens.
      local kebab = name:gsub("_", "-")
      target = path.join(source_dir, "target", "release", kebab)
    end
    if not path.exists(target) then
      -- Try listing directory.
      local f = io.popen("ls " .. path.quote(path.join(source_dir, "target", "release")) .. " 2>/dev/null")
      if f then
        for line in f:lines() do
          local cand = path.join(source_dir, "target", "release", line)
          if path.run("test -f " .. path.quote(cand) .. " -a -x " .. path.quote(cand)) then
            target = cand
            log.detail("detected cargo binary: " .. line)
            break
          end
        end
        f:close()
      end
    end
    run("install -D " .. path.quote(target) .. " " .. path.quote(path.join(bin_dir, path.basename(target))))

  elseif bs == "custom" then
    local script = recipe.build_script
    -- Relative scripts resolve against the recipe's directory first (our
    -- recipes ship build.sh next to the .recipe file), falling back to the
    -- extracted source directory (upstream custom-demo model).
    if not script:match("^/") and recipe.dir then
      local rp = path.join(recipe.dir, script)
      if path.exists(rp) then
        script = rp
      end
    end
    run("DESTDIR=" .. path.quote(stage_dir) .. " sh " .. path.quote(script))

  else
    error(("unknown build_system: %s"):format(bs), 0)
  end

  log.ok("build complete")
  return true
end

-- Run a post-install fixup command from the stage root, substituting
-- ${DESTDIR} with stage_dir. This repairs packaging defects upstream
-- installs into the stage (e.g. absolute symlinks Zeta refuses to commit).
function builder.run_post_install(cmd, stage_dir)
  local subst = cmd:gsub("${DESTDIR}", stage_dir)
  subst = subst:gsub("$DESTDIR", stage_dir)
  log.step("post_install: " .. subst)
  if not path.run("cd " .. path.quote(stage_dir) .. " && " .. subst) then
    error(("post_install failed: %s"):format(subst), 0)
  end
  log.ok("post_install done")
  return true
end

-- Run the test command, substituting ${DESTDIR} with stage_dir.
function builder.run_test(test_cmd, stage_dir)
  local cmd = test_cmd:gsub("${DESTDIR}", stage_dir)
  cmd = cmd:gsub("$DESTDIR", stage_dir)
  log.step("testing: " .. cmd)
  if not path.run(cmd) then
    error(("test failed: %s"):format(cmd), 0)
  end
  log.ok("test passed")
  return true
end

-- Remove files Zeta refuses to install: init-system hooks, unit files, and
-- distro-identity files. Mirrors the blocklist in zeta/lib/commit.lua so a
-- package can never build a payload that fails to commit.
--
-- skip (boolean): opt-out for packages whose payloads contain sealed,
-- content-addressed trees (e.g. a Nix store closure) with registered hashes;
-- stripping embedded unit files there would corrupt the closure.
function builder.clean_stage(stage_dir, skip)
  if skip then
    log.info("clean_stage: skipped (recipe clean_stage = false)")
    return 0
  end

  local blocked_prefixes = {
    "usr/lib/systemd", "lib/systemd", "etc/systemd",
    "etc/init.d", "etc/rc.d", "lib/rc", "usr/lib/rc", "etc/runlevels",
  }
  local blocked_exact = {
    "etc/rc.conf", "etc/rc.local", "etc/rc.shutdown",
    "etc/inittab", "etc/os-release", "etc/lsb-release",
  }
  local blocked_suffixes = {
    ".service", ".timer", ".socket", ".path", ".mount",
    ".target", ".unit", ".automount", ".device", ".slice", ".scope",
  }

  local removed = 0
  for _, p in ipairs(blocked_prefixes) do
    local dir = path.join(stage_dir, p)
    if path.exists(dir) then
      path.run("rm -rf " .. path.quote(dir))
      removed = removed + 1
    end
  end
  for _, e in ipairs(blocked_exact) do
    local f = path.join(stage_dir, e)
    if path.exists(f) then
      path.run("rm -rf " .. path.quote(f))
      removed = removed + 1
    end
  end
  for _, s in ipairs(blocked_suffixes) do
    -- Count matches before deleting so the warning reflects reality.
    local n = io.popen("find " .. path.quote(stage_dir)
      .. " -type f -name '*" .. s .. "' 2>/dev/null | wc -l")
    local count = tonumber(n and n:read("*l") or "0")
    if n then n:close() end
    if count and count > 0 then
      path.run("find " .. path.quote(stage_dir)
        .. " -type f -name '*" .. s .. "' -delete 2>/dev/null")
      removed = removed + count
    end
  end

  if removed > 0 then
    log.warn(("clean_stage: removed %d blocked file(s) from staging"):format(removed))
  end
end

return builder
