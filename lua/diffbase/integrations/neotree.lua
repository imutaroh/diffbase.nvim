-- neo-tree.nvim integration: provides a "diffbase" renderer component showing "+added -removed" next to files
-- and directories, and (only with `neotree.git_base = true`) sets neo-tree's git base so its M/A markers use
-- the same base.
local M = {}

-- Sources whose git base diffbase sets and which it refreshes.
local SOURCES = { "filesystem", "git_status" }

-- Built-in sources that render with the global `renderers` unless they define their own; each needs the
-- "diffbase" component registered, or neo-tree renders "Component diffbase not found." in every row.
local COMPONENT_SOURCES = { "filesystem", "buffers", "git_status", "document_symbols" }

-- Values that were in each neo-tree state before diffbase first wrote to it, restored on OFF.
-- state -> { keys = { [worktree key] = previous value or NONE }, git_base = previous value or NONE }
local NONE = {}
---@type table<table, { keys: table<string, any>, git_base: any }>
local saved = setmetatable({}, { __mode = "k" })

---@return table|nil
local function manager()
  local ok, mgr = pcall(require, "neo-tree.sources.manager")
  if ok and type(mgr) == "table" then
    return mgr
  end
  return nil
end

---@param mgr table
---@param source string
---@param fn fun(state: table)
local function for_each_state(mgr, source, fn)
  if type(mgr._for_each_state) == "function" then
    pcall(mgr._for_each_state, source, function(state)
      pcall(fn, state)
    end)
  end
end

-- neo-tree normalizes worktree roots its own way; ask it for the key and fall back to ours.
---@type table<string, string>
local key_cache = {}

