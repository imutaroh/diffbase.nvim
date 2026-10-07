local h = require("helpers")

local T = {}

T["defaults apply without setup()"] = function()
  local config = require("diffbase.config")
  require("diffbase").setup()
  h.eq(config.defaults, config.options)
  h.eq(false, config.options.commit_view, "commit view is opt-in")
  h.eq(
    { "main", "previous", "unpushed" },
    vim.tbl_map(function(b)
      return b.name
    end, config.options.bases)
  )
  h.no_warnings()
end

T["nested tables merge, lists replace"] = function()
  local config = require("diffbase.config")
  require("diffbase").setup({
    gitsigns = { numhl = false },
    bases = { { name = "dev", label = "vs dev", ref = "dev" } },
    refresh_events = { "BufWritePost" },
    colors = { dark = { new_line = "#000001" } },
  })
  local o = config.options
  h.eq({ enabled = true, linehl = true, numhl = false, word_diff = true, show_deleted = true }, o.gitsigns)
  h.eq({ git_base = false }, o.neotree, "neo-tree's git base is opt-in")
  h.eq({ { name = "dev", label = "vs dev", ref = "dev" } }, o.bases)
  h.eq({ "BufWritePost" }, o.refresh_events)
  h.eq("#000001", o.colors.dark.new_line)
  h.eq(config.defaults.colors.dark.new_word, o.colors.dark.new_word, "partial palette keeps other keys")
  h.eq(config.defaults.colors.light, o.colors.light)
  -- defaults were not mutated
  h.eq("main", config.defaults.bases[1].name)
  h.eq(true, config.defaults.gitsigns.numhl)
  h.no_warnings()
end

T["colors = false is kept"] = function()
  require("diffbase").setup({ colors = false })
  h.eq(false, require("diffbase.config").options.colors)
  h.no_warnings()
end

T["unknown options warn once"] = function()
  local d = require("diffbase")
  d.setup({ bogus = 1, zzz = true })
  d.setup({ bogus = 2 })
  local w = h.find_notes("unknown option", vim.log.levels.WARN)
  h.eq(1, #w, "warned exactly once")
  h.contains(w[1].msg, "bogus, zzz")
  h.warned("unknown option")
end

T["unknown keys inside gitsigns / neotree are reported with their path"] = function()
  require("diffbase").setup({ neotree = { enabled = true }, gitsigns = { linehl = false, bogus = 1 } })
  local w = h.find_notes("unknown option", vim.log.levels.WARN)
  h.eq(1, #w)
  h.contains(w[1].msg, "gitsigns.bogus, neotree.enabled")
  h.eq(false, require("diffbase.config").options.neotree.git_base, "the old key does not turn it on")
  h.warned("unknown option")
end

T["neotree.git_base must be a boolean"] = function()
  require("diffbase").setup({ neotree = { git_base = "yes" } })
  h.warned("neotree.git_base")
  h.eq(false, require("diffbase.config").options.neotree.git_base)
end

T["invalid options fall back to defaults with one warning listing every error"] = function()
  local config = require("diffbase.config")
  require("diffbase").setup({
    debounce_ms = "x",
    gitsigns = { linehl = "yes" },
    bases = { { name = "n", label = 3, ref = "HEAD" } },
  })
  h.eq(config.defaults, config.options)
  local w = h.warnings()
  h.eq(1, #w)
  h.contains(w[1].msg, "debounce_ms")
  h.contains(w[1].msg, "gitsigns.linehl")
  h.contains(w[1].msg, "bases[1].label")
  h.warned("invalid config")
end

T["commit_list_limit and debounce_ms must be integers in range"] = function()
  local config = require("diffbase.config")
  for _, bad in ipairs({
    { commit_list_limit = 2.5 },
    { commit_list_limit = 0 },
    { commit_list_limit = -1 },
    { commit_list_limit = math.huge },
    { debounce_ms = 1.5 },
    { debounce_ms = -1 },
  }) do
    h.clear_notes()
    require("diffbase").setup(bad)
    local key = next(bad)
    h.eq(config.defaults[key], config.options[key], vim.inspect(bad))
    h.warned(key .. ": expected an integer")
  end
  h.clear_notes()
  require("diffbase").setup({ commit_list_limit = 1, debounce_ms = 0 })
  h.no_warnings()
  h.eq(1, config.options.commit_list_limit)
  h.eq(0, config.options.debounce_ms)
end

T["palette values of the wrong type are rejected by setup()"] = function()
  local config = require("diffbase.config")
  require("diffbase").setup({ colors = { dark = { new_line = true }, light = { old_fg = {} } } })
  h.eq(config.defaults, config.options)
  local w = h.warnings()
  h.eq(1, #w)
  h.contains(w[1].msg, "colors.dark.new_line")
  h.contains(w[1].msg, "colors.light.old_fg")
end

T["function refs and optional keys validate"] = function()
  local config = require("diffbase.config")
  local fn = function()
    return "HEAD"
  end
  require("diffbase").setup({
    default_branch = "develop",
    bases = { { name = "f", label = "fn", ref = fn, merge_base = true } },
    stat_format = function()
      return ""
    end,
  })
  h.no_warnings()
  h.eq("develop", config.options.default_branch)
  h.eq(fn, config.options.bases[1].ref)
  h.eq(true, config.base_by_name("f").merge_base)
  h.eq(nil, config.base_by_name("main"))
end

T["a misspelled refresh event is rejected; setup() still creates every autocmd"] = function()
  local config = require("diffbase.config")
  local ok, err = pcall(require("diffbase").setup, { refresh_events = { "BufWritePost", "FocusGaind" } })
  h.ok(ok, tostring(err))
  h.warned('refresh_events[2]: unknown event "FocusGaind"')
  h.eq(config.defaults.refresh_events, config.options.refresh_events)
  h.eq(1, #vim.api.nvim_get_autocmds({ group = "diffbase", event = "ColorScheme" }))
  h.eq(0, #vim.api.nvim_get_autocmds({ group = "diffbase", event = "VimLeavePre" }), "nothing runs at quit")
end

T["non-table setup argument warns"] = function()
  require("diffbase").setup("nope")
  h.warned("setup() expects a table")
  h.eq(require("diffbase.config").defaults, require("diffbase.config").options)
end

return T
