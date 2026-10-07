---@brief
--- diffbase.nvim: choose what to diff against (default branch, previous commit, unpushed work, any single
--- commit) and see it in your normal editing view: line/word highlights via gitsigns, new-file highlights,
--- and +added -removed counts in neo-tree.

local config = require("diffbase.config")
local util = require("diffbase.util")
local git = require("diffbase.git")

local M = {}

---@class diffbase.ReturnTarget
---@field root string
---@field ref string branch name or sha
---@field detach boolean
---@field sha string the viewed commit HEAD is detached at

---@class diffbase.State
---@field base string|nil sha (or tree for a root commit) being diffed against
---@field label string|nil long label (menu text)
---@field name string|nil short name for status()
---@field root string|nil normalized repository root
---@field files table<string, diffbase.Stat>
---@field dirs table<string, diffbase.Stat>
---@field gen integer generation counter; bumped on every state change to drop stale async results
---@field return_to diffbase.ReturnTarget|nil set while in commit view
---@field need_full boolean the base changed and neo-tree has not been given it yet (consumed by the next
---current compute result, whichever compute started it)
local state = {
  base = nil,
  label = nil,
  name = nil,
  root = nil,
  files = {},
  dirs = {},
  gen = 0,
  return_to = nil,
  need_full = false,
}

local initialized = false
local augroup

---Deferred re-snapshot + re-paint after a colorscheme or 'background' change while ON. Deferred so other
---ColorScheme handlers (e.g. gitsigns) re-define their groups before the snapshot.
local function schedule_resnapshot()
  if not state.base then
    return
  end
  vim.schedule(function()
    if state.base then
      require("diffbase.highlight").on_colorscheme(config.options.colors)
    end
  end)
end

local function gitsigns()
  return require("diffbase.integrations.gitsigns")
end

local function neotree()
  return require("diffbase.integrations.neotree")
end

---Stats entry for a path: the path itself first (a tracked symlink has its own entry), then its target.
---A path that changed between file and directory has both a (deleted) file entry and a directory entry;
---whatever is on disk now wins.
---@param path string
---@return diffbase.Stat|nil
local function lookup(path)
  for _, key in ipairs(util.lookup_keys(path)) do
    local f, d = state.files[key], state.dirs[key]
    if f and d then
      local st = (vim.uv or vim.loop).fs_stat(key)
      return st and st.type == "directory" and d or f
    end
    local s = f or d
    if s then
      return s
    end
  end
  return nil
end

---@param path string
---@return boolean
local function is_new(path)
  for _, key in ipairs(util.lookup_keys(path)) do
    local s = state.files[key]
    if s then
      return s.new
    end
  end
  return false
end

local function fire_changed()
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "DiffBaseChanged", modeline = false, data = M.get() })
end

