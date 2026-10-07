-- Git helpers. Every command is an argv list (no shell). Quick one-shots at user-action time are
-- synchronous; the potentially slow stats computation is asynchronous.
local util = require("diffbase.util")

local M = {}

-- Avoid taking index.lock for read-only background commands.
local ENV = { GIT_OPTIONAL_LOCKS = "0" }

M.EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

---@class diffbase.GitResult
---@field code integer
---@field stdout string
---@field stderr string

---@param root string|nil
---@param args string[]
---@return string[]
local function argv(root, args)
  local cmd = { "git" }
  if root then
    vim.list_extend(cmd, { "-C", root })
  end
  return vim.list_extend(cmd, args)
end

---Run git synchronously.
---@param root string|nil
---@param args string[]
---@return diffbase.GitResult
function M.run_sync(root, args)
  local ok, res = pcall(function()
    return vim.system(argv(root, args), { text = true, env = ENV }):wait()
  end)
  if not ok or not res then
    return { code = -1, stdout = "", stderr = tostring(res) }
  end
  return { code = res.code, stdout = res.stdout or "", stderr = res.stderr or "" }
end

---Run git synchronously and return the first stdout line on success.
---@param root string|nil
---@param args string[]
---@return string|nil
function M.line(root, args)
  local res = M.run_sync(root, args)
  if res.code ~= 0 then
    return nil
  end
  local first = res.stdout:match("^([^\n]*)")
  if not first or first == "" then
    return nil
  end
  return first
end

---Run git asynchronously; `cb` is called on the main loop.
---@param root string|nil
---@param args string[]
---@param cb fun(res: diffbase.GitResult)
function M.run(root, args, cb)
  local done = vim.schedule_wrap(cb)
  local ok, err = pcall(vim.system, argv(root, args), { text = true, env = ENV }, function(res)
    done({ code = res.code, stdout = res.stdout or "", stderr = res.stderr or "" })
  end)
  if not ok then
    done({ code = -1, stdout = "", stderr = tostring(err) })
  end
end

---Repository top-level containing `dir` (normalized), or nil.
---@param dir string
---@return string|nil
function M.root(dir)
  local top = M.line(nil, { "-C", dir, "rev-parse", "--show-toplevel" })
  return top and util.norm(top) or nil
end

---@param root string
---@param ref string
---@return boolean
function M.ref_exists(root, ref)
  return M.line(root, { "rev-parse", "--verify", "--quiet", "--end-of-options", ref .. "^{commit}" }) ~= nil
end

---Detect the default branch: origin/HEAD, then origin/main, origin/master, main, master.
---@param root string
---@param override? string
---@return string|nil
function M.default_branch(root, override)
  if override and override ~= "" then
    return override
  end
  local head = M.line(root, { "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD" })
  if head and M.ref_exists(root, head) then
    return head
  end
  for _, cand in ipairs({ "origin/main", "origin/master", "main", "master" }) do
    if M.ref_exists(root, cand) then
      return cand
    end
  end
  return nil
end

---Resolve a ref to a commit sha, optionally via merge-base with HEAD.
---@param root string
---@param ref string
---@param merge_base? boolean
---@return string|nil sha
---@return string|nil err
function M.resolve(root, ref, merge_base)
  local sha = M.line(root, { "rev-parse", "--verify", "--quiet", "--end-of-options", ref .. "^{commit}" })
  if not sha then
    return nil, ("'%s' not found"):format(ref)
  end
  if merge_base then
    local mb = M.line(root, { "merge-base", sha, "HEAD" })
    if not mb then
      return nil, ("no common ancestor between '%s' and HEAD"):format(ref)
    end
    return mb
  end
  return sha
end

---True when tracked files have uncommitted changes (staged or not). Submodules are ignored: `git switch`
---does not update submodule worktrees, so after detaching a submodule's checked-out commit no longer matches
---the gitlink even though nothing was changed (and switching back does not touch it either).
---@param root string
---@return boolean
function M.is_dirty(root)
  local res = M.run_sync(root, { "status", "--porcelain", "--untracked-files=no", "--ignore-submodules=all" })
  return res.code ~= 0 or res.stdout ~= ""
end

---@param root string
---@return string|nil
function M.current_branch(root)
  return M.line(root, { "branch", "--show-current" })
end

