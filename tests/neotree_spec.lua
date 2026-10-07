local h = require("helpers")

local T = {}

local function db()
  return require("diffbase")
end

local function nt()
  return require("diffbase.integrations.neotree")
end

local function on(fx, fn)
  h.edit(fx.dir .. "/README.md")
  h.on_and_wait(fn or function()
    return db().set_preset("previous")
  end)
end

-- Opt in to neo-tree's own git base (off by default).
local function with_git_base(extra)
  db().setup(vim.tbl_extend("force", { neotree = { git_base = true } }, extra or {}))
end

-- What M.refresh(full) / M.refresh(false) asks of neo-tree's manager.
local FULL = {
  { "refresh", "filesystem" },
  { "redraw", "buffers" },
  { "refresh", "git_status" },
  { "redraw", "document_symbols" },
}
local REDRAWS =
  { { "redraw", "filesystem" }, { "redraw", "buffers" }, { "redraw", "git_status" }, { "redraw", "document_symbols" } }

local function container(content)
  return { { "indent" }, { "icon" }, { "container", content = content } }
end

local function names(content)
  return vim.tbl_map(function(c)
    return c[1]
  end, content)
end

---------------------------------------------------------------------------------------------------------------
-- component
---------------------------------------------------------------------------------------------------------------

T["component: counts, binary, directories, nothing when off"] = function()
  local fx = h.fixture()
  local d = fx.dir
  h.eq({}, nt().component({}, { path = d .. "/src/a.txt" }, {}), "off")
  on(fx)
  h.eq({
    { text = " +0", highlight = "NeoTreeGitAdded" },
    { text = " -2", highlight = "NeoTreeGitDeleted" },
  }, nt().component({}, { path = d .. "/src/a.txt" }, {}))
  h.eq({
    { text = " +2", highlight = "NeoTreeGitAdded" },
    { text = " -2", highlight = "NeoTreeGitDeleted" },
  }, nt().component({}, { path = d .. "/src" }, {}))
  h.eq({ { text = " bin", highlight = "NeoTreeDimText" } }, nt().component({}, { path = d .. "/blob.bin" }, {}))
  h.eq({}, nt().component({}, { path = d .. "/src/b.txt" }, {}), "unchanged")
  -- node without .path but with get_id()
  local node = {
    get_id = function()
      return d .. "/untracked.txt"
    end,
  }
  h.eq(" +3", nt().component({}, node, {})[1].text)
  h.eq({}, nt().component({}, {}, {}))
  h.eq({}, nt().component({}, nil, {}))
end

T["component: stat_format string, chunks, errors"] = function()
  local fx = h.fixture()
  db().setup({
    stat_format = function(s)
      if s.binary then
        return ""
      end
      return ("[%d/%d]"):format(s.added, s.removed)
    end,
  })
  on(fx)
  h.eq({ { text = "[0/2]", highlight = "NeoTreeDimText" } }, nt().component({}, { path = fx.dir .. "/src/a.txt" }, {}))
  h.eq({}, nt().component({}, { path = fx.dir .. "/blob.bin" }, {}))

  require("diffbase.config").options.stat_format = function()
    return { { text = "X", highlight = "Title" } }
  end
  h.eq({ { text = "X", highlight = "Title" } }, nt().component({}, { path = fx.dir .. "/src/a.txt" }, {}))

  require("diffbase.config").options.stat_format = function()
    error("bad formatter")
  end
  h.eq({}, nt().component({}, { path = fx.dir .. "/src/a.txt" }, {}), "formatter errors are contained")
end

---------------------------------------------------------------------------------------------------------------
-- setup_opts
---------------------------------------------------------------------------------------------------------------

T["setup_opts: patches user renderers after name, idempotent"] = function()
  local opts = {
    renderers = {
      file = container({ { "name" }, { "symlink_target" }, { "git_status" } }),
      directory = container({ { "name" }, { "git_status" } }),
    },
    filesystem = { renderers = { file = container({ { "icon" }, { "name" }, { "diagnostics" } }) } },
  }
  local r = nt().setup_opts(opts)
  h.ok(r == opts, "returns the same table")
  nt().setup_opts(opts)
  h.eq({ "name", "diffbase", "symlink_target", "git_status" }, names(opts.renderers.file[3].content))
  h.eq({ "name", "diffbase", "git_status" }, names(opts.renderers.directory[3].content))
  h.eq({ "icon", "name", "diffbase", "diagnostics" }, names(opts.filesystem.renderers.file[3].content))
  h.eq({ "diffbase", zindex = 10 }, opts.renderers.file[3].content[2])
  h.eq(nt().component, opts.filesystem.components.diffbase)
  h.eq(nt().component, opts.git_status.components.diffbase)