---Start an async stats computation; results land only if still current. A pending neo-tree base change
---(state.need_full) is applied by whichever compute result lands, so a refresh that supersedes the first
---compute does not drop it.
local function compute()
  if not state.base or not state.root then
    return
  end
  state.gen = state.gen + 1
  local gen, root, base = state.gen, state.root, state.base
  local opts = config.options
  -- In commit view the working tree's untracked files are not part of the viewed commit.
  local include_untracked = opts.include_untracked and not state.return_to
  local function is_current()
    return gen == state.gen and state.base == base and state.root == root
  end
  git.compute(root, base, include_untracked, is_current, function(result, err)
    if not is_current() then
      return -- stale
    end
    if not result then
      util.warn("git diff failed: " .. (err or "unknown error"))
      result = { files = {}, dirs = {} }
    end
    util.clear_norm_cache()
    state.files, state.dirs = result.files, result.dirs
    local full = state.need_full
    state.need_full = false
    if opts.neotree.git_base then
      if full then
        neotree().set_base(root, base)
      end
      neotree().refresh(full)
    else
      -- The component reads the stats; only redraw (never touches neo-tree's git base).
      neotree().refresh(false)
    end
    if opts.new_file_highlight then
      require("diffbase.newfile").mark_all(is_new)
    end
    fire_changed()
  end)
end

local debounced = util.debouncer(function()
  compute()
end)

local function create_autocmds()
  augroup = vim.api.nvim_create_augroup("diffbase", { clear = true })
  local opts = config.options

  if #opts.refresh_events > 0 then
    vim.api.nvim_create_autocmd(opts.refresh_events, {
      group = augroup,
      callback = function()
        if state.base then
          debounced.call(config.options.debounce_ms)
        end
      end,
    })
  end

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "TextChanged", "TextChangedI" }, {
    group = augroup,
    callback = function(ev)
      if state.base and config.options.new_file_highlight then
        require("diffbase.newfile").mark(ev.buf, is_new, false)
      end
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = function()
      require("diffbase.highlight").define_defaults()
      schedule_resnapshot()
    end,
  })

  vim.api.nvim_create_autocmd("OptionSet", {
    group = augroup,
    pattern = "background",
    callback = schedule_resnapshot,
  })

  -- neo-tree opened after diffbase was turned on: give it the base too.
  vim.api.nvim_create_autocmd("FileType", {
    group = augroup,
    pattern = "neo-tree",
    callback = function()
      if state.base and config.options.neotree.git_base then
        vim.schedule(function()
          -- Only refresh when the base actually had to be set: avoids a refresh -> FileType -> refresh loop.
          if state.base and neotree().set_base(state.root, state.base) then
            neotree().refresh(true)
          end
        end)
      end
    end,
  })
end

local function ensure_init()
  if not initialized then
    M.setup()
  end
end

---Configure diffbase. Optional: everything works with defaults.
---@param opts? diffbase.Opts
function M.setup(opts)
  config.setup(opts)
  initialized = true
  require("diffbase.highlight").define_defaults()
  create_autocmds()
end

---@return string|nil root
local function current_root()
  local root = git.root(util.buf_dir())
  if not root then
    util.warn("not inside a git repository")
  end
  return root
end

---Turn on (or switch) the diff base.
---@param root string
---@param base string
---@param label string
---@param name string
local function activate(root, base, label, name)
  local opts = config.options
  local was_on = state.base ~= nil
  if was_on and state.root and state.root ~= root and opts.neotree.git_base then
    neotree().set_base(nil, nil)
  end
  debounced.cancel()
  state.base, state.root, state.label, state.name = base, root, label, name
  state.files, state.dirs = {}, {}
  state.need_full = true
  -- gitsigns first: requiring it may define its highlight groups, which the snapshot below must see.
  gitsigns().enable(base, opts.gitsigns)
  if opts.colors then
    require("diffbase.highlight").apply(opts.colors)
  end
  compute()
  util.notify("diffing against " .. label)
end

---@param ref string|fun(ctx: diffbase.RefContext): string|nil
---@param root string
---@return string|nil ref
---@return string|nil err
local function expand_ref(ref, root)
  local opts = config.options
  if type(ref) == "function" then
    local ok, r = pcall(ref, {
      root = root,
      default_branch = git.default_branch(root, opts.default_branch),
    })
    if not ok then
      return nil, "ref function failed: " .. tostring(r)
    end
    if type(r) ~= "string" or r == "" then
      return nil, "ref function returned no ref"
    end
    ref = r
  end
  if ref == "@default" then
    local db = git.default_branch(root, opts.default_branch)
    if not db then
      return nil, "could not detect the default branch (set `default_branch`)"
    end
    return db
  end
  return ref
end

local same_root_as_commit_view -- defined below, after current_return_to()

---@class diffbase.SetOpts
---@field merge_base? boolean diff against `git merge-base <ref> HEAD`
---@field label? string label shown in notifications and the menu (defaults to the ref; "@default" and a
---function ref default to the resolved ref; a ref equal to a configured base name to "ref:<ref>")
---@field name? string short name for status() (defaults like `label`)

