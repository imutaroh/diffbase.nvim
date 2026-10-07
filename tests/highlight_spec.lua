local h = require("helpers")

local T = {}

local function db()
  return require("diffbase")
end

local function get(g)
  return vim.api.nvim_get_hl(0, { name = g })
end

local function rgb(hex)
  return tonumber(hex:sub(2), 16)
end

---Define a varied set of user highlights for the groups diffbase touches.
local function define_user_groups()
  db().setup() -- diffbase's own default links exist from startup on
  vim.api.nvim_set_hl(0, "MyAdd", { bg = "#001100" })
  vim.api.nvim_set_hl(0, "GitSignsAddLn", { link = "MyAdd" }) -- plain link
  vim.api.nvim_set_hl(0, "GitSignsChangeLn", { link = "DiffChange", default = true }) -- default link
  vim.api.nvim_set_hl(0, "GitSignsDeleteLn", { bg = "#123456", italic = true }) -- colors + attrs
  vim.api.nvim_set_hl(0, "GitSignsAddNr", { fg = "#abcdef", sp = "#010203", underline = true, ctermfg = 2 })
  vim.api.nvim_set_hl(0, "GitSignsDeleteNr", { fg = "#ff0000", default = true }) -- default colors
  -- GitSignsTopdeleteLn etc. stay undefined.
  vim.api.nvim_set_hl(0, "DiffBaseNewLine", { bg = "#222222" }) -- user overrides diffbase's own group
end

local function all_groups()
  local groups = require("diffbase.highlight").groups()
  vim.list_extend(groups, { "DiffBaseNewLine", "DiffBaseNewNr", "MyAdd" })
  return groups
end

local function snapshot()
  local out = {}
  for _, g in ipairs(all_groups()) do
    out[g] = get(g)
  end
  return out
end

local function turn_on(fx)
  h.edit(fx.dir .. "/README.md")
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
end

T["groups() covers the documented GitSigns groups"] = function()
  local groups = require("diffbase.highlight").groups()
  for _, g in ipairs({
    "GitSignsAddLn",
    "GitSignsDeleteLn",
    "GitSignsAddInline",
    "GitSignsDeleteVirtLn",
    "GitSignsAddNr",
  }) do
    h.ok(vim.tbl_contains(groups, g), g)
  end
end

T["own groups default-link to DiffAdd and respect user definitions"] = function()
  vim.api.nvim_set_hl(0, "DiffBaseNewNr", { fg = "#333333" })
  db().setup()
  h.eq({ link = "DiffAdd", default = true }, get("DiffBaseNewLine"))
  h.eq({ fg = rgb("#333333") }, get("DiffBaseNewNr"), "user definition wins over default link")
end

T["round trip: ON paints, OFF restores links, default links, attrs and undefined groups"] = function()
  local fx = h.fixture()
  define_user_groups()
  local before = snapshot()
  h.eq({}, before.GitSignsTopdeleteLn, "precondition: undefined")
  h.eq({ link = "MyAdd" }, before.GitSignsAddLn, "precondition: link")
  h.eq({ link = "DiffChange", default = true }, before.GitSignsChangeLn, "precondition: default link")

  turn_on(fx)
  local p = require("diffbase.config").defaults.colors.dark
  h.eq({ bg = rgb(p.new_line) }, get("GitSignsAddLn"))
  h.eq({ bg = rgb(p.new_line) }, get("GitSignsChangeLn"))
  h.eq({ bg = rgb(p.old_line) }, get("GitSignsDeleteLn"))
  h.eq({ bg = rgb(p.old_line) }, get("GitSignsTopdeleteLn"))
  h.eq({ bg = rgb(p.new_word) }, get("GitSignsAddInline"))
  h.eq({ fg = rgb(p.new_fg), bold = true, cterm = { bold = true } }, get("GitSignsAddNr"))
  h.eq({ fg = rgb(p.old_fg), bold = true, cterm = { bold = true } }, get("GitSignsDeleteNr"))
  h.eq({ bg = rgb(p.new_line) }, get("DiffBaseNewLine"))
  h.eq({ fg = rgb(p.new_fg), bold = true, cterm = { bold = true } }, get("DiffBaseNewNr"))
  h.eq({ bg = rgb("#001100") }, get("MyAdd"), "unrelated groups untouched")

  db().off()
  h.eq(before, snapshot())
