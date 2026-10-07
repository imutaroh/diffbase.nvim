-- Palette handling. While diffbase is ON, the GitSigns* groups it touches are snapshotted, painted with the
-- palette, and restored exactly on OFF. diffbase's own groups are always defined (with `default = true`).
local M = {}

---@type table<string, string[]> palette key -> GitSigns groups (group name suffixes)
local GROUPS = {
  new_line = { "AddLn", "ChangeLn", "ChangedeleteLn", "UntrackedLn" },
  new_word = { "AddLnInline", "ChangeLnInline", "AddInline", "ChangeInline", "AddVirtLnInline", "ChangeVirtLnInline" },
  old_line = { "DeleteLn", "TopdeleteLn", "DeleteVirtLn" },
  old_word = { "DeleteLnInline", "DeleteInline", "DeleteVirtLnInline", "DeleteVirtLnInLine" },
  new_fg = { "AddNr", "ChangeNr", "ChangedeleteNr", "UntrackedNr" },
  old_fg = { "DeleteNr", "TopdeleteNr" },
}

---All GitSigns groups this module may touch.
---@return string[]
function M.groups()
  local out = {}
  for _, suffixes in pairs(GROUPS) do
    for _, s in ipairs(suffixes) do
      out[#out + 1] = "GitSigns" .. s
    end
  end
  table.sort(out)
  return out
end

---@type table<string, table>|nil
local saved = nil

-- What each group looked like right after we painted it; lets a re-snapshot tell "someone redefined this
-- group" apart from "this is still our own paint".
---@type table<string, table>
local painted = {}

---@param colors diffbase.Colors|false
---@return diffbase.Palette|nil
function M.palette(colors)
  if not colors then
    return nil
  end
  return vim.o.background == "light" and colors.light or colors.dark
end

-- Palette values already reported as invalid (one warning per value, not per paint).
local warned_bad = {}

---Set a group; a bad color value (e.g. a misspelled name) is reported once instead of aborting the paint.
---@param group string
---@param spec table
---@param key string option path of the value ("dark.new_line"), for the warning
---@param value any
local function set_hl(group, spec, key, value)
  local ok, err = pcall(vim.api.nvim_set_hl, 0, group, spec)
  if not ok then
    local id = key .. "=" .. tostring(value)
    if not warned_bad[id] then
      warned_bad[id] = true
      -- Drop the "file:line: " prefix of the Lua error.
      local msg = tostring(err):gsub("^.-:%d+: ", "")
      require("diffbase.util").warn(("invalid color colors.%s = %s: %s"):format(key, vim.inspect(value), msg))
    end
  end
end

---@param p diffbase.Palette
local function paint(p)
  local variant = vim.o.background == "light" and "light" or "dark" -- the palette M.palette() picked
  for key, suffixes in pairs(GROUPS) do
    local spec
    if key == "new_fg" or key == "old_fg" then
      spec = { fg = p[key], bold = true }
    else
      spec = { bg = p[key] }
    end
    for _, s in ipairs(suffixes) do
      set_hl("GitSigns" .. s, spec, variant .. "." .. key, p[key])
    end
  end
  set_hl("DiffBaseNewLine", { bg = p.new_line }, variant .. ".new_line", p.new_line)
  set_hl("DiffBaseNewNr", { fg = p.new_fg, bold = true }, variant .. ".new_fg", p.new_fg)
  painted = {}
  for g in pairs(saved or {}) do
    painted[g] = vim.api.nvim_get_hl(0, { name = g })
  end
end

---Define diffbase's own groups if the user/colorscheme has not.
function M.define_defaults()
  -- Links resolve at draw time; when the palette is active these are painted directly instead.
  vim.api.nvim_set_hl(0, "DiffBaseNewLine", { link = "DiffAdd", default = true })
  vim.api.nvim_set_hl(0, "DiffBaseNewNr", { link = "DiffAdd", default = true })
end

---Save the current definitions. On a re-snapshot (ColorScheme / 'background' change while ON), a group that
---still carries our paint was not redefined, so its previously saved definition is kept: saving our own
---palette would make OFF "restore" the palette.
local function snapshot()
  local prev = saved
  local names = M.groups()
  vim.list_extend(names, { "DiffBaseNewLine", "DiffBaseNewNr" })
  saved = {}
  for _, g in ipairs(names) do
    local cur = vim.api.nvim_get_hl(0, { name = g })
    if prev and painted[g] and vim.deep_equal(cur, painted[g]) then
      saved[g] = prev[g]
    else
      saved[g] = cur
    end
  end
end

---Snapshot (only if not already active) and apply the palette.
---@param colors diffbase.Colors|false
function M.apply(colors)
  local p = M.palette(colors)
  if not p then
    return
  end
  if not saved then
    snapshot()
  end
  paint(p)
end

---On ColorScheme while ON: the colorscheme defined new base colors, so re-snapshot first, then re-apply.
---@param colors diffbase.Colors|false
function M.on_colorscheme(colors)
  M.define_defaults()
  local p = M.palette(colors)
  if not p or not saved then
    return
  end
  snapshot()
  paint(p)
end

---Restore the snapshotted definitions.
function M.restore()
  if not saved then
    return
  end
  local cleared = false
  for g, def in pairs(saved) do
    -- Clear first: a saved `default = true` definition is ignored by nvim_set_hl while the group is set,
    -- and an undefined group must stay undefined (so plugins can still apply their own defaults later).
    pcall(vim.cmd, "highlight clear " .. g)
    if next(def) ~= nil then
      pcall(vim.api.nvim_set_hl, 0, g, def)
    elseif vim.startswith(g, "GitSigns") then
      cleared = true
    end
  end
  saved = nil
  painted = {}
  M.define_defaults()
  -- A GitSigns group that was undefined when diffbase turned ON may have received gitsigns' `default = true`
  -- definition while ON (gitsigns.setup() ran later, e.g. lazy-loaded); nvim ignored it because the group was
  -- painted, and clearing it above dropped it. Let gitsigns derive its defaults again (only if it is loaded).
  if cleared then
    local gs_hl = package.loaded["gitsigns.highlight"]
    if type(gs_hl) == "table" and type(gs_hl.setup_highlights) == "function" then
      pcall(gs_hl.setup_highlights)
    end
  end
end

---@return boolean
function M.is_applied()
  return saved ~= nil
end

return M
