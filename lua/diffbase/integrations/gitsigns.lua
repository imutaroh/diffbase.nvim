-- gitsigns.nvim integration (v1 and v2). Snapshots the user's toggles and global base when diffbase turns ON
-- and restores them when it turns OFF. A buffer-local base (`:Gitsigns change_base` without global) is not
-- kept: the global change_base resets it.
local M = {}

local FLAGS = {
  linehl = "toggle_linehl",
  numhl = "toggle_numhl",
  word_diff = "toggle_word_diff",
  show_deleted = "toggle_deleted",
}

---@class diffbase.GitsignsSnapshot
---@field flags table<string, boolean>
---@field base string|nil

-- The user's state, taken at ON. Kept until OFF has finished restoring it, so an ON that supersedes a
-- pending OFF reuses it instead of snapshotting diffbase's own toggles.
---@type diffbase.GitsignsSnapshot|nil
local saved = nil

-- diffbase is ON for gitsigns.
local active = false

-- Bumped by every enable() / disable(): the change_base callback of a superseded call does nothing.
local gen = 0

---@return table|nil
local function gitsigns()
  local ok, gs = pcall(require, "gitsigns")
  if ok and type(gs) == "table" then
    return gs
  end
  return nil
end

---@return table|nil
local function gs_config()
  local ok, cfg = pcall(function()
    return require("gitsigns.config").config
  end)
  if ok and type(cfg) == "table" then
    return cfg
  end
  return nil
end

---@return boolean
function M.available()
  return gitsigns() ~= nil
end

---@param gs table
---@param flags table<string, boolean>
local function apply_flags(gs, flags)
  for flag, value in pairs(flags) do
    local fn = gs[FLAGS[flag]]
    if type(fn) == "function" then
      pcall(fn, value)
    end
  end
end

---Set the global base, then run `cb` once gitsigns has finished (unless another enable() / disable() started
---meanwhile). The toggles refresh every buffer; started while change_base is still updating them, gitsigns
---ends up diffing against the previous base, so they go in `cb`.
---@param gs table
---@param base string|nil nil: gitsigns' default (the index)
---@param cb fun()
local function change_base(gs, base, cb)
  gen = gen + 1
  local my = gen
  local function done()
    if my == gen then
      cb()
    end
  end
  -- reset_base() takes no callback, so the default base is restored with change_base(nil).
  if not pcall(gs.change_base, base, true, vim.schedule_wrap(done)) then
    done()
  end
end

---Point gitsigns at `base` for all buffers and enable the configured toggles.
---@param base string
---@param opts diffbase.GitsignsConfig
function M.enable(base, opts)
  if not opts.enabled then
    return
  end
  local gs = gitsigns()
  if not gs then
    return
  end
  if not saved then
    local cfg = gs_config() or {}
    saved = { flags = {}, base = cfg.base }
    for flag in pairs(FLAGS) do
      if opts[flag] then
        saved.flags[flag] = cfg[flag] == true
      end
    end
  end
  active = true
  local on = {}
  for flag in pairs(FLAGS) do
    if opts[flag] then
      on[flag] = true
    end
  end
  change_base(gs, base, function()
    apply_flags(gs, on)
  end)
end

---Restore the user's global base, then their toggles.
function M.disable()
  if not active then
    return
  end
  active = false
  local snap = saved
  local gs = gitsigns()
  if not gs or not snap then
    saved = nil
    return
  end
  change_base(gs, snap.base, function()
    saved = nil
    apply_flags(gs, snap.flags)
  end)
end

---@return boolean
function M.is_active()
  return active
end

return M
