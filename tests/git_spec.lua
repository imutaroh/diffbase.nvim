local h = require("helpers")

local T = {}

local function git()
  return require("diffbase.git")
end

---Run git.compute and wait for the result.
local function compute(root, base, untracked)
  local result, err, done
  git().compute(root, base, untracked, function()
    return true
  end, function(r, e)
    result, err, done = r, e, true
  end)
  h.wait_for(function()
    return done
  end, "git.compute")
  return result, err
end

T["default branch: origin/HEAD wins over origin/main"] = function()
  -- origin's HEAD points at "develop"; origin/main also exists.
  local src = h.repo("src")
  h.write(src .. "/f.txt", { "x" })
  h.commit(src, "init")
  h.git(src, "branch", "develop")
  local bare = h.path("bare.git")
  h.run({ "git", "clone", "-q", "--bare", src, bare })
  h.run({ "git", "-C", bare, "symbolic-ref", "HEAD", "refs/heads/develop" })
  local clone = h.path("clone")
  h.run({ "git", "clone", "-q", bare, clone })
  clone = vim.uv.fs_realpath(clone)
  h.eq("origin/develop", h.git(clone, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"))
  h.eq("origin/develop", git().default_branch(clone))

  -- Without origin/HEAD: fall back to origin/main.
  h.git(clone, "remote", "set-head", "origin", "-d")
  h.eq("origin/main", git().default_branch(clone))

  -- Override wins.
  h.eq("custom", git().default_branch(clone, "custom"))
  h.eq("origin/main", git().default_branch(clone, ""))
end

T["default branch: dangling origin/HEAD is skipped"] = function()
  local fx = h.fixture({ origin = true })
  -- origin/HEAD -> origin/gone (does not exist)
  h.git(fx.dir, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/gone")
  h.eq("origin/main", git().default_branch(fx.dir))
end

T["default branch: origin/master, local main, local master, none"] = function()
  local r = h.repo("master-remote")
  h.write(r .. "/f.txt", { "x" })
  h.commit(r, "init")
  h.git(r, "branch", "-m", "main", "trunk")
  h.eq(nil, git().default_branch(r), "no candidates -> nil")

  h.git(r, "branch", "master")
  h.eq("master", git().default_branch(r))

  h.git(r, "branch", "main")
  h.eq("main", git().default_branch(r), "main preferred over master")

  local sha = h.git(r, "rev-parse", "HEAD")
  h.git(r, "update-ref", "refs/remotes/origin/master", sha)
  h.eq("origin/master", git().default_branch(r), "remote branches preferred over local")

  h.git(r, "update-ref", "refs/remotes/origin/main", sha)
  h.eq("origin/main", git().default_branch(r))
end

T["root() normalizes and fails outside a repo"] = function()
  local fx = h.fixture()
  h.eq(fx.dir, git().root(fx.dir .. "/src"))
  local outside = h.path("plain")
  vim.fn.mkdir(outside, "p")
  h.eq(nil, git().root(outside))
end

T["resolve: plain ref, merge-base, missing ref"] = function()
  local fx = h.fixture()
  local dir = fx.dir
  -- main moves on after feature branched, so merge-base differs from main's tip.
  h.git(dir, "switch", "-q", "main")
  h.write(dir .. "/src/m.txt", { "m" })
  local main_tip = h.commit(dir, "main moves", { "src/m.txt" })
  h.git(dir, "switch", "-q", "feature")

  h.eq(main_tip, git().resolve(dir, "main"))
  h.eq(fx.second, git().resolve(dir, "main", true))
  h.eq(fx.second, git().resolve(dir, "HEAD~1"))
  local sha, err = git().resolve(dir, "nope")
  h.eq(nil, sha)
  h.contains(err, "'nope' not found")
  -- A ref that looks like an option is not interpreted as one.
  h.eq(nil, (git().resolve(dir, "--all")))
end

T["resolve: merge-base without common ancestor"] = function()
  local fx = h.fixture({ untracked = false })
  h.git(fx.dir, "switch", "-q", "--orphan", "lonely")
  h.write(fx.dir .. "/l.txt", { "l" })
  h.commit(fx.dir, "lonely")
  local sha, err = git().resolve(fx.dir, "main", true)
  h.eq(nil, sha)
  h.contains(err, "no common ancestor")
end

T["compute: numstat, new files, directory aggregation"] = function()
  local fx = h.fixture({ untracked = false })
  local d = fx.dir
  local r = compute(d, fx.second, true)
  h.eq({ added = 0, removed = 2, binary = false, new = false }, r.files[d .. "/src/a.txt"])
  h.eq({ added = 2, removed = 0, binary = false, new = true }, r.files[d .. "/src/c.txt"])
  h.eq(nil, r.files[d .. "/src/b.txt"], "unchanged file has no entry")
  h.eq({ added = 2, removed = 2, binary = false, new = false }, r.dirs[d .. "/src"])
  h.eq({ added = 2, removed = 2, binary = false, new = false }, r.dirs[d])
  h.eq(nil, r.dirs[vim.fs.dirname(d)], "aggregation stops at the root")

  -- Against init: b.txt changes too, nested dir aggregation.
  h.write(d .. "/src/deep/er/x.txt", { "1", "2", "3", "4" })
  h.git(d, "add", "src/deep/er/x.txt")
  local r2 = compute(d, fx.init, false)
  h.eq({ added = 2, removed = 1, binary = false, new = false }, r2.files[d .. "/src/b.txt"])
  h.eq(4, r2.dirs[d .. "/src/deep/er"].added)
  h.eq(4, r2.dirs[d .. "/src/deep"].added)
  h.eq({ added = 8, removed = 3, binary = false, new = false }, r2.dirs[d .. "/src"])
  h.eq(true, r2.files[d .. "/src/deep/er/x.txt"].new, "staged new file is new")
end

T["compute: working tree edits and deleted files"] = function()
  local fx = h.fixture({ untracked = false })
  local d = fx.dir
  h.write(d .. "/src/a.txt", { "a1", "a2", "added" })
  vim.fn.delete(d .. "/README.md")
  local r = compute(d, fx.second, false)
  h.eq({ added = 1, removed = 2, binary = false, new = false }, r.files[d .. "/src/a.txt"])
  h.eq({ added = 0, removed = 1, binary = false, new = false }, r.files[d .. "/README.md"])
  h.eq({ added = 3, removed = 3, binary = false, new = false }, r.dirs[d])
end

T["compute: untracked files included only when enabled"] = function()
  local fx = h.fixture()
  local d = fx.dir
  h.write(d .. "/.gitignore", { "ignored.txt" })
  h.write(d .. "/ignored.txt", { "i" })
  h.write(d .. "/new dir/with space.txt", { "s1", "s2" })
  local on = compute(d, fx.feat, true)
  h.eq({ added = 3, removed = 0, binary = false, new = true }, on.files[d .. "/untracked.txt"])
  h.eq({ added = 0, removed = 0, binary = true, new = true }, on.files[d .. "/blob.bin"])
  h.eq({ added = 2, removed = 0, binary = false, new = true }, on.files[d .. "/new dir/with space.txt"])
  h.eq({ added = 1, removed = 0, binary = false, new = true }, on.files[d .. "/.gitignore"])
  h.eq(nil, on.files[d .. "/ignored.txt"], "ignored files are excluded")
  h.eq(2, on.dirs[d .. "/new dir"].added)
  h.eq(6, on.dirs[d].added)

  local off = compute(d, fx.feat, false)
  h.eq({}, off.files)
  h.eq({}, off.dirs)
end

T["compute: untracked nested repository and symlink to a directory are skipped"] = function()
  local fx = h.fixture({ untracked = false })
  local d = fx.dir
  vim.fn.mkdir(d .. "/nested", "p")
  h.run({ "git", "init", "-q", d .. "/nested" })
  h.write(d .. "/nested/n.txt", { "n" })
  vim.fn.mkdir(d .. "/somedir", "p")
  h.write(d .. "/somedir/x.txt", { "x1", "x2" })
  assert(vim.uv.fs_symlink("somedir", d .. "/dirlink"))
  h.write(d .. "/empty.txt", "")
  local r = compute(d, fx.feat, true)
  h.eq(nil, r.files[d .. "/nested/"], "no trailing-slash key")
  h.eq(nil, r.files[d .. "/nested"])
  h.eq(nil, r.dirs[d .. "/nested"], "no bogus +0 -0 directory")
  h.eq(nil, r.files[d .. "/dirlink"], "git error for a directory symlink is not a 0/0 file")
  h.eq({ added = 2, removed = 0, binary = false, new = true }, r.files[d .. "/somedir/x.txt"])
  h.eq({ added = 0, removed = 0, binary = false, new = true }, r.files[d .. "/empty.txt"], "empty files are kept")
  h.eq(2, r.dirs[d].added)
end

T["compute: many untracked files (concurrency queue)"] = function()
  local fx = h.fixture({ untracked = false })
  for i = 1, 30 do
    h.write(("%s/many/f%02d.txt"):format(fx.dir, i), { "x", "y" })
  end
  local r = compute(fx.dir, fx.feat, true)
  h.eq({ added = 60, removed = 0, binary = false, new = false }, r.dirs[fx.dir .. "/many"])
  h.eq(true, r.files[fx.dir .. "/many/f30.txt"].new)
end

T["compute: tracked binary file shows as binary"] = function()
  local fx = h.fixture({ untracked = false })
  h.write_binary(fx.dir, "img.bin")
  local before = h.commit(fx.dir, "add binary")
  h.write(fx.dir .. "/img.bin", "\0changed\0binary\255")
  local r = compute(fx.dir, before, false)
  h.eq({ added = 0, removed = 0, binary = true, new = false }, r.files[fx.dir .. "/img.bin"])
  local r2 = compute(fx.dir, fx.feat, false)
  h.eq({ added = 0, removed = 0, binary = true, new = true }, r2.files[fx.dir .. "/img.bin"])
end

T["compute: bad base reports an error"] = function()
  local fx = h.fixture({ untracked = false })
  local r, err = compute(fx.dir, "0000000000000000000000000000000000000001", true)
  h.eq(nil, r)
  h.ok(err and err ~= "", "error message")
end

T["commits: default..HEAD range, else limited log"] = function()
  local fx = h.fixture({ untracked = false })
  h.write(fx.dir .. "/src/d.txt", { "d" })
  local feat2 = h.commit(fx.dir, "feat two")
  local list = git().commits(fx.dir, "main", 20)
  h.eq(
    { feat2, fx.feat },
    vim.tbl_map(function(c)
      return c.sha
    end, list)
  )
  h.eq(feat2:sub(1, 7) .. " feat two", list[1].text)

  -- On main itself the range is empty: fall back to the last `limit` commits.
  h.git(fx.dir, "switch", "-q", "main")
  local fallback = git().commits(fx.dir, "main", 1)
  h.eq(
    { fx.second },
    vim.tbl_map(function(c)
      return c.sha
    end, fallback)
  )
  h.eq(2, #git().commits(fx.dir, nil, 20), "no default branch -> limited log")
end

T["parent: normal and root commit"] = function()
  local fx = h.fixture({ untracked = false })
  local p, is_root = git().parent(fx.dir, fx.second)
  h.eq(fx.init, p)
  h.eq(false, is_root)
  local ep, eroot = git().parent(fx.dir, fx.init)
  h.eq(git().EMPTY_TREE, ep)
  h.eq(true, eroot)
end

T["is_dirty ignores untracked files"] = function()
  local fx = h.fixture()
  h.eq(false, git().is_dirty(fx.dir))
  h.write(fx.dir .. "/src/a.txt", { "dirty" })
  h.eq(true, git().is_dirty(fx.dir))
  h.git(fx.dir, "add", "src/a.txt")
  h.eq(true, git().is_dirty(fx.dir), "staged counts")
end

return T