---@param root string
---@return string[]
local function worktree_keys(root)
  local keys = { root }
  local key = key_cache[root]
  if key == nil then
    local ok, git = pcall(require, "neo-tree.git")
    if ok and type(git) == "table" and type(git.find_worktree_info) == "function" then
      local ok2, wt = pcall(git.find_worktree_info, root)
      if ok2 and type(wt) == "string" then
        key = wt
      end
    end
    key_cache[root] = key or root
    key = key_cache[root]
  end
  if key ~= root then
    keys[#keys + 1] = key
  end
  return keys
end

-- neo-tree builds before 6679b93 (fix(git): use correct argument order for git_base callback, #2072; first
-- release 3.42.0) pass
-- the coroutine's success flag as the diff status when a git base is set, and every tree row then renders a
-- Lua error ("attempt to index local 'git_status' (a boolean value)"). Detect that exact callback shape in
-- the loaded neo-tree source; anything else (fixed, refactored, unreadable) counts as supported.
local BROKEN_GIT_BASE_PATTERN = "name_status_job%(%s*worktree_root%s*,%s*base%s*,%s*false%s*,%s*ctx%s*,"
  .. "%s*function%s*%(%s*status%s*%)"

---@param text string contents of neo-tree's lua/neo-tree/git/init.lua
---@return boolean broken
function M._source_has_broken_git_base(text)
  return text:find(BROKEN_GIT_BASE_PATTERN) ~= nil
end

---@type boolean|nil
local supported_cache = nil
local warned_unsupported = false

---Whether the loaded neo-tree can use a git base without breaking its git_status component. nil when
---neo-tree's git module is not loadable (nothing to check). Private: used by setup and :checkhealth.
---@private
---@return boolean|nil
function M._git_base_supported()
  if supported_cache ~= nil then
    return supported_cache
  end
  local ok, ngit = pcall(require, "neo-tree.git")
  if not ok or type(ngit) ~= "table" then
    return nil
  end
  local result = true
  if type(ngit.status_async) == "function" then
    local info = debug.getinfo(ngit.status_async, "S")
    local src = info and info.source
    if type(src) == "string" and src:sub(1, 1) == "@" then
      local f = io.open(src:sub(2), "rb")
      if f then
        local text = f:read("*a") or ""
        f:close()
        result = not M._source_has_broken_git_base(text)
      end
    end
  end
  supported_cache = result
  return result
end

---@private
function M._reset_probe()
  supported_cache = nil
  warned_unsupported = false
end

---@param state table
---@return { keys: table<string, any>, git_base: any }
local function snapshot(state)
  local snap = saved[state]
  if not snap then
    local git_base = state.git_base
    if git_base == nil then
      git_base = NONE
    end
    snap = { keys = {}, git_base = git_base }
    saved[state] = snap
  end
  return snap
end

---Set (base ~= nil) or clear (base == nil) neo-tree's git base for `root`. Clearing restores whatever the
---state held before diffbase first wrote to it (e.g. a user's `:Neotree git_base=main`).
---@param root string|nil
---@param base string|nil
---@return boolean changed whether any neo-tree state was modified
function M.set_base(root, base)
  local mgr = manager()
  if not mgr then
    return false
  end
  if base and root and M._git_base_supported() == false then
    if not warned_unsupported then
      warned_unsupported = true
      require("diffbase.util").warn(
        "neo-tree.nvim is too old to use a git base (update it to 3.42.0 or newer, commit 6679b93); "
          .. "its git markers keep showing HEAD, the +/- counts still work"
      )
    end
    return false
  end
  local changed = false
  for _, source in ipairs(SOURCES) do
    for_each_state(mgr, source, function(state)
      if base and root then
        local snap = snapshot(state)
        state.git_base_by_worktree = state.git_base_by_worktree or {}
        for _, key in ipairs(worktree_keys(root)) do
          if snap.keys[key] == nil then
            local prev = state.git_base_by_worktree[key]
            if prev == nil then
              prev = NONE
            end
            snap.keys[key] = prev
          end
          if state.git_base_by_worktree[key] ~= base then
            state.git_base_by_worktree[key] = base
            changed = true
          end
        end
        if state.git_base ~= base then
          state.git_base = base -- older neo-tree versions
          changed = true
        end
      else
        local snap = saved[state]
        if not snap then
          return
        end
        saved[state] = nil
        if type(state.git_base_by_worktree) == "table" then
          for key, prev in pairs(snap.keys) do
            if prev == NONE then
              prev = nil
            end
            if state.git_base_by_worktree[key] ~= prev then
              state.git_base_by_worktree[key] = prev
              changed = true
            end
          end
        end
        local prev_base = snap.git_base
        if prev_base == NONE then
          prev_base = nil
        end
        if state.git_base ~= prev_base then
          state.git_base = prev_base
          changed = true
        end
      end
    end)
  end
  return changed
end

---Refresh (re-read git status) the git-base sources when `full`, and redraw every source that shows the
---component (all of them when not `full`). A redraw never loads neo-tree.
---@param full boolean
function M.refresh(full)
  local mgr
  if full then
    mgr = manager()
  else
    mgr = package.loaded["neo-tree.sources.manager"]
  end
  if type(mgr) ~= "table" then
    return
  end
  for _, source in ipairs(COMPONENT_SOURCES) do
    local fn = mgr.redraw
    if full and vim.tbl_contains(SOURCES, source) then
      fn = mgr.refresh
    end
    if type(fn) == "function" then
      pcall(fn, source)
    end
  end
end

---@param stat diffbase.Stat
---@return { text: string, highlight: string }[]
local function default_format(stat)
  if stat.binary then
    return { { text = " bin", highlight = "NeoTreeDimText" } }
  end
  return {
    { text = " +" .. stat.added, highlight = "NeoTreeGitAdded" },
    { text = " -" .. stat.removed, highlight = "NeoTreeGitDeleted" },
  }
end

---neo-tree renderer component. Register it as "diffbase" (see setup_opts).
---@param _ table component config
---@param node table neo-tree node
---@param _state table neo-tree state
---@return { text: string, highlight: string }[]
function M.component(_, node, _state)
  local ok, result = pcall(function()
    local diffbase = require("diffbase")
    local path = node and (node.path or (node.get_id and node:get_id()))
    if type(path) ~= "string" then
      return {}
    end
    local stat = diffbase.stats(path)
    if not stat then
      return {}
    end
    local fmt = require("diffbase.config").options.stat_format
    if fmt then
      local r = fmt(stat)
      if type(r) == "string" then
        return r == "" and {} or { { text = r, highlight = "NeoTreeDimText" } }
      end
      return type(r) == "table" and r or {}
    end
    return default_format(stat)
  end)
  return ok and result or {}
end

---@param content table[]
local function insert_component(content)
  for _, item in ipairs(content) do
    if item[1] == "diffbase" then
      return
    end
  end
  local pos = 1
  for i, item in ipairs(content) do
    if item[1] == "name" then
      pos = i
      break
    end
  end
  table.insert(content, pos + 1, { "diffbase", zindex = 10 })
end

---@param renderers table|nil
local function patch_renderers(renderers)
  if type(renderers) ~= "table" then
    return
  end
  for _, kind in ipairs({ "file", "directory" }) do
    local list = renderers[kind]
    if type(list) == "table" then
      for _, part in ipairs(list) do
        if type(part) == "table" and part[1] == "container" and type(part.content) == "table" then
          insert_component(part.content)
        end
      end
    end
  end
end

---Patch neo-tree opts (lazy.nvim `opts = function(_, opts) ... end`): registers the "diffbase" component for
---every built-in source (filesystem, buffers, git_status, document_symbols) and every source named in
---`opts.sources`, and inserts it right after "name" in the file/directory containers. Idempotent.
---@param opts table neo-tree setup opts (mutated)
---@return table opts
function M.setup_opts(opts)
  opts = opts or {}
  local sources = vim.deepcopy(COMPONENT_SOURCES)
  if type(opts.sources) == "table" then
    for _, name in ipairs(opts.sources) do
      -- External sources are given as module paths ("netman.ui.neo-tree"); their config key differs.
      if type(name) == "string" and not name:find(".", 1, true) and not vim.tbl_contains(sources, name) then
        sources[#sources + 1] = name
      end
    end
  end
  for _, source in ipairs(sources) do
    opts[source] = opts[source] or {}
    opts[source].components = opts[source].components or {}
    opts[source].components.diffbase = M.component
    -- Source-specific renderers, if the user has them.
    patch_renderers(opts[source].renderers)
  end

  opts.renderers = opts.renderers or {}
  if opts.renderers.file == nil or opts.renderers.directory == nil then
    local ok, defaults = pcall(require, "neo-tree.defaults")
    if ok and type(defaults) == "table" and type(defaults.renderers) == "table" then
      for _, kind in ipairs({ "file", "directory" }) do
        if opts.renderers[kind] == nil and defaults.renderers[kind] then
          opts.renderers[kind] = vim.deepcopy(defaults.renderers[kind])
        end
      end
    end
  end
  patch_renderers(opts.renderers)
  return opts
end

return M