end

T["round trip with nothing defined"] = function()
  local fx = h.fixture()
  db().setup()
  local before = snapshot()
  turn_on(fx)
  h.ok(next(get("GitSignsAddLn")) ~= nil, "painted")
  db().off()
  h.eq(before, snapshot())
  h.eq({}, get("GitSignsAddLn"))
  h.eq({ link = "DiffAdd", default = true }, get("DiffBaseNewLine"))
end

T["a plugin's default definition applies after restore of an undefined group"] = function()
  local fx = h.fixture()
  turn_on(fx)
  db().off()
  -- e.g. gitsigns defining its defaults later must not be blocked by a leftover definition
  vim.api.nvim_set_hl(0, "GitSignsAddLn", { link = "DiffAdd", default = true })
  h.eq({ link = "DiffAdd", default = true }, get("GitSignsAddLn"))
end

T["gitsigns set up after ON: its default groups come back on OFF"] = function()
  local fx = h.fixture()
  -- A minimal stand-in for gitsigns.highlight: define a group only when it is not set, with default = true.
  local function setup_highlights()
    local defaults = { GitSignsAddNr = "DiffAdd", GitSignsAddLn = "DiffAdd", GitSignsDeleteVirtLn = "DiffDelete" }
    for g, link in pairs(defaults) do
      if vim.tbl_isempty(get(g)) then
        vim.api.nvim_set_hl(0, g, { link = link, default = true })
      end
    end
  end
  turn_on(fx) -- GitSigns groups are undefined at ON time
  -- gitsigns.setup() runs now (lazy-loaded): ignored, the groups are painted
  package.loaded["gitsigns.highlight"] = { setup_highlights = setup_highlights }
  setup_highlights()
  db().off()
  h.eq({ link = "DiffAdd", default = true }, get("GitSignsAddNr"))
  h.eq({ link = "DiffAdd", default = true }, get("GitSignsAddLn"))
  h.eq({ link = "DiffDelete", default = true }, get("GitSignsDeleteVirtLn"))
end

T["switching bases while ON does not re-snapshot painted colors"] = function()
  local fx = h.fixture()
  define_user_groups()
  local before = snapshot()
  turn_on(fx)
  h.on_and_wait(function()
    return db().set("HEAD~2")
  end)
  db().off()
  h.eq(before, snapshot())
end

T["light palette when background=light"] = function()
  local fx = h.fixture()
  vim.o.background = "light"
  turn_on(fx)
  local p = require("diffbase.config").defaults.colors.light
  h.eq({ bg = rgb(p.new_line) }, get("GitSignsAddLn"))
  h.eq({ bg = rgb(p.old_line) }, get("GitSignsDeleteLn"))
end

T["custom palette"] = function()
  local fx = h.fixture()
  db().setup({ colors = { dark = { new_line = "#010101" } } })
  turn_on(fx)
  h.eq({ bg = rgb("#010101") }, get("GitSignsAddLn"))
  h.eq({ bg = rgb("#010101") }, get("DiffBaseNewLine"))
end