---Show the diff against an arbitrary ref.
---@param ref string|fun(ctx: diffbase.RefContext): string|nil
---@param opts? diffbase.SetOpts
---@return boolean ok
function M.set(ref, opts)
  ensure_init()
  opts = opts or {}
  if ref == nil or ref == "" then
    util.warn("set(): ref is required")
    return false
  end
  local root = current_root()
  if not root then
    return false
  end
  if not same_root_as_commit_view(root) then
    return false
  end
  local expanded, err = expand_ref(ref, root)
  if not expanded then
    util.warn(err or "invalid ref")
    return false
  end
  local sha, rerr = git.resolve(root, expanded, opts.merge_base)
  if not sha and expanded:find("@{u", 1, true) then
    rerr = git.upstream_problem(root)
  end
  if not sha then
    util.warn(rerr or ("'%s' not found"):format(expanded))
    return false
  end
  -- A function ref and "@default" show what they resolved to. A ref spelled like a configured base name (e.g.
  -- `:DiffBase ref main` vs the `main` preset, which diffs against a merge-base) is shown as "ref:<ref>".
  local shown = (type(ref) == "string" and ref ~= "@default") and ref or expanded
  if config.base_by_name(shown) then
    shown = "ref:" .. shown
  end
  activate(root, sha, opts.label or shown, opts.name or shown)
  return true
end

---Show the diff against a configured base by name ("main", "previous", "unpushed", ...).
---@param name string
---@return boolean ok
function M.set_preset(name)
  ensure_init()
  local b = config.base_by_name(name)
  if not b then
    util.warn(("unknown base '%s'"):format(tostring(name)))
    return false
  end
  return M.set(b.ref, { merge_base = b.merge_base, label = b.label, name = b.name })
end

---Turn diffbase off: restore gitsigns, highlights and neo-tree. Does not leave commit view (see back()).
function M.off()
  ensure_init()
  debounced.cancel()
  state.gen = state.gen + 1
  local was_on = state.base ~= nil
  local root = state.root
  state.base, state.label, state.name = nil, nil, nil
  state.files, state.dirs = {}, {}
  state.need_full = false
  if not state.return_to then
    state.root = nil
  end
  if not was_on then
    return
  end
  gitsigns().disable()
  require("diffbase.highlight").restore()
  require("diffbase.newfile").clear_all()
  if config.options.neotree.git_base then
    neotree().set_base(root, nil)
    neotree().refresh(true)
  else
    neotree().refresh(false) -- clear the counts shown by the component
  end
  fire_changed()
  util.notify("off")
end

---Recompute stats now (debounced).
function M.refresh()
  ensure_init()
  if state.base then
    debounced.call(config.options.debounce_ms)
  end
end

