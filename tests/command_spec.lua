local h = require("helpers")

local T = {}

local function db()
  return require("diffbase")
end

local function cmd_and_wait(c)
  local events = h.track_changed()
  vim.cmd(c)
  h.wait_for(function()
    return #events > 0
  end, "DiffBaseChanged after " .. c)
end

T[":DiffBase command exists without requiring diffbase at startup"] = function()
  h.eq(2, vim.fn.exists(":DiffBase"))
  h.eq(nil, package.loaded["diffbase"])
end

T[":DiffBase <preset> / ref / off"] = function()
  local fx = h.fixture()
  h.edit(fx.dir .. "/README.md")
  cmd_and_wait("DiffBase previous")
  h.eq("Δ previous +5 -2", db().status())
  cmd_and_wait("DiffBase ref HEAD~2")
  h.eq(fx.init, db().get().base)
  h.eq("Δ HEAD~2 +7 -3", db().status())
  cmd_and_wait("DiffBase main")
  h.eq(fx.second, db().get().base)
  cmd_and_wait("DiffBase off")
  h.eq("", db().status())
  h.no_warnings()
end

T[":DiffBase works with | (bar)"] = function()
  local fx = h.fixture()
  h.edit(fx.dir .. "/README.md")
  cmd_and_wait("DiffBase previous")
  cmd_and_wait("DiffBase off | DiffBase ref HEAD~2")
  h.eq(fx.init, db().get().base)
  vim.cmd("DiffBase off | let g:diffbase_after_bar = 1")
  h.eq(1, vim.g.diffbase_after_bar)
  h.eq(nil, db().get().base)
  vim.g.diffbase_after_bar = nil
  h.no_warnings()
end

T[":DiffBase refresh recomputes"] = function()
  local fx = h.fixture()
  h.edit(fx.dir .. "/README.md")
  cmd_and_wait("DiffBase previous")
  h.write(fx.dir .. "/README.md", { "readme", "more" })
  cmd_and_wait("DiffBase refresh")
  h.eq({ added = 1, removed = 0, binary = false, new = false }, db().stats())
end

T[":DiffBase errors are warnings"] = function()
  local fx = h.fixture()
  h.edit(fx.dir .. "/README.md")
  vim.cmd("DiffBase ref")
  h.warned("usage: :DiffBase ref <git-ref>")
  vim.cmd("DiffBase bogus")
  h.warned("unknown subcommand 'bogus'")
  vim.cmd("DiffBase ref nope")
  h.warned("'nope' not found")
  vim.cmd("DiffBase back")
  h.warned("not in commit view")
  h.eq(nil, db().get().base)
end

T[":DiffBase and :DiffBase pick open the menu"] = function()
  local fx = h.fixture()
  h.edit(fx.dir .. "/README.md")
  local calls = h.fake_select({ nil })
  vim.cmd("DiffBase")
  h.eq("Diff against:", calls[1].prompt)
  h.eq({
    "  Changes on this branch (vs default branch)",
    "  Last commit",
    "  Not pushed yet",
  }, calls[1].labels, "commit view is opt-in: no Pick a commit…")

  calls = h.fake_select("Last commit")
  local events = h.track_changed()
  vim.cmd("DiffBase pick")
  h.wait_for(function()
    return #events > 0
  end, "DiffBaseChanged")
  h.eq("previous", db().get().name)

  -- Current base is marked, and "Off" is offered.
  calls = h.fake_select("Off")
  vim.cmd("DiffBase")
  h.eq({
    "  Changes on this branch (vs default branch)",
    "● Last commit",
    "  Not pushed yet",
    "  Off",
  }, calls[1].labels)
  h.eq(nil, db().get().base)
end