end

T["setup_opts: every source that inherits the global renderers gets the component"] = function()
  -- neo-tree's buffers source renders with the global renderers too; without the component registered there,
  -- every row shows "Neo-tree: Component diffbase not found."
  local opts = nt().setup_opts({
    sources = { "filesystem", "buffers", "git_status", "my_source", "netman.ui.neo-tree" },
    buffers = { components = { other = print } },
  })
  for _, source in ipairs({ "filesystem", "buffers", "git_status", "document_symbols", "my_source" }) do
    h.eq(nt().component, opts[source].components.diffbase, source)
  end
  h.eq(print, opts.buffers.components.other, "user components kept")
  h.eq(nil, opts["netman.ui.neo-tree"], "module-path sources are not configured by that key")
end

T["setup_opts: no renderers -> deep copy of neo-tree defaults, defaults untouched"] = function()
  local defaults = {
    renderers = {
      file = container({ { "name", use_git_status_colors = true }, { "git_status" } }),
      directory = container({ { "name" } }),
      message = { { "indent" } },
    },
  }
  local pristine = vim.deepcopy(defaults)
  package.loaded["neo-tree.defaults"] = defaults
  local opts = nt().setup_opts({})
  nt().setup_opts(opts)
  h.eq(pristine, defaults, "neo-tree defaults not mutated")
  h.eq({ "name", "diffbase", "git_status" }, names(opts.renderers.file[3].content))
  h.eq({ "name", "diffbase" }, names(opts.renderers.directory[3].content))
  h.eq(nil, opts.renderers.message, "only file/directory are copied")
  h.ok(opts.renderers.file ~= defaults.renderers.file)
end

T["setup_opts: partial renderers keep the user's and copy the missing kind"] = function()
  package.loaded["neo-tree.defaults"] =
    { renderers = { file = container({ { "name" } }), directory = container({ { "name" } }) } }
  local mine = container({ { "name" }, { "custom" } })
  local opts = nt().setup_opts({ renderers = { file = mine } })
  h.ok(opts.renderers.file == mine)
  h.eq({ "name", "diffbase", "custom" }, names(mine[3].content))
  h.eq({ "name", "diffbase" }, names(opts.renderers.directory[3].content))
end

T["setup_opts: no container or no name"] = function()
  local opts = nt().setup_opts({
    renderers = { file = { { "name" } }, directory = container({ { "icon" } }) },
  })
  h.eq({ { "name" } }, opts.renderers.file, "renderer without a container is left alone")
  h.eq({ "icon", "diffbase" }, names(opts.renderers.directory[3].content))
  h.eq(nt().setup_opts(nil).filesystem.components.diffbase, nt().component)
end

---------------------------------------------------------------------------------------------------------------
-- git base + refresh
---------------------------------------------------------------------------------------------------------------

