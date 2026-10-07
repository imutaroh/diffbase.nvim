local util = require("diffbase.util")

local M = {}

---@class diffbase.Palette
---@field new_line string Background of added/changed lines
---@field new_word string Background of changed words on the new side
---@field new_fg string Line-number foreground on the new side
---@field old_line string Background of deleted lines
---@field old_word string Background of changed words on the old side
---@field old_fg string Line-number foreground on the old side

---@class diffbase.Colors
---@field dark diffbase.Palette
---@field light diffbase.Palette

---@class diffbase.RefContext
---@field root string Normalized repository root
---@field default_branch string|nil Detected (or configured) default branch

---@class diffbase.Base
---@field name string Short name, used in `:DiffBase <name>` and status()
---@field label string Menu label
---@field ref string|fun(ctx: diffbase.RefContext): string|nil Git ref; "@default" = the default branch
---@field merge_base? boolean Diff against `git merge-base <ref> HEAD` instead of <ref>

---@class diffbase.GitsignsConfig
---@field enabled boolean
---@field linehl boolean
---@field numhl boolean
---@field word_diff boolean
---@field show_deleted boolean

---@class diffbase.NeotreeConfig
---@field git_base boolean Also set neo-tree's own git base (off by default: see the README's known issues)

---@class diffbase.Stat
---@field added integer
---@field removed integer
---@field binary boolean
---@field new boolean

---@class diffbase.Config
---@field default_branch string|nil Override default-branch detection
---@field bases diffbase.Base[] Menu entries, in order
---@field commit_view boolean Offer "Pick a commit…" and `:DiffBase commit` (detaches HEAD); opt-in
---@field commit_list_limit integer
---@field include_untracked boolean
---@field gitsigns diffbase.GitsignsConfig
---@field neotree diffbase.NeotreeConfig
---@field new_file_highlight boolean
---@field colors diffbase.Colors|false
---@field stat_format nil|fun(stat: diffbase.Stat): string|{ text: string, highlight: string }[]
---@field refresh_events string[]
---@field debounce_ms integer

---@alias diffbase.Opts table Partial diffbase.Config; omitted keys keep their defaults

---@type diffbase.Config
M.defaults = {
  default_branch = nil,
  bases = {
    { name = "main", label = "Changes on this branch (vs default branch)", ref = "@default", merge_base = true },
    { name = "previous", label = "Last commit", ref = "HEAD~1" },
    { name = "unpushed", label = "Not pushed yet", ref = "@{upstream}", merge_base = true },
  },
  commit_view = false,
  commit_list_limit = 20,
  include_untracked = true,
  gitsigns = { enabled = true, linehl = true, numhl = true, word_diff = true, show_deleted = true },
  neotree = { git_base = false },
  new_file_highlight = true,
  -- GitHub-style: new side green, old side red; the stronger shade marks changed words.
  colors = {
    dark = {
      new_line = "#1f3d2b",
      new_word = "#2f6f47",
      new_fg = "#3fb950",
      old_line = "#4a1f27",
      old_word = "#8b2f3c",
      old_fg = "#f85149",
    },
    light = {
      new_line = "#dafbe1",
      new_word = "#aceebb",
      new_fg = "#1a7f37",
      old_line = "#ffebe9",
      old_word = "#ffcecb",
      old_fg = "#cf222e",
    },
  },
  stat_format = nil,
  refresh_events = { "BufWritePost", "FocusGained" },
  debounce_ms = 150,
}

---@type diffbase.Config
M.options = vim.deepcopy(M.defaults)

local PALETTE_KEYS = { "new_line", "new_word", "new_fg", "old_line", "old_word", "old_fg" }

local warned_unknown = false

---@diagnostic disable-next-line: deprecated
local islist = vim.islist or vim.tbl_islist

---@param value any
---@param types string[]
local function type_ok(value, types)
  local t = type(value)
  for _, want in ipairs(types) do
    if t == want or (want == "list" and t == "table" and islist(value)) then
      return true
    end
  end
  return false
end

---Tiny validator (deliberately not vim.validate, whose signature changed across versions).
---@param name string
---@param value any
---@param types string|string[]
---@param optional? boolean
---@return string|nil err
local function check(name, value, types, optional)
  if value == nil and optional then
    return nil
  end
  types = type(types) == "table" and types or { types }
  ---@cast types string[]
  if not type_ok(value, types) then
    return ("%s: expected %s, got %s"):format(name, table.concat(types, "|"), type(value))
  end
  return nil
end

