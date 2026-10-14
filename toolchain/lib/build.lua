-- build.lua -- single-recipe pipeline and batch dispatcher.
--
-- build_single(recipe_path, opts)  → runs the full pipeline for one recipe
-- build_all(dir, opts, script_path) → batch build (sequential or parallel)

local build = {}

local path     = require("path")
local log      = require("log")
local recipe   = require("recipe")
local builder  = require("builder")
local packager = require("packager")
local indexer  = require("indexer")
local closure  = require("closure")

---------------------------------------------------------------------------
-- Dependency resolution (--follow)
---------------------------------------------------------------------------

-- Given a recipe directory and a dep spec (e.g. "ncurses" or "libfoo>=2.0"),
-- return the path to <dep>.recipe if it exists, or nil.
local function find_dep_recipe(recipe_dir, dep_spec)
  local name = dep_spec:match("^([%w%._+%-]+)")
  if not name then return nil end
  local p = path.join(recipe_dir, name .. ".recipe")
  if path.exists(p) then return p end
  return nil
end

-- Recursively collect all dependency recipe paths, bottom-up (deps first).
-- Returns an ordered list (no duplicates) and an in-progress set for cycle
-- detection. Recipes for deps that don't have a .recipe file are silently
-- skipped (assumed already installed).
local function collect_deps(recipe_path, seen, order, in_progress)
  if seen[recipe_path] then return end
  if in_progress[recipe_path] then
    error(("dependency cycle involving %s"):format(path.basename(recipe_path)), 0)
  end

  in_progress[recipe_path] = true

  local r, err = recipe.load(recipe_path)
  if not r then
    in_progress[recipe_path] = nil
    log.warn(("skipping %s: %s"):format(path.basename(recipe_path), tostring(err)))
    return
  end

  local dir = path.dirname(recipe_path)
  for _, dep in ipairs(r.deps) do
    local dep_recipe = find_dep_recipe(dir, dep)
    if dep_recipe then
      collect_deps(dep_recipe, seen, order, in_progress)
    end
  end

  in_progress[recipe_path] = nil
  seen[recipe_path] = true
  order[#order + 1] = recipe_path
end

-- Return an ordered list of recipe paths to build: all dependencies
-- (bottom-up), then the target recipe itself.
local function resolve_deps(recipe_path)
  local seen = {}
  local order = {}
  local in_progress = {}
  collect_deps(recipe_path, seen, order, in_progress)
  return order
end

---------------------------------------------------------------------------
-- Single recipe pipeline
---------------------------------------------------------------------------

function build.single(recipe_path, opts)
  -- If --follow, build dependencies first (bottom-up order, already sorted).
  if opts.follow then
    log.step("resolving dependencies")
    local ordered = resolve_deps(recipe_path)
    local dep_count = #ordered - 1  -- last is the target itself
    if dep_count > 0 then
      log.info(("found %d dependenc%s"):format(dep_count, dep_count == 1 and "y" or "ies"))
      for i = 1, dep_count do
        io.write("\n" .. string.rep("─", 36) .. "\n")
        log.step(("building dependency %s (%d/%d)"):format(
          path.basename(ordered[i]), i, dep_count))
        build.single(ordered[i], opts)
      end
      io.write("\n" .. string.rep("─", 36) .. "\n")
    else
      log.info("no unresolved dependencies")
    end
  end

  local r, err = recipe.load(recipe_path)
  if not r then error(("recipe error: %s"):format(tostring(err)), 0) end

  local packages_dir = path.join(opts.output, "packages")
  local pkg_dir = path.join(packages_dir, r.name)

  if path.exists(pkg_dir) and not opts.force then
    error(("package %s already exists at %s (use --force to overwrite)"):format(
      r.name, pkg_dir), 0)
  end
  path.mkdir_p(pkg_dir)

  local stamp = os.date("%Y%m%d-%H%M%S")
  local tmp_base = os.getenv("TMPDIR") or "/tmp"
  local work_dir = path.join(tmp_base, "zeta-makepkg", r.name .. "-" .. stamp)
  local stage_dir = path.join(work_dir, "stage")
  path.mkdir_p(stage_dir)

  log.info(("work directory: %s"):format(work_dir))

  local cache_dir = path.join(os.getenv("HOME") or "/tmp", ".cache", "zeta-makepkg", "sources")
  local recipe_dir = path.dirname(recipe_path)
  local cache_file = builder.fetch_source(r, cache_dir, recipe_dir)
  local source_dir = builder.extract_source(r, cache_file, work_dir)

  builder.run_build(r, source_dir, stage_dir, { jobs = opts.jobs })

  -- Strip files Zeta refuses to install (init hooks, unit files, os-release…
  -- unless the recipe opts out; see clean_stage in recipe.lua).
  builder.clean_stage(stage_dir, r.clean_stage == false)

  if r.post_install then
    builder.run_post_install(r.post_install, stage_dir)
  end

  if r.test then
    builder.run_test(r.test, stage_dir)
  else
    log.info("no test command — skipping verification")
  end

  -- Every NEEDED soname must be covered by the payload, the declared
  -- runtime dependency closure, or the host base system (rofi-1.7.8 rule).
  log.step("verifying dependency closure")
  local ok, cerr = closure.verify(r, stage_dir)
  if not ok then
    error(tostring(cerr), 0)
  end
  log.ok("dependency closure verified")

  local ext = packager.archive_ext(r)
  local tarball_path = path.join(pkg_dir, r.name .. "-" .. r.version .. ext)
  local sha256 = packager.create_tarball(stage_dir, tarball_path, r.archive_format)
  packager.write_manifest(r, sha256, pkg_dir, opts.repo, opts.local_urls)

  if not opts.no_index then
    indexer.generate(packages_dir)
  else
    log.info("--no-index: skipping index update")
  end

  if not opts.keep_work then
    path.run("rm -rf " .. path.quote(work_dir))
  else
    log.info(("--keep-work: work directory preserved at %s"):format(work_dir))
  end

  log.ok(("%s-%s built successfully"):format(r.name, r.version))
  log.info(("output: %s"):format(pkg_dir))
end

---------------------------------------------------------------------------
-- Collect recipes from a directory
---------------------------------------------------------------------------

local function collect_recipes(dir)
  local recipes = {}
  local f = io.popen("find " .. path.quote(dir)
    .. " -maxdepth 1 -name '*.recipe' -type f 2>/dev/null | sort")
  if f then
    for line in f:lines() do
      if line ~= "" then recipes[#recipes + 1] = line end
    end
    f:close()
  end
  return recipes
end

---------------------------------------------------------------------------
-- Batch build
---------------------------------------------------------------------------

function build.all(dir, opts, script_path)
  if not path.exists(dir) then
    error(("directory not found: %s"):format(dir), 0)
  end

  log.step(("scanning %s for recipes"):format(dir))

  local recipes = collect_recipes(dir)
  if #recipes == 0 then
    error(("no .recipe files found in %s"):format(dir), 0)
  end

  log.info(("found %d recipe(s)"):format(#recipes))

  local batch_opts = {
    output     = opts.output,
    no_index   = true,
    keep_work  = opts.keep_work,
    force      = opts.force,
    jobs       = opts.jobs,
    repo       = opts.repo,
    local_urls = opts.local_urls,
  }

  local failed = {}
  local workers = opts.workers or 1

  if workers <= 1 then
    for _, recipe_path in ipairs(recipes) do
      io.write("\n" .. string.rep("─", 48) .. "\n")
      log.step(("building %s"):format(path.basename(recipe_path)))
      local ok, err = pcall(build.single, recipe_path, batch_opts)
      if not ok then
        log.error(tostring(err))
        failed[#failed + 1] = { path = recipe_path, err = tostring(err) }
      end
    end
  else
    local task_dir = path.join(os.getenv("TMPDIR") or "/tmp", "zeta-makepkg-workers")
    path.run("rm -rf " .. path.quote(task_dir))
    path.mkdir_p(task_dir)

    local jobs_flag = opts.jobs and (" -j" .. opts.jobs) or ""
    local running = 0

    local function count_alive()
      local n = 0
      for i = 1, #recipes do
        if not path.exists(task_dir .. "/" .. i .. ".done") then n = n + 1 end
      end
      return n
    end

    for i, recipe_path in ipairs(recipes) do
      while running >= workers do
        os.execute("sleep 0.5")
        running = count_alive()
      end

      local done_file = task_dir .. "/" .. i .. ".done"
      local log_file  = task_dir .. "/" .. i .. ".log"
      local local_flag = opts.local_urls and " --local-urls" or ""
      local cmd = string.format(
        "(%s %s %s --output %s --no-index --force --repo %s%s > %s 2>&1; echo $? > %s) &",
        path.quote(script_path), jobs_flag, path.quote(recipe_path),
        path.quote(opts.output), path.quote(opts.repo), local_flag,
        path.quote(log_file), path.quote(done_file))

      os.execute(cmd)
      running = running + 1
      log.info(("[%d/%d] spawned %s"):format(i, #recipes, path.basename(recipe_path)))
    end

    log.step("waiting for workers...")
    while count_alive() > 0 do
      os.execute("sleep 0.5")
    end

    for i = 1, #recipes do
      local done_file = task_dir .. "/" .. i .. ".done"
      local f = io.open(done_file, "r")
      local exit_code = f and tonumber(f:read("*l")) or 1
      if f then f:close() end
      if exit_code ~= 0 then
        local err_msg = ("exit code %d"):format(exit_code)
        local lf = io.open(task_dir .. "/" .. i .. ".log", "r")
        if lf then
          for line in lf:lines() do
            if line:match("error") then err_msg = line end
          end
          lf:close()
        end
        failed[#failed + 1] = { path = recipes[i], err = err_msg }
      else
        log.ok(path.basename(recipes[i]))
      end
    end

    path.run("rm -rf " .. path.quote(task_dir))
  end

  io.write("\n" .. string.rep("─", 48) .. "\n")
  if not opts.no_index then
    indexer.generate(path.join(opts.output, "packages"))
  end

  io.write("\n")
  local built = #recipes - #failed
  log.ok(("%d built, %d failed"):format(built, #failed))
  if #failed > 0 then
    log.warn("failed recipes:")
    for _, f in ipairs(failed) do
      log.warn(("  %s — %s"):format(path.basename(f.path), f.err))
    end
    os.exit(1)
  end
end

return build