T["ON sets git_base_by_worktree (+ legacy), OFF restores the previous values"] = function()
  with_git_base()
  local fx = h.fixture()
  local fake = h.fake_neotree()
  fake.states.filesystem[1].git_base_by_worktree = { ["/other/repo"] = "abc" }
  on(fx)
  for _, source in ipairs({ "filesystem", "git_status" }) do
    local s = fake.states[source][1]
    h.eq(fx.second, s.git_base_by_worktree[fx.dir], source)
    h.eq(fx.second, s.git_base, source .. " legacy")
  end
  h.eq(FULL, fake.calls)

  db().off()
  for _, source in ipairs({ "filesystem", "git_status" }) do
    local s = fake.states[source][1]
    h.eq(nil, s.git_base_by_worktree[fx.dir], source)
    h.eq(nil, s.git_base, source .. " legacy restored (was unset)")
  end
  h.eq("abc", fake.states.filesystem[1].git_base_by_worktree["/other/repo"], "other worktrees untouched")
  h.eq(FULL, vim.list_slice(fake.calls, #fake.calls - #FULL + 1), "OFF refreshes, and redraws the other sources")
end

T["OFF restores the user's own neo-tree git base"] = function()
  with_git_base()
  local fx = h.fixture()
  local fake = h.fake_neotree()
  for _, source in ipairs({ "filesystem", "git_status" }) do
    -- e.g. after `:Neotree git_base=main`
    fake.states[source][1].git_base_by_worktree = { [fx.dir] = "main" }
    fake.states[source][1].git_base = "main"
  end
  on(fx)
  h.eq(fx.second, fake.states.filesystem[1].git_base_by_worktree[fx.dir])
  -- switching bases while ON keeps the first snapshot
  h.on_and_wait(function()
    return db().set("HEAD")
  end)
  h.eq(fx.feat, fake.states.filesystem[1].git_base_by_worktree[fx.dir])
  db().off()
  for _, source in ipairs({ "filesystem", "git_status" }) do
    local s = fake.states[source][1]
    h.eq({ [fx.dir] = "main" }, s.git_base_by_worktree, source)
    h.eq("main", s.git_base, source)
  end
end

T["a refresh racing the first compute still gives neo-tree the new base"] = function()
  local fx = h.fixture()
  with_git_base({ debounce_ms = 0 })
  local fake = h.fake_neotree()
  h.edit(fx.dir .. "/README.md")
  local events = h.track_changed()
  h.eq(true, db().set_preset("previous"))
  -- Supersedes the first compute before it finishes (FocusGained / BufWritePost right after switching).
  db().refresh()
  h.wait_for(function()
    return #events > 0
  end, "DiffBaseChanged")
  h.settle(50)
  for _, source in ipairs({ "filesystem", "git_status" }) do
    h.eq(fx.second, fake.states[source][1].git_base_by_worktree[fx.dir], source)
  end
  h.ok(#h.calls_of(fake.calls, "refresh") >= 2, "full refresh happened: " .. vim.inspect(fake.calls))
  -- consumed once: a later stats refresh only redraws
  local n = #fake.calls
  db().refresh()
  h.wait_for(function()
    return #fake.calls > n
  end, "redraw")
  h.settle(50)
  h.eq(0, #h.calls_of(vim.list_slice(fake.calls, n + 1), "refresh"))
end

T["worktree key from neo-tree's find_worktree_info is used too"] = function()
  with_git_base()
  local fx = h.fixture()
  local asked = {}
  local fake = h.fake_neotree({
    worktree = function(p)
      asked[#asked + 1] = p
      return "/neo/key"
    end,
  })
  on(fx)
  local s = fake.states.git_status[1]
  h.eq(fx.second, s.git_base_by_worktree[fx.dir])
  h.eq(fx.second, s.git_base_by_worktree["/neo/key"])
  h.eq({ fx.dir }, asked, "asked once (cached)")
  db().off()
  h.eq({}, s.git_base_by_worktree)
end

T["refresh happens after stats are populated"] = function()
  with_git_base()
  local fx = h.fixture()
  local seen = {}
  h.fake_neotree({
    on_refresh = function(source)
      seen[#seen + 1] = { source, require("diffbase").stats(fx.dir .. "/src/c.txt") }
    end,
  })
  h.edit(fx.dir .. "/README.md")
  h.eq(true, db().set_preset("previous"))
  h.eq({}, seen, "no refresh right after dispatch")
  h.wait_for(function()
    return #seen == 2
  end, "refresh")
  local stat = { added = 2, removed = 0, binary = false, new = true }
  h.eq({ { "filesystem", stat }, { "git_status", stat } }, seen)
end

T["stats refresh without a base change only redraws"] = function()
  with_git_base()
  local fx = h.fixture()
  local fake = h.fake_neotree()
  on(fx)
  local n = #fake.calls
  local events = h.track_changed()
  db().refresh()
  h.wait_for(function()
    return #events > 0
  end)
  h.eq(REDRAWS, vim.list_slice(fake.calls, n + 1))
end

T["default (git_base = false): never sets the git base, but redraws so the counts follow"] = function()
  local fx = h.fixture()
  local fake = h.fake_neotree()
  on(fx)
  h.eq(REDRAWS, fake.calls, "redraw after ON")
  db().off()
  h.eq(vim.list_extend(vim.deepcopy(REDRAWS), REDRAWS), fake.calls, "redraw after OFF clears the counts")
  h.eq(nil, fake.states.filesystem[1].git_base_by_worktree)
  h.eq(nil, fake.states.filesystem[1].git_base)
end

T["OFF redraws the buffers source too, so its counts clear"] = function()
  local fx = h.fixture()
  local fake = h.fake_neotree()
  fake.states.buffers = { {} }
  on(fx)
  local n = #fake.calls
  db().off()
  h.ok(
    vim.tbl_contains(vim.list_slice(fake.calls, n + 1), function(c)
      return vim.deep_equal(c, { "redraw", "buffers" })
    end, { predicate = true }),
    "buffers redrawn on OFF: " .. vim.inspect(fake.calls)
  )
end

T["a redraw never loads neo-tree"] = function()
  local fx = h.fixture()
  local required = {}
  table.insert(package.loaders or package.searchers, 2, function(name)
    if name:match("^neo%-tree") then
      required[#required + 1] = name
    end
  end)
  local ok, err = pcall(function()
    on(fx)
    db().off()
  end)
  table.remove(package.loaders or package.searchers, 2)
  assert(ok, err)
  h.eq({}, required)
end

---------------------------------------------------------------------------------------------------------------
-- neo-tree too old for git_base_by_worktree
---------------------------------------------------------------------------------------------------------------

local BROKEN_SNIPPET = [[
          if base then
            git_diff.name_status_job(worktree_root, base, false, ctx, function(status)
              change_worktree_git_status(worktree_root, ctx.git_status, base, status)
]]

local FIXED_SNIPPET = [[
          if base then
            git_diff.name_status_job(worktree_root, base, false, ctx, function(ok, status)
              if ok then
]]

---Install a fake neo-tree.git whose status_async is defined in a file containing `snippet`.
---@param snippet string
local function fake_neotree_git(snippet)
  local file = h.path("neo-tree-git.lua")
  -- The snippet is only scanned as text; keep it inside a comment so the file still loads.
  h.write(file, "--[==[\n" .. snippet .. "]==]\nlocal M = {}\nfunction M.status_async() end\nreturn M\n")
  package.loaded["neo-tree.git"] = dofile(file)
end

T["git base probe: broken and fixed neo-tree sources"] = function()
  h.eq(true, nt()._source_has_broken_git_base(BROKEN_SNIPPET))
  h.eq(false, nt()._source_has_broken_git_base(FIXED_SNIPPET))
  h.eq(false, nt()._source_has_broken_git_base(""))
  fake_neotree_git(FIXED_SNIPPET)
  h.eq(true, nt()._git_base_supported())
  nt()._reset_probe()
  fake_neotree_git(BROKEN_SNIPPET)
  h.eq(false, nt()._git_base_supported())
  nt()._reset_probe()
  package.loaded["neo-tree.git"] = { status_async = print } -- not a Lua file: assume supported
  h.eq(true, nt()._git_base_supported())
end

T["neo-tree too old: skips the git base, warns once, still refreshes counts"] = function()
  with_git_base()
  local fx = h.fixture()
  local fake = h.fake_neotree()
  fake_neotree_git(BROKEN_SNIPPET)
  on(fx)
  h.eq(nil, fake.states.filesystem[1].git_base_by_worktree)
  h.eq(nil, fake.states.filesystem[1].git_base)
  h.ok(#fake.calls > 0, "neo-tree still refreshed")
  h.warned("too old to use a git base")
  h.on_and_wait(function()
    return db().set("HEAD")
  end)
  h.eq(1, #h.find_notes("too old", vim.log.levels.WARN), "warned once")
  db().off()
  h.eq(nil, fake.states.filesystem[1].git_base_by_worktree)
end

T["FileType neo-tree applies the base once, without a refresh loop"] = function()
  with_git_base()
  local fx = h.fixture()
  on(fx)
  -- neo-tree is loaded after diffbase was turned on
  local fake = h.fake_neotree()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "neo-tree"
  h.settle(30)
  h.eq(fx.second, fake.states.filesystem[1].git_base_by_worktree[fx.dir])
  h.eq(FULL, fake.calls)
  -- a re-render setting the filetype again must not refresh again
  vim.bo[buf].filetype = "neo-tree"
  vim.bo[buf].filetype = "neo-tree"
  h.settle(30)
  h.eq(#FULL, #fake.calls)
end

T["FileType neo-tree with the default git_base = false does nothing"] = function()
  local fx = h.fixture()
  on(fx)
  local fake = h.fake_neotree()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "neo-tree"
  h.settle(30)
  h.eq({}, fake.calls)
  h.eq(nil, fake.states.filesystem[1].git_base_by_worktree)
end

T["FileType neo-tree while OFF does nothing"] = function()
  h.fixture()
  with_git_base()
  local fake = h.fake_neotree()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "neo-tree"
  h.settle(30)
  h.eq({}, fake.calls)
end

T["switching repositories clears the old worktree entry"] = function()
  with_git_base()
  local a = h.fixture()
  local b = h.fixture({ untracked = false })
  local fake = h.fake_neotree()
  on(a)
  on(b)
  local s = fake.states.filesystem[1]
  h.eq(nil, s.git_base_by_worktree[a.dir])
  h.eq(b.second, s.git_base_by_worktree[b.dir])
  db().off()
  h.eq({}, s.git_base_by_worktree)
end

T["a broken neo-tree manager does not break diffbase"] = function()
  with_git_base()
  local fx = h.fixture()
  local fake = h.fake_neotree()
  fake.mgr._for_each_state = function()
    error("boom")
  end
  fake.mgr.refresh = function()
    error("boom")
  end
  on(fx)
  db().off()
  h.no_warnings()
end

return T