T["an invalid color name warns once and activation still completes"] = function()
  local fx = h.fixture()
  db().setup({ colors = { dark = { new_line = "green-ish" } } })
  h.edit(fx.dir .. "/src/a.txt")
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
  h.eq("Δ previous +5 -2", db().status(), "counts arrive")
  local w = h.warnings()
  h.eq(1, #w, vim.inspect(w))
  h.contains(w[1].msg, "colors.dark.new_line")
  h.contains(w[1].msg, "green-ish")
  h.ok(not w[1].msg:find("highlight.lua", 1, true), "no internal file:line")
  -- The other groups were still painted.
  h.eq({ bg = rgb(require("diffbase.config").defaults.colors.dark.old_line) }, get("GitSignsDeleteLn"))
end

T["an invalid color in the light palette names colors.light.*"] = function()
  local fx = h.fixture()
  vim.o.background = "light"
  db().setup({ colors = { light = { old_fg = "redd" } } })
  h.edit(fx.dir .. "/src/a.txt")
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
  local w = h.warnings()
  h.eq(1, #w, vim.inspect(w))
  h.contains(w[1].msg, "colors.light.old_fg")
  h.contains(w[1].msg, "redd")
end

T["colors = false touches nothing"] = function()
  local fx = h.fixture()
  define_user_groups()
  db().setup({ colors = false })
  local before = snapshot()
  turn_on(fx)
  h.eq(before, snapshot(), "nothing painted")
  db().off()
  h.eq(before, snapshot())

  vim.cmd("highlight clear DiffBaseNewLine")
  db().setup({ colors = false })
  turn_on(fx)
  h.eq({ link = "DiffAdd", default = true }, get("DiffBaseNewLine"))
end

T["ColorScheme while ON: re-snapshot, then re-apply; OFF restores the new scheme's values"] = function()
  local fx = h.fixture()
  define_user_groups()
  turn_on(fx)
  local p = require("diffbase.config").defaults.colors.dark

  -- Simulate a colorscheme: clears everything, then (like gitsigns on ColorScheme) defines its groups.
  local aug = vim.api.nvim_create_augroup("diffbase_test_scheme", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = aug,
    callback = function()
      vim.api.nvim_set_hl(0, "GitSignsAddLn", { bg = "#0a0a0a" })
      vim.api.nvim_set_hl(0, "GitSignsDeleteLn", { link = "DiffDelete", default = true })
    end,
  })
  vim.cmd("colorscheme default")
  h.wait_for(function()
    return vim.deep_equal(get("GitSignsAddLn"), { bg = rgb(p.new_line) })
  end, "palette re-applied after ColorScheme")
  h.eq({ bg = rgb(p.old_line) }, get("GitSignsDeleteLn"))
  local new_line = get("DiffBaseNewLine")
  h.eq({ bg = rgb(p.new_line) }, new_line)

  db().off()
  vim.api.nvim_del_augroup_by_id(aug)
  h.eq({ bg = rgb("#0a0a0a") }, get("GitSignsAddLn"), "restored to the scheme's value, not the pre-ON one")
  h.eq({ link = "DiffDelete", default = true }, get("GitSignsDeleteLn"))
  h.eq({}, get("GitSignsAddNr"), "cleared by the colorscheme, stays cleared")
  h.eq({ link = "DiffAdd", default = true }, get("DiffBaseNewLine"))
end

T["background change and OFF in the same tick restore the user's colors"] = function()
  local fx = h.fixture()
  define_user_groups()
  local before = snapshot()
  turn_on(fx)
  vim.cmd("set background=light | lua require('diffbase').off()")
  h.eq(before, snapshot())
  h.settle(30)
  h.eq(before, snapshot())
end

T["background change while ON: OFF still restores the user's colors"] = function()
  local fx = h.fixture()
  define_user_groups()
  local before = snapshot()
  turn_on(fx)
  vim.o.background = "light"
  local p = require("diffbase.config").defaults.colors.light
  h.wait_for(function()
    return vim.deep_equal(get("GitSignsAddLn"), { bg = rgb(p.new_line) })
  end, "light palette applied")
  db().off()
  h.eq(before, snapshot())
end

T["ColorScheme while OFF does nothing to GitSigns groups"] = function()
  local fx = h.fixture()
  turn_on(fx)
  db().off()
  vim.api.nvim_set_hl(0, "GitSignsAddLn", { bg = "#0b0b0b" })
  vim.cmd("doautocmd ColorScheme")
  h.settle(30)
  h.eq({ bg = rgb("#0b0b0b") }, get("GitSignsAddLn"))
  h.eq({ link = "DiffAdd", default = true }, get("DiffBaseNewLine"))
end

return T