---Loaded file buffers inside `root` with unsaved changes (relative names). Switching commits under them would
---leave the buffer showing the old content plus the edit, and writing it would dirty the detached tree.
---@param root string
---@return string[]
local function unsaved_in(root)
  local out = {}
  local prefix = root == "/" and "/" or (root .. "/")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and vim.bo[buf].modified then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        local p = util.norm(name)
        if vim.startswith(p, prefix) then
          out[#out + 1] = p:sub(#prefix + 1)
        end
      end
    end
  end
  table.sort(out)
  return out
end

---Turn off once commit view ended (state.return_to already cleared).
local function turn_off_after_commit_view()
  local was_on = state.base ~= nil
  M.off()
  if not was_on then
    state.root = nil
    fire_changed() -- off() was a no-op, but status() changed (no longer detached)
  end
end

---The commit-view return target, but only while HEAD is still detached at the viewed commit. When HEAD moved
---outside nvim (e.g. `git switch` in a terminal), commit view is over: forget the target, so nothing switches
---the user away from where they are now, and turn off (the base was the viewed commit's parent).
---@return diffbase.ReturnTarget|nil
local function current_return_to()
  local rt = state.return_to
  if not rt then
    return nil
  end
  if git.line(rt.root, { "rev-parse", "HEAD" }) == rt.sha and not git.current_branch(rt.root) then
    return rt
  end
  state.return_to = nil
  util.warn(("HEAD moved away from the viewed commit %s; left commit view without switching"):format(rt.sha:sub(1, 7)))
  turn_off_after_commit_view()
  return nil
end

---While commit view is active in one repository, diffbase works only there: the base, the stats (which leave
---out untracked files in commit view) and `back` all belong to that repository. Warns and returns false when
---`root` is another one.
---@param root string
---@return boolean ok
function same_root_as_commit_view(root)
  local rt = current_return_to()
  if rt and rt.root ~= root then
    util.warn(("still in commit view in %s; run :DiffBase back there first"):format(rt.root))
    return false
  end
  return true
end

---Reasons commit view cannot start in `root` right now (warns and returns false), else true.
---@param root string
---@return boolean ok
local function can_view_commit(root)
  if not same_root_as_commit_view(root) then
    return false
  end
  if git.is_dirty(root) then
    util.warn("uncommitted changes to tracked files; commit or stash them before viewing a commit")
    return false
  end
  local unsaved = unsaved_in(root)
  if #unsaved > 0 then
    util.warn(
      ("unsaved changes in %s; write or discard them before viewing a commit"):format(table.concat(unsaved, ", "))
    )
    return false
  end
  return true
end

---Pick a commit and view only what it changed (detaches HEAD at that commit, diffs against its parent).
function M.view_commit()
  ensure_init()
  if not config.options.commit_view then
    util.warn("commit view is disabled; enable it with setup({ commit_view = true })")
    return
  end
  local root = current_root()
  if not root then
    return
  end
  if not can_view_commit(root) then
    return
  end
  local db = git.default_branch(root, config.options.default_branch)
  -- Already in commit view: HEAD is the detached commit, so list from where `back` returns to.
  local rt = state.return_to
  local tip = rt and rt.root == root and rt.ref or nil
  local commits = git.commits(root, db, config.options.commit_list_limit, tip)
  if #commits == 0 then
    util.warn("no commits to show")
    return
  end
  vim.ui.select(commits, {
    prompt = "View changes of commit:",
    format_item = function(item)
      return item.text
    end,
  }, function(choice)
    if not choice then
      return
    end
    M._open_commit(root, choice.sha, choice.text)
  end)
end

---Detach at `sha` and diff against its parent. Exposed for tests and custom pickers.
---@param root string
---@param sha string
---@param text? string
---@return boolean ok
function M._open_commit(root, sha, text)
  ensure_init()
  if not can_view_commit(root) then
    return false
  end
  local return_to = state.return_to
  if not return_to then
    local branch = git.current_branch(root)
    if branch then
      return_to = { root = root, ref = branch, detach = false }
    else
      local head = git.line(root, { "rev-parse", "HEAD" })
      if not head then
        util.warn("could not determine the current HEAD")
        return false
      end
      return_to = { root = root, ref = head, detach = true }
    end
  end
  local ok, err = git.switch(root, sha, true)
  if not ok then
    util.warn("could not switch to commit: " .. (err or ""))
    return false
  end
  return_to.sha = git.line(root, { "rev-parse", "HEAD" }) or sha
  state.return_to = return_to
  pcall(vim.cmd.checktime)
  local parent = git.parent(root, sha)
  local short = sha:sub(1, 7)
  activate(root, parent, "commit " .. (text or short), "commit " .. short)
  return true
end

---Leave commit view: switch back to where you were and turn diffbase off.
---@return boolean ok
function M.back()
  ensure_init()
  if not state.return_to then
    util.warn("not in commit view")
    return false
  end
  local rt = current_return_to()
  if not rt then
    return false
  end
  if git.is_dirty(rt.root) then
    util.warn("files were changed while viewing a commit; clean them up before going back")
    return false
  end
  local unsaved = unsaved_in(rt.root)
  if #unsaved > 0 then
    util.warn(("unsaved changes in %s; write or discard them before going back"):format(table.concat(unsaved, ", ")))
    return false
  end
  local ok, err = git.switch(rt.root, rt.ref, rt.detach)
  if not ok then
    util.warn(("could not switch back to '%s': %s"):format(rt.ref, err or ""))
    return false
  end
  state.return_to = nil
  pcall(vim.cmd.checktime)
  util.notify("back on " .. rt.ref)
  turn_off_after_commit_view()
  return true
end

---Menu: [back], each configured base, "Pick a commit…", "Off" (only while a base is set).
function M.pick()
  ensure_init()
  local items = {}
  if state.return_to then
    items[#items + 1] = {
      label = ("Back to %s"):format(state.return_to.detach and state.return_to.ref:sub(1, 7) or state.return_to.ref),
      action = M.back,
    }
  end
  for _, b in ipairs(config.options.bases) do
    items[#items + 1] = {
      label = b.label,
      current = state.name == b.name,
      action = function()
        M.set_preset(b.name)
      end,
    }
  end
  if config.options.commit_view then
    items[#items + 1] = { label = "Pick a commit…", action = M.view_commit }
  end
  if state.base then
    items[#items + 1] = { label = "Off", action = M.off }
  end
  vim.ui.select(items, {
    prompt = "Diff against:",
    format_item = function(item)
      return (item.current and "● " or "  ") .. item.label
    end,
  }, function(item)
    if item then
      item.action()
    end
  end)
end

---@class diffbase.Info
---@field base string|nil
---@field label string|nil
---@field name string|nil
---@field root string|nil
---@field detached_from string|nil branch (or sha) to return to while in commit view

---Current state.
---@return diffbase.Info
function M.get()
  return {
    base = state.base,
    label = state.label,
    name = state.name,
    root = state.root,
    detached_from = state.return_to and state.return_to.ref or nil,
  }
end

---Line stats for a file or directory (directories are aggregated). nil when off or unchanged.
---@param path? string defaults to the current buffer
---@return diffbase.Stat|nil
function M.stats(path)
  if not state.base then
    return nil
  end
  if path == nil or path == "" then
    path = vim.api.nvim_buf_get_name(0)
    if path == "" then
      return nil
    end
  end
  local s = lookup(path)
  if not s then
    return nil
  end
  return { added = s.added, removed = s.removed, binary = s.binary, new = s.new }
end

---Statusline string: "" when off, e.g. "Δ main +120 -34", "Δ commit abc1234 +3 -1", "Δ detached abc1234".
---@return string
function M.status()
  if state.base then
    local total = state.root and state.dirs[state.root]
    local s = "Δ " .. (state.name or "?")
    if total then
      s = s .. (" +%d -%d"):format(total.added, total.removed)
    end
    return s
  end
  if state.return_to then
    local rt = state.return_to
    return "Δ detached (from " .. (rt.detach and rt.ref:sub(1, 7) or rt.ref) .. ")"
  end
  return ""
end

---Names available as `:DiffBase <name>`.
---@return string[]
function M._subcommands()
  local subs = { "pick" }
  for _, b in ipairs(config.options.bases) do
    subs[#subs + 1] = b.name
  end
  vim.list_extend(subs, { "commit", "back", "off", "refresh", "ref" })
  return subs
end

---Entry point for :DiffBase.
---@param args string[]
function M._command(args)
  ensure_init()
  local sub = args[1]
  if not sub or sub == "" or sub == "pick" then
    return M.pick()
  elseif sub == "ref" then
    if not args[2] then
      return util.warn("usage: :DiffBase ref <git-ref>")
    end
    return M.set(args[2])
  elseif sub == "commit" then
    return M.view_commit()
  elseif sub == "back" then
    return M.back()
  elseif sub == "off" then
    return M.off()
  elseif sub == "refresh" then
    return M.refresh()
  elseif config.base_by_name(sub) then
    return M.set_preset(sub)
  end
  util.warn(("unknown subcommand '%s'"):format(sub))
end

---@private
---@return diffbase.State
function M._state()
  return state
end

return M
