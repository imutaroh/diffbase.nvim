-- Test helpers: throwaway git repos under tests/.tmp/run, fakes for gitsigns / neo-tree / vim.ui.select,
-- notification capture, wait helpers and assertions.
local M = {}

local uv = vim.uv or vim.loop

M.root = nil ---@type string
M.tmp = nil ---@type string

local real_select = vim.ui.select
local real_notify = vim.notify
local notes = {}
local counter = 0
local test_group

---@param root string repository root of diffbase.nvim
function M.init(root)
  M.root = root
  M.tmp = root .. "/tests/.tmp/run"
  vim.fn.delete(M.tmp, "rf")
  vim.fn.mkdir(M.tmp, "p")
  M.tmp = uv.fs_realpath(M.tmp)
end

function M.teardown()
  vim.fn.delete(M.tmp, "rf")
end

---------------------------------------------------------------------------------------------------------------
-- Notifications
---------------------------------------------------------------------------------------------------------------

local function capture_notify(msg, level)
  notes[#notes + 1] = { msg = tostring(msg), level = level or vim.log.levels.INFO }
end

---@return { msg: string, level: integer }[]
function M.notifications()
  return notes
end

---Notifications whose message contains `text` (plain), optionally of a given level.
---@param text string
---@param level? integer
---@return { msg: string, level: integer }[]
function M.find_notes(text, level)
  local out = {}
  for _, n in ipairs(notes) do
    if n.msg:find(text, 1, true) and (level == nil or n.level == level) then
      out[#out + 1] = n
    end
  end
  return out
end

---@return { msg: string, level: integer }[]
function M.warnings()
  local out = {}
  for _, n in ipairs(notes) do
    if n.level == vim.log.levels.WARN then
      out[#out + 1] = n
    end
  end
  return out
end

function M.clear_notes()
  notes = {}
end

---------------------------------------------------------------------------------------------------------------
-- Reset between tests
---------------------------------------------------------------------------------------------------------------

function M.reset()
  local d = package.loaded["diffbase"]
  if d then
    pcall(function()
      if d._state().return_to then
        d.back()
      end
    end)
    pcall(d.off)
  end
  pcall(vim.cmd, "silent! %bwipeout!")
  for name in pairs(package.loaded) do
    if name:match("^diffbase") or name == "gitsigns" or name:match("^gitsigns%.") or name:match("^neo%-tree") then
      package.loaded[name] = nil
    end
  end
  pcall(vim.api.nvim_del_augroup_by_name, "diffbase")
  test_group = vim.api.nvim_create_augroup("diffbase_test", { clear = true })
  pcall(vim.api.nvim_del_augroup_by_name, "diffbase_test_scheme")
  vim.g.colors_name = nil
  vim.o.background = "dark"
  vim.cmd("highlight clear")
  -- `:hi clear` keeps default links; drop those too so every test starts with undefined groups.
  local groups = { "DiffBaseNewLine", "DiffBaseNewNr", "MyAdd" }
  for name in pairs(vim.api.nvim_get_hl(0, {})) do
    if type(name) == "string" and vim.startswith(name, "GitSigns") then
      groups[#groups + 1] = name
    end
  end
  for _, g in ipairs(groups) do
    pcall(vim.cmd, "highlight! default link " .. g .. " NONE")
    pcall(vim.cmd, "highlight clear " .. g)
  end
  vim.ui.select = real_select
  vim.notify = capture_notify
  notes = {}
  vim.cmd.cd(vim.fn.fnameescape(M.root))
end

---Restore the real vim.notify (used by the runner for its own output, not needed by tests).
function M.real_notify(...)
  return real_notify(...)
end

---------------------------------------------------------------------------------------------------------------
-- Shell / git
---------------------------------------------------------------------------------------------------------------

---Run a command synchronously; errors on non-zero exit.
---@param argv string[]
---@param cwd? string
---@return string stdout
function M.run(argv, cwd)
  local res = vim.system(argv, { cwd = cwd, text = true }):wait()
  if res.code ~= 0 then
    error(("command failed (%d): %s\n%s"):format(res.code, table.concat(argv, " "), res.stderr or ""), 2)
  end
  return res.stdout or ""
end

---@param dir string
---@param ... string
---@return string stdout trimmed
function M.git(dir, ...)
  return vim.trim(M.run(vim.list_extend({ "git", "-C", dir }, { ... })))
end

---@param path string
---@param content string|string[]
function M.write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  if type(content) == "table" then
    content = table.concat(content, "\n") .. "\n"
  end
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
end

---A fresh, unique directory path under tests/.tmp/run (not created).
---@param name string
---@return string
function M.path(name)
  counter = counter + 1
  return ("%s/%03d-%s"):format(M.tmp, counter, name)
end

---`git init -b main` in a fresh directory.
---@param name? string
---@return string dir realpath
function M.repo(name)
  local dir = M.path(name or "repo")
  vim.fn.mkdir(dir, "p")
  M.run({ "git", "init", "-q", "-b", "main", dir })
  return uv.fs_realpath(dir)
end

---Stage everything (or only `paths`) and commit.
---@param dir string
---@param msg string
---@param paths? string[]
---@return string sha
function M.commit(dir, msg, paths)
  if paths then
    M.git(dir, "add", "--", unpack(paths))
  else
    M.git(dir, "add", "-A")
  end
  M.git(dir, "commit", "-q", "--no-verify", "-m", msg)
  return M.git(dir, "rev-parse", "HEAD")
end

---@param dir string
---@param rel string
function M.write_binary(dir, rel)
  M.write(dir .. "/" .. rel, "\0\1\2\3binary\0data\255\254")
end

---Standard fixture:
---  main:    init (src/a.txt a1..a4, src/b.txt b1 b2, README.md) -> second (src/b.txt +2 -1)
---  feature: feat (adds src/c.txt 2 lines, removes 2 lines from src/a.txt)    [checked out]
---  untracked: untracked.txt (3 lines), blob.bin (binary)
---With opts.origin, a bare clone is added as `origin` (origin/HEAD -> origin/main) before branching, and
---main tracks origin/main.
---@param opts? { origin?: boolean, untracked?: boolean }
---@return { dir: string, init: string, second: string, feat: string, origin?: string }
function M.fixture(opts)
  opts = opts or {}
  local dir = M.repo("fx")
  M.write(dir .. "/src/a.txt", { "a1", "a2", "a3", "a4" })
  M.write(dir .. "/src/b.txt", { "b1", "b2" })
  M.write(dir .. "/README.md", { "readme" })
  local init = M.commit(dir, "init")
  M.write(dir .. "/src/b.txt", { "b1", "b2 changed", "b3" })
  local second = M.commit(dir, "second")
  local fx = { dir = dir, init = init, second = second }
  if opts.origin then
    local origin = dir .. "-origin.git"
    M.run({ "git", "clone", "-q", "--bare", dir, origin })
    M.git(dir, "remote", "add", "origin", origin)
    M.git(dir, "fetch", "-q", "origin")
    M.git(dir, "remote", "set-head", "origin", "main")
    M.git(dir, "branch", "-q", "--set-upstream-to=origin/main", "main")
    fx.origin = origin
  end
  M.git(dir, "switch", "-q", "-c", "feature")
  M.write(dir .. "/src/c.txt", { "c1", "c2" })
  M.write(dir .. "/src/a.txt", { "a1", "a2" })
  fx.feat = M.commit(dir, "feat")
  if opts.untracked ~= false then
    M.write(dir .. "/untracked.txt", { "u1", "u2", "u3" })
    M.write_binary(dir, "blob.bin")
  end
  return fx
end

---------------------------------------------------------------------------------------------------------------
-- Editor helpers
---------------------------------------------------------------------------------------------------------------

---@param path string
---@return integer buf
function M.edit(path)
  vim.cmd("silent edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

---Wait until `cond()` is truthy; fails the test on timeout.
---@param cond fun(): any
---@param msg? string
---@param ms? integer
function M.wait_for(cond, msg, ms)
  local ok = vim.wait(ms or 5000, function()
    local r = cond()
    return r and true or false
  end, 5)
  if not ok then
    error("timed out waiting for: " .. (msg or "condition"), 2)
  end
end

---Let scheduled callbacks and pending jobs run for `ms` milliseconds.
---@param ms integer
function M.settle(ms)
  vim.wait(ms, function()
    return false
  end, 5)
end

---Record every DiffBaseChanged event. Snapshot values *inside* the callback (assertions thrown there would be
---swallowed by diffbase's pcall around nvim_exec_autocmds).
---@param snap? fun(ev: table): any extra snapshot stored as event.snap
---@return table[] events list of { data = ..., snap = ... }
function M.track_changed(snap)
  local events = {}
  vim.api.nvim_create_autocmd("User", {
    group = test_group,
    pattern = "DiffBaseChanged",
    callback = function(ev)
      local e = { data = ev.data }
      if snap then
        local ok, v = pcall(snap, ev)
        e.snap = ok and v or ("snapshot error: " .. tostring(v))
      end
      events[#events + 1] = e
    end,
  })
  return events
end

---Turn on via `fn` and wait for the resulting DiffBaseChanged.
---@param fn fun(): any
---@return any result of fn
function M.on_and_wait(fn)
  local events = M.track_changed()
  local before = #events
  local r = fn()
  if r == false then
    error("activation returned false; warnings: " .. vim.inspect(M.warnings()), 2)
  end
  M.wait_for(function()
    return #events > before
  end, "DiffBaseChanged")
  return r
end

---Replace vim.ui.select with a fake that picks the item whose formatted text contains `want` (plain).
---`want == nil` cancels. Every call is recorded in the returned list as { prompt, labels, picked }.
---@param want string|string[]|nil labels to pick, in order, one per select call
---@return table[] calls
function M.fake_select(want)
  local queue = type(want) == "table" and vim.deepcopy(want) or { want }
  local calls = {}
  vim.ui.select = function(items, opts, on_choice)
    opts = opts or {}
    local fmt = opts.format_item or tostring
    local labels = {}
    for i, item in ipairs(items) do
      labels[i] = fmt(item)
    end
    local target = table.remove(queue, 1)
    local call = { prompt = opts.prompt, labels = labels }
    calls[#calls + 1] = call
    if target == nil then
      return on_choice(nil, nil)
    end
    for i, label in ipairs(labels) do
      if label:find(target, 1, true) then
        call.picked = label
        return on_choice(items[i], i)
      end
    end
    error(("fake_select: no item matching %q in %s"):format(target, vim.inspect(labels)))
  end
  return calls
end

---------------------------------------------------------------------------------------------------------------
-- Fakes
---------------------------------------------------------------------------------------------------------------

local GS_TOGGLES = {
  toggle_linehl = "linehl",
  toggle_numhl = "numhl",
  toggle_word_diff = "word_diff",
  toggle_deleted = "show_deleted",
}

---Inject a fake `gitsigns` + `gitsigns.config` into package.loaded. Like gitsigns' async API, change_base sets
---the global base at once and calls its callback later (on the next event-loop turn, or `delay_ms` later).
---`overlaps` records toggles called while a change_base was still in flight.
---@param user? table initial config values (linehl, numhl, word_diff, show_deleted, base)
---@return table fake { gs, config, calls, delay_ms, overlaps }
function M.fake_gitsigns(user)
  local cfg = { linehl = false, numhl = false, word_diff = false, show_deleted = false }
  for k, v in pairs(user or {}) do
    cfg[k] = v
  end
  local calls = {}
  local gs = {}
  local fake = { delay_ms = nil, overlaps = {} }
  local in_flight = 0
  function gs.change_base(base, global, cb)
    calls[#calls + 1] = { "change_base", base, global }
    if global then
      cfg.base = base
    end
    in_flight = in_flight + 1
    vim.defer_fn(function()
      in_flight = in_flight - 1
      if type(cb) == "function" then
        cb()
      end
    end, fake.delay_ms or 0)
  end
  function gs.reset_base(global)
    calls[#calls + 1] = { "reset_base", global }
    if global then
      cfg.base = nil
    end
  end
  for fn, key in pairs(GS_TOGGLES) do
    gs[fn] = function(value)
      if value == nil then
        value = not cfg[key]
      end
      calls[#calls + 1] = { fn, value }
      if in_flight > 0 then
        fake.overlaps[#fake.overlaps + 1] = fn
      end
      cfg[key] = value
      return value
    end
  end
  package.loaded["gitsigns"] = gs
  package.loaded["gitsigns.config"] = { config = cfg }
  fake.gs, fake.config, fake.calls = gs, cfg, calls
  return fake
end

---Calls of a given function name recorded by a fake.
---@param calls table[]
---@param name string
---@return table[]
function M.calls_of(calls, name)
  return vim.tbl_filter(function(c)
    return c[1] == name
  end, calls)
end

---Inject a fake neo-tree manager (and optionally neo-tree.git) into package.loaded.
---@param opts? { worktree?: fun(path: string): string|nil, on_refresh?: fun(source: string) }
---@return { states: table<string, table[]>, calls: table[], mgr: table }
function M.fake_neotree(opts)
  opts = opts or {}
  local states = { filesystem = { {} }, git_status = { {} } }
  local calls = {}
  local mgr = {}
  function mgr._for_each_state(source, fn)
    for _, s in ipairs(states[source] or {}) do
      fn(s)
    end
  end
  function mgr.refresh(source)
    calls[#calls + 1] = { "refresh", source }
    if opts.on_refresh then
      opts.on_refresh(source)
    end
  end
  function mgr.redraw(source)
    calls[#calls + 1] = { "redraw", source }
  end
  package.loaded["neo-tree.sources.manager"] = mgr
  if opts.worktree then
    package.loaded["neo-tree.git"] = {
      find_worktree_info = function(path)
        return opts.worktree(path)
      end,
    }
  end
  return { states = states, calls = calls, mgr = mgr }
end

---------------------------------------------------------------------------------------------------------------
-- Assertions
---------------------------------------------------------------------------------------------------------------

---@param expected any
---@param actual any
---@param msg? string
function M.eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    if type(expected) == "table" and type(actual) == "table" then
      local diff = {}
      local keys = vim.tbl_keys(vim.tbl_extend("force", {}, expected, actual))
      table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
      end)
      for _, k in ipairs(keys) do
        if not vim.deep_equal(expected[k], actual[k]) then
          diff[#diff + 1] = ("  [%s] expected %s, got %s"):format(
            tostring(k),
            vim.inspect(expected[k], { newline = " ", indent = "" }),
            vim.inspect(actual[k], { newline = " ", indent = "" })
          )
        end
      end
      error(("%sdiffering keys:\n%s"):format(msg and (msg .. "\n") or "", table.concat(diff, "\n")), 2)
    end
    error(
      ("%sexpected:\n%s\nactual:\n%s"):format(msg and (msg .. "\n") or "", vim.inspect(expected), vim.inspect(actual)),
      2
    )
  end
end

---@param v any
---@param msg? string
function M.ok(v, msg)
  if not v then
    error(msg or "expected truthy value", 2)
  end
end

---@param s string
---@param sub string
---@param msg? string
function M.contains(s, sub, msg)
  if type(s) ~= "string" or not s:find(sub, 1, true) then
    error(("%sexpected %s to contain %s"):format(msg and (msg .. ": ") or "", vim.inspect(s), vim.inspect(sub)), 2)
  end
end

---Assert exactly one warning containing `text` was emitted (with the "diffbase: " prefix).
---@param text string
function M.warned(text)
  local found = M.find_notes(text, vim.log.levels.WARN)
  if #found == 0 then
    error(("expected a warning containing %q; got %s"):format(text, vim.inspect(notes)), 2)
  end
  for _, n in ipairs(found) do
    if not vim.startswith(n.msg, "diffbase: ") then
      error("warning without 'diffbase: ' prefix: " .. n.msg, 2)
    end
  end
end

function M.no_warnings()
  local w = M.warnings()
  if #w > 0 then
    error("unexpected warnings: " .. vim.inspect(w), 2)
  end
end

---Number of diffbase new-file extmarks in a buffer.
---@param buf integer
---@return integer
function M.newfile_marks(buf)
  local ns = vim.api.nvim_create_namespace("diffbase_newfile")
  return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
end

return M
