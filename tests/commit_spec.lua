local h = require("helpers")

local T = {}

local function db()
  return require("diffbase")
end

-- Commit view is opt-in.
local function enable()
  db().setup({ commit_view = true })
end

local function head(dir)
  return h.git(dir, "rev-parse", "HEAD")
end

local function branch(dir)
  return h.git(dir, "branch", "--show-current")
end

T["view_commit: lists default..HEAD, detaches, diffs against the parent"] = function()
  enable()
  local fx = h.fixture({ origin = true })
  local d = fx.dir
  h.write(d .. "/src/d.txt", { "d1" })
  local feat2 = h.commit(d, "feat two", { "src/d.txt" })
  h.edit(d .. "/README.md")
  local calls = h.fake_select("feat") -- first match: "feat two"
  local events = h.track_changed()
  db().view_commit()
  h.eq(1, #calls)
  h.eq("View changes of commit:", calls[1].prompt)
  h.eq({ feat2:sub(1, 7) .. " feat two", fx.feat:sub(1, 7) .. " feat" }, calls[1].labels)
  h.wait_for(function()
    return #events > 0
  end, "DiffBaseChanged")

  h.eq(feat2, head(d))
  h.eq("", branch(d), "HEAD is detached")
  local g = db().get()
  h.eq(fx.feat, g.base, "base is the parent")
  h.eq("feature", g.detached_from)
  h.eq("commit " .. feat2:sub(1, 7), g.name)
  h.eq("commit " .. feat2:sub(1, 7) .. " feat two", g.label)
  h.eq({ added = 1, removed = 0, binary = false, new = true }, db().stats(d .. "/src/d.txt"))
  h.eq(nil, db().stats(d .. "/src/c.txt"), "earlier commits are not shown")
  -- Untracked working-tree files are not part of the viewed commit.
  h.eq(nil, db().stats(d .. "/untracked.txt"), "untracked files are not counted in commit view")
  h.eq(nil, db().stats(d .. "/blob.bin"))
  h.eq(("Δ commit %s +1 -0"):format(feat2:sub(1, 7)), db().status())
end

T["view_commit again while detached lists from the branch it returns to"] = function()
  enable()
  local fx = h.fixture({ origin = true })
  local d = fx.dir
  h.write(d .. "/src/d.txt", { "d1" })
  local feat2 = h.commit(d, "feat two", { "src/d.txt" })
  h.edit(d .. "/README.md")
  local calls = h.fake_select({ "feat", "feat two" })
  local events = h.track_changed()
  db().view_commit()
  h.wait_for(function()
    return #events > 0
  end, "first commit")
  h.eq(feat2, head(d))
  -- Hop to the older commit, then open the picker again: the branch tip must still be offered.
  h.on_and_wait(function()
    return db()._open_commit(d, fx.feat)
  end)
  h.eq(fx.feat, head(d))
  local n = #events
  db().view_commit()
  h.eq(2, #calls)
  h.eq({ feat2:sub(1, 7) .. " feat two", fx.feat:sub(1, 7) .. " feat" }, calls[2].labels)
  h.wait_for(function()
    return #events > n
  end, "second commit")
  h.eq(feat2, head(d))
  h.eq("feature", db().get().detached_from)
  h.eq(true, db().back())
  h.eq("feature", branch(d))
end

T["view_commit again from the root commit still lists the branch range"] = function()
  enable()
  local fx = h.fixture()
  local d = fx.dir
  h.edit(d .. "/README.md")
  h.on_and_wait(function()
    return db()._open_commit(d, fx.init)
  end)
  local calls = h.fake_select(nil)
  db().view_commit()
  -- local main exists, so the range main..feature applies (feat only); still listed from the branch tip.
  h.eq({ fx.feat:sub(1, 7) .. " feat" }, calls[1].labels)
end

T["submodules: commit view and back work although switch leaves the submodule worktree alone"] = function()
  local sub = h.repo("sub")
  h.write(sub .. "/s.txt", { "s1" })
  h.commit(sub, "sub one")
  local d = h.repo("super")
  h.write(d .. "/a.txt", { "a1" })
  h.commit(d, "init")
  h.run({ "git", "-C", d, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "lib/sub" })
  h.commit(d, "add submodule")
  h.git(d, "switch", "-q", "-c", "feat")
  h.write(d .. "/lib/sub/s.txt", { "s1", "s2" })
  h.commit(d .. "/lib/sub", "sub two")
  h.write(d .. "/a.txt", { "a1", "a2" })
  h.commit(d, "bump submodule")
  h.eq("", h.git(d, "status", "--porcelain"), "clean before")

  h.edit(d .. "/a.txt")
  h.on_and_wait(function()
    return db()._open_commit(d, h.git(d, "rev-parse", "HEAD~1"))
  end)
  h.eq(false, require("diffbase.git").is_dirty(d), "a stale submodule checkout is not a local change")
  h.eq(true, db().back())
  h.eq("feat", branch(d))
  h.eq("", h.git(d, "status", "--porcelain"), "clean after")
  h.no_warnings()
end

T["view_commit: cancel does nothing"] = function()
  enable()
  local fx = h.fixture()
  h.edit(fx.dir .. "/README.md")
  h.fake_select(nil)
  db().view_commit()
  h.settle(50)
  h.eq("feature", branch(fx.dir))
  h.eq(nil, db().get().base)
end

T["refuses while a buffer in the repository has unsaved changes"] = function()
  enable()
  local fx = h.fixture()
  local d = fx.dir
  local other = h.repo("other")
  h.write(other .. "/o.txt", { "o" })
  h.commit(other, "init")
  -- An unsaved buffer in another repository does not block.
  local obuf = h.edit(other .. "/o.txt")
  vim.api.nvim_buf_set_lines(obuf, 0, -1, false, { "edited elsewhere" })
  local buf = h.edit(d .. "/src/a.txt")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })
  h.ok(vim.bo[buf].modified)
  local before = head(d)
  local calls = h.fake_select("feat")
  db().view_commit()
  h.eq(0, #calls, "picker not shown")
  h.warned("unsaved changes in src/a.txt")
  h.eq(0, #h.find_notes("o.txt"), "other repositories are not listed")
  h.eq(false, db()._open_commit(d, fx.second))
  h.eq(before, head(d), "HEAD unchanged")
  h.eq("feature", branch(d))
  h.eq(nil, db().get().detached_from)

  -- Discarding the edit unblocks it.
  vim.cmd("silent edit!")
  h.on_and_wait(function()
    return db()._open_commit(d, fx.second)
  end)
  h.eq(fx.second, head(d))
end

T["a second repository cannot enter commit view while the first is detached"] = function()
  enable()
  local a = h.fixture()
  local b = h.fixture()
  h.edit(a.dir .. "/README.md")
  h.on_and_wait(function()
    return db()._open_commit(a.dir, a.second)
  end)
  h.eq(a.second, head(a.dir))

  h.edit(b.dir .. "/README.md")
  local calls = h.fake_select("feat")
  db().view_commit()
  h.eq(0, #calls, "picker not shown")
  h.warned("still in commit view in " .. a.dir)
  h.eq(false, db()._open_commit(b.dir, b.second))
  h.eq("feature", branch(b.dir), "B stays on its branch")
  h.eq("feature", db().get().detached_from, "A's return target is kept")
  h.eq(a.dir, db()._state().return_to.root)

  -- back() (from B's buffer) returns A.
  h.eq(true, db().back())
  h.eq("feature", branch(a.dir))
  h.eq("feature", branch(b.dir))
  h.eq("", db().status())
end

T["a second repository cannot set a base while the first is in commit view"] = function()
  local a = h.fixture()
  local b = h.fixture()
  h.edit(a.dir .. "/README.md")
  h.on_and_wait(function()
    return db()._open_commit(a.dir, a.second)
  end)
  local base_a = db().get().base

  -- Diffing B here would leave out B's untracked files (commit view excludes them), and `back` in A would
  -- turn B's base off.
  h.edit(b.dir .. "/README.md")
  h.clear_notes()
  h.eq(false, db().set("HEAD"))
  h.warned("still in commit view in " .. a.dir)
  h.eq(false, db().set_preset("previous"))
  h.eq(a.dir, db().get().root, "A's commit view is untouched")
  h.eq(base_a, db().get().base)

  h.eq(true, db().back())
  h.on_and_wait(function()
    return db().set("HEAD")
  end)
  h.eq(true, db().stats(b.dir .. "/untracked.txt").new, "B's untracked files count once A is back")
end

T["refuses with tracked changes; untracked files do not block"] = function()
  enable()
  local fx = h.fixture()
  local d = fx.dir
  h.edit(d .. "/README.md")
  h.write(d .. "/src/a.txt", { "dirty" })
  local calls = h.fake_select("feat")
  db().view_commit()
  h.eq(0, #calls, "picker not shown")
  h.warned("uncommitted changes to tracked files")
  h.eq(false, db()._open_commit(d, fx.second))
  h.eq("feature", branch(d))
  h.eq(nil, db().get().base)
  h.eq(nil, db().get().detached_from)

  h.git(d, "checkout", "--", "src/a.txt")
  -- untracked.txt and blob.bin are still there
  h.on_and_wait(function()
    return db()._open_commit(d, fx.second)
  end)
  h.eq(fx.second, head(d))
end

T["root commit diffs against the empty tree"] = function()
  local fx = h.fixture()
  h.edit(fx.dir .. "/README.md")
  h.on_and_wait(function()
    return db()._open_commit(fx.dir, fx.init)
  end)
  h.eq(h.git(fx.dir, "hash-object", "-t", "tree", "/dev/null"), db().get().base)
  h.eq({ added = 4, removed = 0, binary = false, new = true }, db().stats(fx.dir .. "/src/a.txt"))
  -- 4 + 2 + 1 tracked; untracked files are not counted in commit view
  h.eq(nil, db().stats(fx.dir .. "/untracked.txt"))
  h.eq(("Δ commit %s +7 -0"):format(fx.init:sub(1, 7)), db().status())
end

T["commit A then commit B, back returns to the original branch"] = function()
  local fx = h.fixture()
  local d = fx.dir
  h.edit(d .. "/README.md")
  h.on_and_wait(function()
    return db()._open_commit(d, fx.second)
  end)
  h.on_and_wait(function()
    return db()._open_commit(d, fx.init)
  end)
  h.eq(fx.init, head(d))
  h.eq("feature", db().get().detached_from, "return target remembered across commits")

  local events = h.track_changed()
  h.eq(true, db().back())
  h.eq("feature", branch(d))
  h.eq(fx.feat, head(d))
  h.eq(1, #events)
  h.eq(nil, events[1].data.base)
  h.eq({ base = nil, label = nil, name = nil, root = nil, detached_from = nil }, db().get())
  h.eq("", db().status())
  h.ok(#h.find_notes("back on feature") == 1)
end

T["off while detached keeps the indicator; back clears it"] = function()
  local fx = h.fixture()
  local d = fx.dir
  h.edit(d .. "/README.md")
  h.on_and_wait(function()
    return db()._open_commit(d, fx.second)
  end)
  db().off()
  h.eq("Δ detached (from feature)", db().status())
  h.eq("feature", db().get().detached_from)
  h.eq(nil, db().get().base)
  h.eq(fx.second, head(d), "off() does not switch")

  local events = h.track_changed()
  h.eq(true, db().back())
  h.eq("feature", branch(d))
  h.eq("", db().status())
  h.eq(1, #events, "back() announces the change even though off() was a no-op")
  h.eq(nil, events[1].data.detached_from)
  h.eq(nil, db().get().root)
end

T["pick menu while detached offers Back first"] = function()
  local fx = h.fixture()
  h.edit(fx.dir .. "/README.md")
  h.on_and_wait(function()
    return db()._open_commit(fx.dir, fx.second)
  end)
  local calls = h.fake_select("Back to feature")
  db().pick()
  h.eq("  Back to feature", calls[1].labels[1])
  h.eq("feature", branch(fx.dir))
  h.eq(nil, db().get().detached_from)
end

T["starting from a detached HEAD returns to that commit"] = function()
  local fx = h.fixture()
  local d = fx.dir
  h.git(d, "switch", "-q", "--detach", fx.feat)
  h.edit(d .. "/README.md")
  h.on_and_wait(function()
    return db()._open_commit(d, fx.init)
  end)
  h.eq(fx.feat, db().get().detached_from)
  h.eq("Δ commit " .. fx.init:sub(1, 7) .. " +7 -0", db().status())
  db().off()
  h.eq("Δ detached (from " .. fx.feat:sub(1, 7) .. ")", db().status())
  h.eq(true, db().back())
  h.eq(fx.feat, head(d))
  h.eq("", branch(d))
end

T["back refuses when tracked files changed in commit view"] = function()
  local fx = h.fixture()
  local d = fx.dir
  h.edit(d .. "/README.md")
  h.on_and_wait(function()
    return db()._open_commit(d, fx.second)
  end)
  h.write(d .. "/src/b.txt", { "edited" })
  h.eq(false, db().back())
  h.warned("clean them up before going back")
  h.eq(fx.second, head(d))
  h.eq("feature", db().get().detached_from)
  h.git(d, "checkout", "--", "src/b.txt")
  h.eq(true, db().back())
end

T["back when not in commit view warns"] = function()
  h.eq(false, db().back())
  h.warned("not in commit view")
end

T["commit view is disabled by default"] = function()
  local fx = h.fixture()
  h.edit(fx.dir .. "/README.md")
  local calls = h.fake_select(nil)
  db().view_commit()
  h.warned("commit view is disabled; enable it with setup({ commit_view = true })")
  h.eq(0, #calls)
  db().pick()
  for _, l in ipairs(calls[1].labels) do
    h.ok(not l:find("Pick a commit", 1, true), "no commit entry: " .. l)
  end
end

T["pick a commit through the menu"] = function()
  enable()
  local fx = h.fixture()
  h.edit(fx.dir .. "/README.md")
  local calls = h.fake_select({ "Pick a commit", "feat" })
  local events = h.track_changed()
  db().pick()
  h.eq(2, #calls)
  h.wait_for(function()
    return #events > 0
  end, "DiffBaseChanged")
  h.eq(fx.feat, head(fx.dir))
  h.eq(fx.second, db().get().base)
end

T["HEAD switched outside nvim: back and a new commit view do not switch the user away"] = function()
  -- back(): refuses to switch, leaves commit view and turns off.
  local fx2 = h.fixture()
  h.edit(fx2.dir .. "/README.md")
  h.on_and_wait(function()
    return db()._open_commit(fx2.dir, fx2.second)
  end)
  h.git(fx2.dir, "switch", "-q", "main")
  h.clear_notes()
  h.eq(false, db().back())
  h.warned("HEAD moved away from the viewed commit")
  h.eq("main", branch(fx2.dir))
  h.eq({ base = nil, label = nil, name = nil, root = nil, detached_from = nil }, db().get())
  h.eq("", db().status())

  -- A new commit view returns to where HEAD is now, not to the stale target.
  local fx3 = h.fixture()
  h.edit(fx3.dir .. "/README.md")
  h.on_and_wait(function()
    return db()._open_commit(fx3.dir, fx3.second)
  end)
  h.git(fx3.dir, "switch", "-q", "main")
  h.on_and_wait(function()
    return db()._open_commit(fx3.dir, fx3.init)
  end)
  h.eq("main", db().get().detached_from)
  h.eq(true, db().back())
  h.eq("main", branch(fx3.dir))
end

T["HEAD moved to another commit while still detached counts as moved"] = function()
  local fx = h.fixture()
  local d = fx.dir
  h.edit(d .. "/README.md")
  h.on_and_wait(function()
    return db()._open_commit(d, fx.second)
  end)
  h.git(d, "switch", "-q", "--detach", fx.init)
  h.eq(false, db().back())
  h.warned("HEAD moved away")
  h.eq(fx.init, head(d))
  h.eq(nil, db().get().detached_from)
end

T["back refuses while a buffer in the repository has unsaved changes"] = function()
  local fx = h.fixture()
  local d = fx.dir
  local buf = h.edit(d .. "/README.md")
  h.on_and_wait(function()
    return db()._open_commit(d, fx.init)
  end)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "my edit" })
  h.eq(false, db().back())
  h.warned("unsaved changes in README.md")
  h.eq(fx.init, head(d), "still on the viewed commit")
  h.eq("feature", db().get().detached_from)
  vim.cmd("silent edit!")
  h.eq(true, db().back())
  h.eq("feature", branch(d))
end

return T
