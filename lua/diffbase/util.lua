local M = {}

local uv = vim.uv or vim.loop

local PREFIX = "diffbase: "

---Notify with the plugin prefix.
---@param msg string
---@param level? integer vim.log.levels.*, defaults to INFO
function M.notify(msg, level)
  vim.notify(PREFIX .. msg, level or vim.log.levels.INFO)
end

---@param msg string
function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

-- Memo for norm(): realpath is a syscall and neo-tree calls the component for every node on every render.
-- Cleared whenever stats are recomputed.
local norm_cache = {}
local keys_cache = {}

---vim.fs.normalize without environment-variable expansion: a file may be named "$HOME.txt".
---@param path string
---@return string
local function normalize(path)
  return vim.fs.normalize(path, { expand_env = false })
end
M.normalize = normalize

---Normalize a path so it can be used as a lookup key: realpath when the path exists
---(macOS /tmp -> /private/tmp, symlinked checkouts), otherwise normalize() (no env expansion).
---@param path string
---@return string
function M.norm(path)
  local cached = norm_cache[path]
  if cached then
    return cached
  end
  local real = uv.fs_realpath(path)
  local result = normalize(real or path)
  if #result > 1 and result:sub(-1) == "/" then
    result = result:sub(1, -2)
  end
  norm_cache[path] = result
  return result
end

function M.clear_norm_cache()
  norm_cache = {}
  keys_cache = {}
end

---Like norm(), but keeps the last path component as is: only the parent directory is resolved. A symlink
---then maps to its own path (as git reports a tracked symlink) instead of its target's.
---@param path string
---@return string
local function norm_keep_last(path)
  local p = normalize(path)
  if #p > 1 and p:sub(-1) == "/" then
    p = p:sub(1, -2)
  end
  local dir, base = vim.fs.dirname(p), vim.fs.basename(p)
  if not dir or base == "" or dir == p then
    return M.norm(path)
  end
  local real_dir = uv.fs_realpath(dir)
  if not real_dir then
    return M.norm(path)
  end
  return M.join(normalize(real_dir), base)
end

---Keys to try, in order, when looking up stats for `path`: the path with only its parent resolved (a
---tracked symlink has its own stats), then the fully resolved path (a link from outside the repository into
---it, or a symlinked checkout).
---@param path string
---@return string[]
function M.lookup_keys(path)
  local cached = keys_cache[path]
  if cached then
    return cached
  end
  local own, target = norm_keep_last(path), M.norm(path)
  local keys = own == target and { own } or { own, target }
  keys_cache[path] = keys
  return keys
end

---Join a normalized root and a git-relative path.
---@param root string
---@param rel string
---@return string
function M.join(root, rel)
  if root == "/" then
    return "/" .. rel
  end
  return root .. "/" .. rel
end

---Directory to start root detection from: the buffer's directory for normal file buffers, else cwd.
---@param buf? integer
---@return string
function M.buf_dir(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" then
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" and not name:match("^%a[%w+.-]*://") then
      -- Resolve the file first: a symlinked file (e.g. ~/.zshrc -> ~/dotfiles/.zshrc) belongs to the
      -- repository of its target, not of the directory holding the link.
      local dir = vim.fs.dirname(uv.fs_realpath(name) or name)
      if dir and uv.fs_stat(dir) then
        return dir
      end
    end
  end
  return uv.cwd() or "."
end

---Split a NUL-separated string, dropping empty trailing fields.
---@param s string
---@return string[]
function M.split_nul(s)
  local out = {}
  for field in (s or ""):gmatch("([^%z]+)") do
    out[#out + 1] = field
  end
  return out
end

---Create a trailing-edge debouncer backed by a single reusable timer.
---@param fn fun()
---@return { call: fun(ms: integer), cancel: fun() }
function M.debouncer(fn)
  local timer
  local d = {}
  function d.cancel()
    if timer then
      timer:stop()
    end
  end
  function d.call(ms)
    if not timer or timer:is_closing() then
      timer = uv.new_timer()
    end
    timer:stop()
    timer:start(ms, 0, vim.schedule_wrap(fn))
  end
  return d
end

return M