T[":DiffBase commit is off by default and says how to enable it"] = function()
  local fx = h.fixture()
  h.edit(fx.dir .. "/README.md")
  local calls = h.fake_select("feat")
  vim.cmd("DiffBase commit")
  h.eq(0, #calls, "no picker")
  h.warned("commit view is disabled; enable it with setup({ commit_view = true })")
  h.eq("feature", h.git(fx.dir, "branch", "--show-current"))
  h.eq(nil, db().get().base)
end

T[":DiffBase pick offers Pick a commit… when commit_view = true"] = function()
  local fx = h.fixture()
  db().setup({ commit_view = true })
  h.edit(fx.dir .. "/README.md")
  local calls = h.fake_select({ nil })
  vim.cmd("DiffBase")
  h.eq("  Pick a commit…", calls[1].labels[#calls[1].labels])
end

T["completion: subcommands"] = function()
  local fx = h.fixture()
  vim.cmd.cd(vim.fn.fnameescape(fx.dir))
  h.eq(
    { "pick", "main", "previous", "unpushed", "commit", "back", "off", "refresh", "ref" },
    vim.fn.getcompletion("DiffBase ", "cmdline")
  )
  h.eq({ "pick", "previous" }, vim.fn.getcompletion("DiffBase p", "cmdline"))
  h.eq({}, vim.fn.getcompletion("DiffBase off ", "cmdline"))
end

T["completion: custom bases"] = function()
  db().setup({ bases = { { name = "dev", label = "Dev", ref = "dev" } } })
  h.eq({ "pick", "dev", "commit", "back", "off", "refresh", "ref" }, vim.fn.getcompletion("DiffBase ", "cmdline"))
end

T["completion: refs after `ref`"] = function()
  local fx = h.fixture({ origin = true })
  h.git(fx.dir, "tag", "v1.0", fx.init)
  vim.cmd.cd(vim.fn.fnameescape(fx.dir))
  local all = vim.fn.getcompletion("DiffBase ref ", "cmdline")
  h.eq("HEAD", all[1])
  for _, want in ipairs({ "main", "feature", "origin/main", "v1.0" }) do
    h.ok(vim.tbl_contains(all, want), want .. " in " .. vim.inspect(all))
  end
  h.eq({ "feature" }, vim.fn.getcompletion("DiffBase ref fe", "cmdline"))
  h.eq({}, vim.fn.getcompletion("DiffBase ref main ", "cmdline"))
end

T["completion: command modifiers do not shift the arguments"] = function()
  local fx = h.fixture({ origin = true })
  vim.cmd.cd(vim.fn.fnameescape(fx.dir))
  local subs = { "pick", "main", "previous", "unpushed", "commit", "back", "off", "refresh", "ref" }
  h.eq(subs, vim.fn.getcompletion("silent DiffBase ", "cmdline"))
  h.eq(subs, vim.fn.getcompletion("vert DiffBase ", "cmdline"))
  if vim.fn.has("nvim-0.11") == 1 then
    -- Neovim 0.10 does not complete user commands after `keepalt` at all.
    h.eq(subs, vim.fn.getcompletion("silent! keepalt DiffBase ", "cmdline"))
  end
  h.eq({ "pick", "previous" }, vim.fn.getcompletion("silent DiffBase p", "cmdline"))
  h.eq({ "feature" }, vim.fn.getcompletion("silent DiffBase ref fe", "cmdline"))
  h.ok(vim.tbl_contains(vim.fn.getcompletion("vert DiffBase ref ", "cmdline"), "origin/main"))
  h.eq({}, vim.fn.getcompletion("silent DiffBase off ", "cmdline"))
end

T["completion outside a repository is empty"] = function()
  local plain = h.path("plain")
  vim.fn.mkdir(plain, "p")
  vim.cmd.cd(vim.fn.fnameescape(plain))
  h.eq({}, vim.fn.getcompletion("DiffBase ref ", "cmdline"))
end

T["_command dispatch"] = function()
  local fx = h.fixture()
  h.edit(fx.dir .. "/README.md")
  local events = h.track_changed()
  db()._command({ "previous" })
  h.wait_for(function()
    return #events > 0
  end)
  h.eq("previous", db().get().name)
  db()._command({ "off" })
  h.eq(nil, db().get().base)
  local calls = h.fake_select(nil)
  db()._command({})
  db()._command({ "" })
  h.eq(2, #calls)
  db().setup({ commit_view = true })
  h.fake_select("feat")
  db()._command({ "commit" })
  h.wait_for(function()
    return db().get().detached_from == "feature"
  end, "commit view")
  db()._command({ "back" })
  h.eq("feature", h.git(fx.dir, "branch", "--show-current"))
end

return T
