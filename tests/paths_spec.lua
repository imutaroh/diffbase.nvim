-- Path-shape edge cases: Unicode normalization, "$NAME" file names, file<->directory changes, submodules.
local h = require("helpers")

local T = {}

local function db()
  return require("diffbase")
end

-- "ガ" decomposed (NFD: KA + combining dakuten) and precomposed (NFC).
local GA_NFD = "\u{30AB}\u{3099}"
local GA_NFC = "\u{30AC}"
-- "é" decomposed and precomposed.
local E_NFD = "e\u{0301}"
local E_NFC = "\u{00E9}"

T["names stored in NFD (macOS) get stats and the new-file highlight"] = function()
  local d = h.repo("nfd")
  h.write(d .. "/caf" .. E_NFD .. "/x.txt", { "x1" })
  h.write(d .. "/plain.txt", { "p" })
  h.commit(d, "init")
  -- Tracked file in an NFD-named directory, modified; untracked NFD-named file.
  h.write(d .. "/caf" .. E_NFD .. "/x.txt", { "x1", "x2" })
  h.write(d .. "/" .. GA_NFD .. ".md", { "one", "two" })
  local buf = h.edit(d .. "/" .. GA_NFD .. ".md")
  h.on_and_wait(function()
    return db().set("HEAD")
  end)
  -- neo-tree and buffers use the stored (NFD) bytes.
  h.eq({ added = 2, removed = 0, binary = false, new = true }, db().stats(d .. "/" .. GA_NFD .. ".md"))
  h.eq({ added = 2, removed = 0, binary = false, new = true }, db().stats(), "current buffer")
  h.ok(h.newfile_marks(buf) > 0, "new-file extmarks on the NFD-named buffer")
  h.eq({ added = 1, removed = 0, binary = false, new = false }, db().stats(d .. "/caf" .. E_NFD .. "/x.txt"))
  h.eq({ added = 1, removed = 0, binary = false, new = false }, db().stats(d .. "/caf" .. E_NFD), "NFD directory")
  -- A name typed in NFC still finds the file (on macOS the file system folds it; elsewhere it is a different
  -- file that does not exist, so there is nothing to find).
  if vim.uv.fs_stat(d .. "/" .. GA_NFC .. ".md") then
    h.eq(2, db().stats(d .. "/" .. GA_NFC .. ".md").added, "NFC spelling")
    h.eq(1, db().stats(d .. "/caf" .. E_NFC).added, "NFC directory spelling")
  end
  h.eq("Δ HEAD +3 -0", db().status())
  h.no_warnings()
end

T["a deleted subtree counts toward its existing NFD-named parent directory"] = function()
  local d = h.repo("nfdgone")
  local dir = d .. "/caf" .. E_NFD
  h.write(dir .. "/keep.txt", { "k1", "k2" })
  h.write(dir .. "/sub/gone.txt", { "g1", "g2", "g3" })
  h.commit(d, "init")
  vim.fn.delete(dir .. "/sub", "rf")
  h.write(dir .. "/keep.txt", { "k1", "k2", "k3" })
  h.edit(dir .. "/keep.txt")
  h.on_and_wait(function()
    return db().set("HEAD")
  end)
  h.eq("Δ HEAD +1 -3", db().status())
  h.eq({ added = 1, removed = 3, binary = false, new = false }, db().stats(dir), "stored (NFD) spelling")
  h.eq(3, db().stats(dir .. "/sub/gone.txt").removed, "the deleted file itself")
  h.no_warnings()
end

T["file names containing $NAME of a set environment variable are not expanded"] = function()
  h.ok(vim.env.HOME and vim.env.HOME ~= "", "HOME is set")
  local d = h.repo("envname")
  h.write(d .. "/a.txt", { "a" })
  h.commit(d, "init")
  h.write(d .. "/$HOME.txt", { "1", "2" })
  h.write(d .. "/$HOME/inner.txt", { "1" })
  local buf = h.edit(d .. "/$HOME.txt")
  h.on_and_wait(function()
    return db().set("HEAD")
  end)
  h.eq({ added = 2, removed = 0, binary = false, new = true }, db().stats(d .. "/$HOME.txt"))
  h.eq(2, db().stats().added, "current buffer")
  h.ok(h.newfile_marks(buf) > 0, "new-file extmarks")
  h.eq(1, db().stats(d .. "/$HOME").added, "directory named $HOME")
  h.eq(1, db().stats(d .. "/$HOME/").added, "trailing slash")
  -- A path that does not exist goes through normalize only; still no expansion.
  h.eq(d .. "/$HOME/gone.txt", require("diffbase.util").norm(d .. "/$HOME/gone.txt"))
end

T["a file replaced by a directory shows the directory's aggregate"] = function()
  local d = h.repo("filedir")
  h.write(d .. "/fd", { "old" })
  h.commit(d, "init")
  vim.fn.delete(d .. "/fd")
  h.write(d .. "/fd/inner", { "new" })
  h.write(d .. "/gone", { "x" })
  vim.cmd.cd(vim.fn.fnameescape(d))
  h.on_and_wait(function()
    return db().set("HEAD")
  end)
  h.eq({ added = 1, removed = 0, binary = false, new = false }, db().stats(d .. "/fd"))
  h.eq({ added = 1, removed = 0, binary = false, new = true }, db().stats(d .. "/fd/inner"))
end

T["a directory replaced by a file shows the file's counts"] = function()
  local d = h.repo("dirfile")
  h.write(d .. "/df/inner", { "old" })
  h.commit(d, "init")
  vim.fn.delete(d .. "/df", "rf")
  h.write(d .. "/df", { "new", "new2" })
  vim.cmd.cd(vim.fn.fnameescape(d))
  h.on_and_wait(function()
    return db().set("HEAD")
  end)
  h.eq({ added = 2, removed = 0, binary = false, new = true }, db().stats(d .. "/df"))
end

T["a submodule with modified content or untracked files is not counted"] = function()
  local sub = h.repo("sub")
  h.write(sub .. "/s.txt", { "s1" })
  h.commit(sub, "sub one")
  local d = h.repo("super")
  h.write(d .. "/a.txt", { "a1" })
  h.commit(d, "init")
  h.run({ "git", "-C", d, "-c", "protocol.file.allow=always", "submodule", "add", "-q", sub, "lib/sub" })
  h.commit(d, "add submodule")
  h.write(d .. "/lib/sub/s.txt", { "s1", "s2", "s3" })
  h.write(d .. "/lib/sub/u.txt", { "u" })
  h.write(d .. "/a.txt", { "a1", "a2" })
  h.edit(d .. "/a.txt")
  h.on_and_wait(function()
    return db().set("HEAD")
  end)
  h.eq(nil, db().stats(d .. "/lib/sub"), "no '+0 -0' on the submodule")
  h.eq(nil, db().stats(d .. "/lib"), "no '+0 -0' on its parent")
  h.eq("Δ HEAD +1 -0", db().status())
end

return T