---Explain why `@{upstream}` does not resolve: detached HEAD, no upstream configured, or upstream gone.
---@param root string
---@return string
function M.upstream_problem(root)
  local branch = M.current_branch(root)
  if not branch then
    return "HEAD is detached; 'unpushed' needs a branch with an upstream"
  end
  local res = M.run_sync(root, {
    "for-each-ref",
    "--format=%(upstream:short)%09%(upstream:track)",
    "refs/heads/" .. branch,
  })
  local upstream, track = res.stdout:match("^([^\t\n]*)\t([^\n]*)")
  if res.code ~= 0 or not upstream or upstream == "" then
    return ("no upstream branch is configured for '%s'"):format(branch)
  end
  if track:find("gone", 1, true) then
    return ("the upstream branch '%s' of '%s' is gone (deleted on the remote)"):format(upstream, branch)
  end
  return ("the upstream branch '%s' of '%s' could not be resolved"):format(upstream, branch)
end

---@param root string
---@param ref string
---@param detach boolean
---@return boolean ok
---@return string|nil err
function M.switch(root, ref, detach)
  local args = { "switch", "--quiet" }
  if detach then
    args[#args + 1] = "--detach"
  end
  args[#args + 1] = ref
  local res = M.run_sync(root, args)
  if res.code ~= 0 then
    return false, vim.trim(res.stderr)
  end
  return true
end

---@class diffbase.Commit
---@field sha string
---@field text string "<short> <subject>"

---Commits for the commit-view picker: `<default_branch>..<tip>` if non-empty, else the last `limit` commits.
---@param root string
---@param default_branch string|nil
---@param limit integer
---@param tip? string commit to list from (default HEAD); in commit view, the branch `back` returns to
---@return diffbase.Commit[]
function M.commits(root, default_branch, limit, tip)
  tip = tip or "HEAD"
  local args = { "log", "--format=%H%x09%h %s" }
  local use_range = false
  if default_branch then
    local n = tonumber(M.line(root, { "rev-list", "--count", default_branch .. ".." .. tip, "--" }) or "")
    use_range = n ~= nil and n > 0
  end
  if use_range then
    vim.list_extend(args, { default_branch .. ".." .. tip, "--" })
  else
    vim.list_extend(args, { "-n", tostring(limit), tip, "--" })
  end
  local res = M.run_sync(root, args)
  local out = {}
  if res.code ~= 0 then
    return out
  end
  for line in res.stdout:gmatch("[^\n]+") do
    local sha, text = line:match("^(%x+)\t(.*)$")
    if sha then
      out[#out + 1] = { sha = sha, text = text }
    end
  end
  return out
end

---Parent of a commit, or the empty tree for a root commit.
---@param root string
---@param sha string
---@return string parent
---@return boolean is_root
function M.parent(root, sha)
  local parent = M.line(root, { "rev-parse", "--verify", "--quiet", sha .. "^" })
  if parent then
    return parent, false
  end
  return M.line(root, { "hash-object", "-t", "tree", "/dev/null" }) or M.EMPTY_TREE, true
end

---@class diffbase.ComputeResult
---@field files table<string, diffbase.Stat> keyed by normalized absolute path
---@field dirs table<string, diffbase.Stat> aggregated per directory (root included)

local uv = vim.uv or vim.loop

---Stats key for a git-relative path: root .. "/" .. rel, but spelled as stored on disk. git may report a name
---in another Unicode normalization form than the file system stores (macOS: core.precomposeunicode makes git
---print NFC while names created by Finder and many tools are stored NFD), and neo-tree / buffer names use the
---stored form. fs_realpath returns the stored form; only non-ASCII paths can differ, so only those pay for it.
---A symlink keeps its own path (only its parent is resolved), like util.lookup_keys does.
---@param root string
---@param rel string
---@return string
local function key_for(root, rel)
  local abs = util.join(root, rel)
  if not rel:find("[\128-\255]") then
    return abs
  end
  local st = uv.fs_lstat(abs)
  if st and st.type ~= "link" then
    return uv.fs_realpath(abs) or abs
  end
  -- A symlink, or a path that no longer exists (deleted file, possibly in a deleted directory): resolve the
  -- nearest existing ancestor, so the directories that still exist get the stored spelling (their keys are
  -- what neo-tree asks for). The missing components keep git's spelling (they cannot be resolved).
  local tail = vim.fs.basename(abs)
  local dir = vim.fs.dirname(abs)
  while dir and dir ~= abs and #dir >= #root do
    local real_dir = uv.fs_realpath(dir)
    if real_dir then
      return util.join(real_dir, tail)
    end
    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then
      break
    end
    tail = vim.fs.basename(dir) .. "/" .. tail
    dir = parent
  end
  return abs
end
M._key_for = key_for

---@param out diffbase.ComputeResult
---@param root string
---@param abs string
---@param stat diffbase.Stat
local function add_file(out, root, abs, stat)
  out.files[abs] = stat
  local dir = vim.fs.dirname(abs)
  while dir and #dir >= #root do
    local sum = out.dirs[dir]
    if not sum then
      sum = { added = 0, removed = 0, binary = false, new = false }
      out.dirs[dir] = sum
    end
    sum.added = sum.added + stat.added
    sum.removed = sum.removed + stat.removed
    if dir == root then
      break
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
end

---@param a string
---@param d string
---@return integer added
---@return integer removed
---@return boolean binary
local function parse_counts(a, d)
  if a == "-" and d == "-" then
    return 0, 0, true
  end
  return tonumber(a) or 0, tonumber(d) or 0, false
end

local UNTRACKED_CONCURRENCY = 8

---Compute per-file and per-directory line stats of the working tree against `base`, asynchronously.
---@param root string normalized repository root
---@param base string commit or tree sha
---@param include_untracked boolean
---@param is_current fun(): boolean false once the result is no longer wanted: stop starting git processes
---@param cb fun(result: diffbase.ComputeResult|nil, err: string|nil) called on the main loop; not called after
---is_current() turned false
function M.compute(root, base, include_untracked, is_current, cb)
  local numstat, added_names, untracked
  local pending = include_untracked and 3 or 2
  local failed

  local function finish()
    if not is_current() then
      return
    end
    if failed then
      return cb(nil, failed)
    end
    local out = { files = {}, dirs = {} }
    local is_new = {}
    for _, rel in ipairs(added_names) do
      is_new[rel] = true
    end
    for _, rec in ipairs(numstat) do
      local a, r, bin = parse_counts(rec.a, rec.d)
      add_file(
        out,
        root,
        key_for(root, rec.path),
        { added = a, removed = r, binary = bin, new = is_new[rec.path] == true }
      )
    end
    if not untracked or #untracked == 0 then
      return cb(out)
    end

    -- Untracked files are invisible to `git diff <base>`: count each against /dev/null.
    local queue, idx, running, left = untracked, 0, 0, #untracked
    local function pump()
      if not is_current() then
        return
      end
      while running < UNTRACKED_CONCURRENCY and idx < #queue do
        idx = idx + 1
        local rel = queue[idx]
        running = running + 1
        M.run(root, { "diff", "--no-index", "--numstat", "--", "/dev/null", rel }, function(res)
          running = running - 1
          left = left - 1
          if not is_current() then
            return
          end
          -- Exit code 1 means "there is a difference" for --no-index, but git also exits 1 on errors such as
          -- "Could not access 'dirlink/null'" (an untracked symlink to a directory): require a numstat line.
          -- An empty file still yields one ("0\t0\t...").
          local a, d = res.stdout:match("^(%S+)\t(%S+)\t")
          if (res.code == 0 or res.code == 1) and a then
            local added, removed, bin = parse_counts(a, d)
            add_file(out, root, key_for(root, rel), { added = added, removed = removed, binary = bin, new = true })
          end
          if left == 0 then
            cb(out)
          else
            pump()
          end
        end)
      end
    end
    pump()
  end

  local function done_one()
    pending = pending - 1
    if pending == 0 then
      finish()
    end
  end

  -- Submodules (gitlinks) are skipped: their changes are not lines of this repository, and a submodule with
  -- modified content would only show up as "+0 -0".
  local numstat_args =
    { "diff", "--numstat", "-z", "--no-renames", "--no-ext-diff", "--ignore-submodules=all", base, "--" }
  M.run(root, numstat_args, function(res)
    if res.code ~= 0 then
      failed = failed or vim.trim(res.stderr)
      numstat = {}
    else
      numstat = {}
      -- With -z and no renames each record is "<added>\t<removed>\t<path>\0".
      for _, rec in ipairs(util.split_nul(res.stdout)) do
        local a, d, path = rec:match("^(%S+)\t(%S+)\t(.*)$")
        if path then
          numstat[#numstat + 1] = { a = a, d = d, path = path }
        end
      end
    end
    done_one()
  end)

  local added_args =
    { "diff", "--name-only", "-z", "--no-renames", "--ignore-submodules=all", "--diff-filter=A", base, "--" }
  M.run(root, added_args, function(res)
    added_names = res.code == 0 and util.split_nul(res.stdout) or {}
    done_one()
  end)

  if include_untracked then
    M.run(root, { "ls-files", "--others", "--exclude-standard", "-z" }, function(res)
      untracked = {}
      if res.code == 0 then
        for _, rel in ipairs(util.split_nul(res.stdout)) do
          -- A trailing slash marks an untracked nested repository: not a file of this one.
          if rel:sub(-1) ~= "/" then
            untracked[#untracked + 1] = rel
          end
        end
      end
      done_one()
    end)
  end
end

return M
