local h = require("helpers")

local T = {}

local function db()
  return require("diffbase")
end

T["previous: stats, directories, untracked, binary, status"] = function()
  local fx = h.fixture()
  local d = fx.dir
  h.edit(d .. "/src/a.txt")
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
  local g = db().get()
  h.eq(fx.second, g.base)
  h.eq(d, g.root)
  h.eq("previous", g.name)
  h.eq("Last commit", g.label)
  h.eq(nil, g.detached_from)
  h.eq({ added = 0, removed = 2, binary = false, new = false }, db().stats(), "current buffer")
  h.eq({ added = 2, removed = 0, binary = false, new = true }, db().stats(d .. "/src/c.txt"))
  h.eq({ added = 2, removed = 2, binary = false, new = false }, db().stats(d .. "/src"))
  h.eq({ added = 2, removed = 2, binary = false, new = false }, db().stats(d .. "/src/"), "trailing slash")
  h.eq({ added = 3, removed = 0, binary = false, new = true }, db().stats(d .. "/untracked.txt"))
  h.eq({ added = 0, removed = 0, binary = true, new = true }, db().stats(d .. "/blob.bin"))
  h.eq(nil, db().stats(d .. "/src/b.txt"), "unchanged")
  h.eq({ added = 5, removed = 2, binary = false, new = false }, db().stats(d))
  h.eq("Δ previous +5 -2", db().status())
  h.no_warnings()
  h.ok(#h.find_notes("diffing against Last commit", vim.log.levels.INFO) == 1)
end

T["stats() returns a copy"] = function()
  local fx = h.fixture()
  vim.cmd.cd(vim.fn.fnameescape(fx.dir)) -- no file buffer: root comes from cwd
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
  local s = db().stats(fx.dir .. "/src")
  s.added = 999
  h.eq(2, db().stats(fx.dir .. "/src").added)
end

T["include_untracked = false hides untracked files"] = function()
  local fx = h.fixture()
  vim.cmd.cd(vim.fn.fnameescape(fx.dir))
  db().setup({ include_untracked = false })
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
  h.eq(nil, db().stats(fx.dir .. "/untracked.txt"))
  h.eq(nil, db().stats(fx.dir .. "/blob.bin"))
  h.eq("Δ previous +2 -2", db().status())
end

T["main: diffs against the merge-base with the default branch"] = function()
  local fx = h.fixture({ origin = true })
  local d = fx.dir
  -- origin/main moves on after feature branched.
  h.git(d, "switch", "-q", "main")
  h.write(d .. "/src/m.txt", { "m1", "m2", "m3", "m4", "m5", "m6", "m7" })
  h.commit(d, "main moves", { "src/m.txt" })
  h.git(d, "push", "-q", "origin", "main")
  h.git(d, "switch", "-q", "feature")
  h.edit(d .. "/src/a.txt")
  h.on_and_wait(function()
    return db().set_preset("main")
  end)
  h.eq(h.git(d, "merge-base", "origin/main", "HEAD"), db().get().base)
  h.eq(fx.second, db().get().base)
  h.eq(nil, db().stats(d .. "/src/m.txt"), "main's later commit is not part of this branch's diff")
  h.eq("Δ main +5 -2", db().status())
end

T["main: no default branch detected"] = function()
  local r = h.repo("trunk")
  h.write(r .. "/f.txt", { "x" })
  h.commit(r, "init")
  h.git(r, "branch", "-m", "main", "trunk")
  h.edit(r .. "/f.txt")
  h.eq(false, db().set_preset("main"))
  h.warned("could not detect the default branch")
  h.eq(nil, db().get().base)

  -- default_branch override makes it work.
  db().setup({ default_branch = "trunk" })
  h.on_and_wait(function()
    return db().set_preset("main")
  end)
  h.eq(h.git(r, "rev-parse", "trunk"), db().get().base)
end

T["unpushed: diffs against the upstream"] = function()
  local fx = h.fixture({ origin = true, untracked = false })
  local d = fx.dir
  h.git(d, "push", "-q", "-u", "origin", "feature")
  h.write(d .. "/src/local.txt", { "l1", "l2", "l3" })
  h.commit(d, "local only")
  h.edit(d .. "/src/local.txt")
  h.on_and_wait(function()
    return db().set_preset("unpushed")
  end)
  h.eq(fx.feat, db().get().base)
  h.eq("Δ unpushed +3 -0", db().status())
  h.eq(nil, db().stats(d .. "/src/c.txt"), "pushed work is not shown")
end

T["unpushed: no upstream warns and stays off"] = function()
  local fx = h.fixture()
  h.edit(fx.dir .. "/src/a.txt")
  h.eq(false, db().set_preset("unpushed"))
  h.warned("no upstream branch is configured for 'feature'")
  h.eq(nil, db().get().base)
  h.eq("", db().status())
end

T["unpushed: upstream deleted on the remote says it is gone"] = function()
  local fx = h.fixture({ origin = true, untracked = false })
  local d = fx.dir
  h.git(d, "push", "-q", "-u", "origin", "feature")
  h.git(d, "push", "-q", "origin", "--delete", "feature")
  h.git(d, "fetch", "-q", "--prune")
  h.edit(d .. "/src/a.txt")
  h.eq(false, db().set_preset("unpushed"))
  h.warned("the upstream branch 'origin/feature' of 'feature' is gone")
  h.eq(0, #h.find_notes("no upstream branch is configured"))
  h.eq(nil, db().get().base)
end

T["unpushed: detached HEAD says so"] = function()
  local fx = h.fixture({ origin = true, untracked = false })
  local d = fx.dir
  h.git(d, "switch", "-q", "--detach", "HEAD")
  h.edit(d .. "/src/a.txt")
  h.eq(false, db().set_preset("unpushed"))
  h.warned("HEAD is detached")
  h.eq(0, #h.find_notes("no upstream branch is configured"))
end

T["set(): arbitrary ref, label and name, unknown ref"] = function()
  local fx = h.fixture()
  h.edit(fx.dir .. "/README.md")
  h.on_and_wait(function()
    return db().set("HEAD~2")
  end)
  h.eq(fx.init, db().get().base)
  h.eq("Δ HEAD~2 +7 -3", db().status())

  h.on_and_wait(function()
    return db().set("main", { merge_base = true, label = "My label", name = "mb" })
  end)
  h.eq(fx.second, db().get().base)
  h.eq("My label", db().get().label)
  h.eq("Δ mb +5 -2", db().status())

  h.eq(false, db().set("does-not-exist"))
  h.warned("'does-not-exist' not found")
  h.eq(fx.second, db().get().base, "failed set keeps the current base")

  h.eq(false, db().set(""))
  h.warned("ref is required")
end

T["set(): a ref spelled like a base name, and @default, are shown so they cannot pass for a preset"] = function()
  local fx = h.fixture()
  h.edit(fx.dir .. "/README.md")
  h.on_and_wait(function()
    return db().set("main") -- the branch tip, not the `main` preset's merge-base
  end)
  h.eq("ref:main", db().get().name)
  h.eq("ref:main", db().get().label)
  h.ok(vim.startswith(db().status(), "Δ ref:main "), db().status())
  h.ok(#h.find_notes("diffing against ref:main") > 0, "notification")
  local calls = h.fake_select(nil)
  db().pick()
  for _, label in ipairs(calls[1].labels) do
    h.ok(not vim.startswith(label, "●"), "no preset marked current: " .. label)
  end

  h.on_and_wait(function()
    return db().set("@default")
  end)
  h.eq("ref:main", db().get().name, "@default shows the resolved branch, not the sentinel")
  h.eq(0, #h.find_notes("@default"), "the sentinel never reaches a notification")

  h.on_and_wait(function()
    return db().set_preset("main")
  end)
  h.eq("main", db().get().name, "the preset keeps its own name")
end

T["set(): @default resolves to the default branch name in status and notifications"] = function()
  local fx = h.fixture({ origin = true })
  h.edit(fx.dir .. "/README.md")
  h.on_and_wait(function()
    return db().set("@default")
  end)
  h.eq("origin/main", db().get().name)
  h.eq("origin/main", db().get().label)
  h.ok(#h.find_notes("diffing against origin/main") > 0, "notification")
  h.eq(0, #h.find_notes("@default"))
end

T["set(): function ref receives root and default branch"] = function()
  local fx = h.fixture({ origin = true })
  h.edit(fx.dir .. "/src/a.txt")
  local ctx
  h.on_and_wait(function()
    return db().set(function(c)
      ctx = c
      return "HEAD~1"
    end)
  end)
  h.eq({ root = fx.dir, default_branch = "origin/main" }, ctx)
  h.eq(fx.second, db().get().base)
  h.eq("HEAD~1", db().get().name, "function refs are named by the expanded ref")

  h.eq(
    false,
    db().set(function()
      error("boom")
    end)
  )
  h.warned("ref function failed")
  h.eq(
    false,
    db().set(function()
      return nil
    end)
  )
  h.warned("ref function returned no ref")
end

T["custom base with function ref via set_preset"] = function()
  local fx = h.fixture()
  db().setup({
    bases = {
      {
        name = "root",
        label = "Since the first commit",
        ref = function(c)
          return h.git(c.root, "rev-list", "--max-parents=0", "HEAD")
        end,
      },
    },
  })
  h.edit(fx.dir .. "/README.md")
  h.on_and_wait(function()
    return db().set_preset("root")
  end)
  h.eq(fx.init, db().get().base)
  h.eq("Δ root +7 -3", db().status())
  h.eq(false, db().set_preset("main"), "default bases were replaced")
  h.warned("unknown base 'main'")
end

T["not inside a git repository"] = function()
  local plain = h.path("plain")
  vim.fn.mkdir(plain, "p")
  h.write(plain .. "/f.txt", { "x" })
  h.edit(plain .. "/f.txt")
  vim.cmd.cd(vim.fn.fnameescape(plain))
  h.eq(false, db().set_preset("previous"))
  h.warned("not inside a git repository")
end

T["root is taken from the current buffer, not cwd"] = function()
  local a = h.fixture()
  local b = h.fixture({ untracked = false })
  vim.cmd.cd(vim.fn.fnameescape(a.dir))
  h.edit(b.dir .. "/src/a.txt")
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
  h.eq(b.dir, db().get().root)
  h.eq("Δ previous +2 -2", db().status())
end

T["ordering: DiffBaseChanged fires after stats are populated, never synchronously"] = function()
  local fx = h.fixture()
  h.edit(fx.dir .. "/src/c.txt")
  local events = h.track_changed(function(ev)
    return {
      stats = require("diffbase").stats(fx.dir .. "/src/c.txt"),
      status = require("diffbase").status(),
      marks = h.newfile_marks(vim.api.nvim_get_current_buf()),
      base = ev.data.base,
    }
  end)
  h.eq(true, db().set_preset("previous"))
  h.eq(0, #events, "not fired right after dispatch")
  h.eq("Δ previous", db().status(), "status before stats arrive has no counts")
  h.wait_for(function()
    return #events > 0
  end, "DiffBaseChanged")
  h.settle(50)
  h.eq(1, #events, "fired exactly once")
  local snap = events[1].snap
  h.eq({ added = 2, removed = 0, binary = false, new = true }, snap.stats)
  h.eq("Δ previous +5 -2", snap.status)
  h.eq(2, snap.marks, "new-file extmarks placed before the event")
  h.eq(fx.second, snap.base)
  h.eq(db().get(), events[1].data, "event data is get()")
end

T["stale results are dropped (off right after set)"] = function()
  local fx = h.fixture()
  h.edit(fx.dir .. "/src/c.txt")
  local events = h.track_changed(function()
    return require("diffbase").stats(fx.dir .. "/src/c.txt")
  end)
  h.eq(true, db().set_preset("previous"))
  db().off()
  h.settle(300)
  h.eq(1, #events, "only off() fired")
  h.eq(nil, events[1].data.base)
  h.eq(nil, db().stats(fx.dir .. "/src/c.txt"))
  h.eq("", db().status())
  h.eq(0, h.newfile_marks(vim.api.nvim_get_current_buf()))
end

T["a superseded computation stops counting untracked files"] = function()
  local fx = h.fixture({ untracked = false })
  for i = 1, 60 do
    h.write(("%s/many/f%02d.txt"):format(fx.dir, i), { "x" })
  end
  h.edit(fx.dir .. "/README.md")
  local git = require("diffbase.git")
  local run, untracked_runs = git.run, 0
  git.run = function(root, args, cb)
    if vim.tbl_contains(args, "--no-index") then
      untracked_runs = untracked_runs + 1
    end
    return run(root, args, cb)
  end
  local events = h.track_changed()
  h.eq(true, db().set_preset("previous"))
  h.eq(true, db().set("HEAD~2")) -- supersedes the first computation
  h.wait_for(function()
    return #events > 0
  end, "DiffBaseChanged")
  h.settle(200)
  git.run = run
  h.eq(1, #events)
  h.eq(60, db().stats(fx.dir .. "/many").added)
  h.eq(60, untracked_runs, "only the current computation counts untracked files")
end

T["stale results are dropped (quick base switch)"] = function()
  local fx = h.fixture()
  h.edit(fx.dir .. "/README.md")
  local events = h.track_changed(function(ev)
    return { base = ev.data.base, status = require("diffbase").status() }
  end)
  h.eq(true, db().set_preset("previous"))
  h.eq(true, db().set("HEAD~2"))
  h.settle(300)
  h.eq(1, #events, "only the latest computation lands")
  h.eq({ base = fx.init, status = "Δ HEAD~2 +7 -3" }, events[1].snap)
end

T["new-file extmarks: new files only, later buffers, off clears"] = function()
  local fx = h.fixture()
  local d = fx.dir
  local c = h.edit(d .. "/src/c.txt")
  local u = h.edit(d .. "/untracked.txt")
  local a = h.edit(d .. "/src/a.txt")
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
  h.eq(2, h.newfile_marks(c))
  h.eq(3, h.newfile_marks(u))
  h.eq(0, h.newfile_marks(a))
  local mark = vim.api.nvim_buf_get_extmarks(c, vim.api.nvim_create_namespace("diffbase_newfile"), 0, -1, {
    details = true,
  })[1]
  h.eq("DiffBaseNewLine", mark[4].line_hl_group)
  h.eq("DiffBaseNewNr", mark[4].number_hl_group)

  -- A new file opened after stats were computed is marked on BufEnter.
  h.write(d .. "/later.txt", { "1", "2", "3", "4" })
  db().refresh()
  h.wait_for(function()
    return db().stats(d .. "/later.txt") ~= nil
  end, "refresh picks up later.txt")
  local l = h.edit(d .. "/later.txt")
  h.eq(4, h.newfile_marks(l))

  -- Lines added in the buffer get marked too.
  vim.api.nvim_buf_set_lines(l, -1, -1, false, { "5" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = l })
  h.eq(5, h.newfile_marks(l))

  db().off()
  for _, b in ipairs({ c, u, l }) do
    h.eq(0, h.newfile_marks(b))
  end
end

T["new_file_highlight = false places no extmarks"] = function()
  local fx = h.fixture()
  db().setup({ new_file_highlight = false })
  local c = h.edit(fx.dir .. "/src/c.txt")
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
  h.eq(0, h.newfile_marks(c))
end

T["refresh(): debounced recompute after edits on disk"] = function()
  local fx = h.fixture()
  h.edit(fx.dir .. "/src/a.txt")
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
  h.write(fx.dir .. "/src/b.txt", { "b1", "b2 changed", "b3", "b4" })
  local events = h.track_changed()
  db().refresh()
  db().refresh()
  db().refresh()
  h.wait_for(function()
    return #events > 0
  end, "refresh")
  h.settle(250)
  h.eq(1, #events, "debounced into one recompute")
  h.eq({ added = 1, removed = 0, binary = false, new = false }, db().stats(fx.dir .. "/src/b.txt"))
  h.eq(fx.second, db().get().base, "refresh keeps the resolved base")
end

T["BufWritePost triggers a refresh"] = function()
  local fx = h.fixture()
  local buf = h.edit(fx.dir .. "/src/b.txt")
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
  h.eq(nil, db().stats())
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "b4", "b5" })
  local events = h.track_changed()
  vim.cmd("silent write")
  h.wait_for(function()
    return #events > 0
  end, "refresh after write")
  h.eq({ added = 2, removed = 0, binary = false, new = false }, db().stats())
end

T["refresh_events = {} disables automatic refresh"] = function()
  local fx = h.fixture()
  db().setup({ refresh_events = {} })
  local buf = h.edit(fx.dir .. "/src/b.txt")
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
  local events = h.track_changed()
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "b4" })
  vim.cmd("silent write")
  h.settle(300)
  h.eq(0, #events)
  h.eq(nil, db().stats())
end

T["refresh() while off is a no-op"] = function()
  h.fixture()
  local events = h.track_changed()
  db().refresh()
  h.settle(250)
  h.eq(0, #events)
end

T["off(): clears state, fires once, no-op when already off"] = function()
  local fx = h.fixture()
  local c = h.edit(fx.dir .. "/src/c.txt")
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
  local events = h.track_changed()
  db().off()
  h.eq(1, #events)
  h.eq(
    {},
    vim.tbl_filter(function(v)
      return v ~= vim.NIL
    end, events[1].data)
  )
  h.eq({ base = nil, label = nil, name = nil, root = nil, detached_from = nil }, db().get())
  h.eq(nil, db().stats(fx.dir .. "/src/c.txt"))
  h.eq(nil, db().stats(fx.dir))
  h.eq("", db().status())
  h.eq(0, h.newfile_marks(c))
  h.ok(#h.find_notes("diffbase: off") == 1)

  db().off()
  h.eq(1, #events, "second off() fires nothing")
  h.eq(1, #h.find_notes("diffbase: off"), "and says nothing")
end

T["symlinked checkout: keys, lookups and buffers resolve to the real path"] = function()
  local fx = h.fixture()
  local link = h.path("link")
  assert(vim.uv.fs_symlink(fx.dir, link))
  -- Neovim resolves symlinks in buffer names itself; lookups by link path go through util.norm.
  local buf = h.edit(link .. "/src/c.txt")
  -- Root detection starting from the symlinked directory.
  vim.cmd.cd(vim.fn.fnameescape(link))
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
  h.eq(fx.dir, db().get().root, "root is the real path")
  h.eq({ added = 2, removed = 0, binary = false, new = true }, db().stats(), "current buffer (symlinked name)")
  h.eq(db().stats(fx.dir .. "/src/c.txt"), db().stats(link .. "/src/c.txt"))
  h.eq(db().stats(fx.dir .. "/src"), db().stats(link .. "/src"))
  h.eq({ added = 5, removed = 2, binary = false, new = false }, db().stats(link))
  h.eq(2, h.newfile_marks(buf), "new-file extmarks on the symlink-named buffer")
  h.eq("Δ previous +5 -2", db().status())
end

T["symlinked file: buffer named via the link gets stats and extmarks"] = function()
  local fx = h.fixture()
  local link = h.path("c-link.txt")
  assert(vim.uv.fs_symlink(fx.dir .. "/src/c.txt", link))
  local buf = h.edit(link)
  h.contains(vim.api.nvim_buf_get_name(buf), "c-link.txt", "buffer keeps the symlink name")
  -- The link lives outside the repository (and cwd is elsewhere): the root comes from the link's target.
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
  h.eq(fx.dir, db().get().root)
  h.eq({ added = 2, removed = 0, binary = false, new = true }, db().stats())
  h.eq(2, h.newfile_marks(buf))
end

T["tracked symlink: stats and extmarks are its own, not its target's"] = function()
  local fx = h.fixture({ untracked = false })
  local d = fx.dir
  assert(vim.uv.fs_symlink("README.md", d .. "/newlink"))
  h.commit(d, "add link", { "newlink" })
  h.edit(d .. "/src/a.txt") -- not README.md: nvim would reuse that buffer when the link is edited
  h.on_and_wait(function()
    return db().set("HEAD~1")
  end)
  h.eq({ added = 1, removed = 0, binary = false, new = true }, db().stats(d .. "/newlink"))
  h.eq(nil, db().stats(d .. "/README.md"), "the unchanged target has no stats")
  local buf = h.edit(d .. "/newlink")
  h.contains(vim.api.nvim_buf_get_name(buf), "newlink")
  h.eq(1, h.newfile_marks(buf), "the new link's buffer is marked as new")
  -- When the target changes, the link still reports its own (unchanged) entry.
  h.write(d .. "/README.md", { "readme", "more" })
  local events = h.track_changed()
  db().refresh()
  h.wait_for(function()
    return #events > 0
  end)
  h.eq({ added = 1, removed = 0, binary = false, new = false }, db().stats(d .. "/README.md"))
  h.eq({ added = 1, removed = 0, binary = false, new = true }, db().stats(d .. "/newlink"))
end

T["switching repositories while on"] = function()
  local a = h.fixture()
  local b = h.fixture({ untracked = false })
  h.edit(a.dir .. "/README.md")
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
  h.edit(b.dir .. "/README.md")
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
  h.eq(b.dir, db().get().root)
  h.eq(nil, db().stats(a.dir .. "/untracked.txt"), "old repository's stats are gone")
  h.eq({ added = 2, removed = 0, binary = false, new = true }, db().stats(b.dir .. "/src/c.txt"))
  h.eq("Δ previous +2 -2", db().status())
end

T["works with no integrations installed"] = function()
  local fx = h.fixture()
  h.ok(not pcall(require, "gitsigns"))
  h.ok(not pcall(require, "neo-tree.sources.manager"))
  h.edit(fx.dir .. "/src/c.txt")
  h.on_and_wait(function()
    return db().set_preset("previous")
  end)
  db().off()
  h.no_warnings()
end

T[":checkhealth diffbase runs"] = function()
  local fx = h.fixture({ origin = true })
  -- the health buffer is not a file buffer, so the repository comes from cwd
  vim.cmd.cd(vim.fn.fnameescape(fx.dir))
  vim.cmd("silent checkhealth diffbase")
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  h.contains(text, "default branch: origin/main")
  h.ok(not text:find("ERROR", 1, true), text)
  vim.cmd("silent! tabclose")
end

T[":checkhealth diffbase reports git older than 2.24 as an error"] = function()
  local real_git = vim.fn.exepath("git")
  local bin = h.path("oldgit")
  h.write(bin .. "/git", {
    "#!/bin/sh",
    'if [ "$1" = "--version" ]; then echo "git version 2.20.1"; exit 0; fi',
    'exec "' .. real_git .. '" "$@"',
  })
  vim.fn.setfperm(bin .. "/git", "rwxr-xr-x")
  local path = vim.env.PATH
  vim.env.PATH = bin .. ":" .. path
  local ok, err = pcall(function()
    vim.cmd("silent checkhealth diffbase")
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    vim.cmd("silent! tabclose")
    h.contains(text, "git version 2.20.1: git >= 2.24 required")
    h.contains(text, "ERROR")
  end)
  vim.env.PATH = path
  h.ok(ok, tostring(err))
end

T[":checkhealth diffbase reports the active state when cwd is outside the repository"] = function()
  local fx = h.fixture({ origin = true })
  vim.cmd.cd(vim.fn.fnameescape(h.tmp)) -- not a repository (GIT_CEILING_DIRECTORIES)
  h.edit(fx.dir .. "/README.md")
  h.on_and_wait(function()
    return db()._open_commit(fx.dir, fx.second)
  end)
  vim.cmd("silent checkhealth diffbase")
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  vim.cmd("silent! tabclose")
  h.contains(text, "active: commit")
  h.contains(text, "in commit view (HEAD detached)")
  h.contains(text, "repository: " .. fx.dir)
  h.contains(text, "default branch: origin/main")
end

return T