---An integer >= `min` (git and libuv reject fractions; `git log -n 2.5` fails).
---@param name string
---@param value any
---@param min integer
---@return string|nil err
local function check_int(name, value, min)
  if type(value) ~= "number" or value ~= math.floor(value) or value < min or value == math.huge then
    return ("%s: expected an integer >= %d, got %s"):format(name, min, vim.inspect(value))
  end
  return nil
end

---@param c diffbase.Config
---@return string[] errors
local function validate(c)
  local errs = {}
  local function add(e)
    if e then
      errs[#errs + 1] = e
    end
  end
  add(check("default_branch", c.default_branch, "string", true))
  add(check("bases", c.bases, "list"))
  if type(c.bases) == "table" then
    for i, b in ipairs(c.bases) do
      local p = ("bases[%d]"):format(i)
      if type(b) ~= "table" then
        add(p .. ": expected table")
      else
        add(check(p .. ".name", b.name, "string"))
        add(check(p .. ".label", b.label, "string"))
        add(check(p .. ".ref", b.ref, { "string", "function" }))
        add(check(p .. ".merge_base", b.merge_base, "boolean", true))
      end
    end
  end
  add(check("commit_view", c.commit_view, "boolean"))
  add(check_int("commit_list_limit", c.commit_list_limit, 1))
  add(check("include_untracked", c.include_untracked, "boolean"))
  add(check("gitsigns", c.gitsigns, "table"))
  if type(c.gitsigns) == "table" then
    for _, k in ipairs({ "enabled", "linehl", "numhl", "word_diff", "show_deleted" }) do
      add(check("gitsigns." .. k, c.gitsigns[k], "boolean"))
    end
  end
  add(check("neotree", c.neotree, "table"))
  if type(c.neotree) == "table" then
    add(check("neotree.git_base", c.neotree.git_base, "boolean"))
  end
  add(check("new_file_highlight", c.new_file_highlight, "boolean"))
  if c.colors ~= false then
    add(check("colors", c.colors, "table"))
    if type(c.colors) == "table" then
      for _, variant in ipairs({ "dark", "light" }) do
        local pal = c.colors[variant]
        add(check("colors." .. variant, pal, "table"))
        if type(pal) == "table" then
          for _, k in ipairs(PALETTE_KEYS) do
            add(check(("colors.%s.%s"):format(variant, k), pal[k], { "string", "number" }, true))
          end
        end
      end
    end
  end
  add(check("stat_format", c.stat_format, "function", true))
  add(check("refresh_events", c.refresh_events, "list"))
  if type(c.refresh_events) == "table" then
    for i, e in ipairs(c.refresh_events) do
      if type(e) ~= "string" or vim.fn.exists("##" .. e) ~= 1 then
        add(("refresh_events[%d]: unknown event %s"):format(i, vim.inspect(e)))
      end
    end
  end
  add(check_int("debounce_ms", c.debounce_ms, 0))
  return errs
end

---Merge user options over the defaults and validate. Invalid options fall back to the defaults.
---@param opts? diffbase.Opts
---@return diffbase.Config
function M.setup(opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    util.warn("setup() expects a table")
    opts = {}
  end

  if not warned_unknown then
    local unknown = {}
    for k in pairs(opts) do
      if M.defaults[k] == nil and k ~= "default_branch" and k ~= "stat_format" then
        unknown[#unknown + 1] = tostring(k)
      end
    end
    -- Sub-tables with a fixed set of keys (catches e.g. a removed or misspelled `neotree.<key>`).
    for _, sub in ipairs({ "gitsigns", "neotree" }) do
      if type(opts[sub]) == "table" then
        for k in pairs(opts[sub]) do
          if M.defaults[sub][k] == nil then
            unknown[#unknown + 1] = sub .. "." .. tostring(k)
          end
        end
      end
    end
    if #unknown > 0 then
      warned_unknown = true
      table.sort(unknown)
      util.warn("unknown option(s): " .. table.concat(unknown, ", "))
    end
  end

  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- Lists are replaced wholesale, not merged by index.
  if opts.bases ~= nil then
    merged.bases = vim.deepcopy(opts.bases)
  end
  if opts.refresh_events ~= nil then
    merged.refresh_events = vim.deepcopy(opts.refresh_events)
  end
  if opts.colors == false then
    merged.colors = false
  end

  local errs = validate(merged)
  if #errs > 0 then
    util.warn("invalid config, using defaults:\n  " .. table.concat(errs, "\n  "))
    merged = vim.deepcopy(M.defaults)
  end

  M.options = merged
  return merged
end

---Find a configured base by name.
---@param name string
---@return diffbase.Base|nil
function M.base_by_name(name)
  for _, b in ipairs(M.options.bases) do
    if b.name == name then
      return b
    end
  end
  return nil
end

return M
