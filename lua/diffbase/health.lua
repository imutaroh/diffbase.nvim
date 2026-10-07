local M = {}

---@param name string
---@return string|nil version
local function plugin_version(name)
  local ok, lazy_cfg = pcall(require, "lazy.core.config")
  if ok and type(lazy_cfg) == "table" and type(lazy_cfg.plugins) == "table" then
    local p = lazy_cfg.plugins[name]
    if p and p.dir then
      local res = vim.system({ "git", "-C", p.dir, "describe", "--tags", "--always" }, { text = true }):wait()
      if res.code == 0 then
        return vim.trim(res.stdout)
      end
    end
  end
  return nil
end

function M.check()
  local health = vim.health
  health.start("diffbase")

  local v = vim.version()
  local vstr = ("%d.%d.%d"):format(v.major, v.minor, v.patch)
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. vstr)
  else
    health.error("Neovim >= 0.10 required, found " .. vstr)
  end

  if vim.fn.executable("git") == 1 then
    local res = vim.system({ "git", "--version" }, { text = true }):wait()
    local out = vim.trim(res.stdout or "")
    local major, minor = out:match("(%d+)%.(%d+)")
    major, minor = tonumber(major), tonumber(minor)
    if not major then
      health.warn("could not read the git version (" .. (out ~= "" and out or "no output") .. "); git >= 2.24 needed")
    elseif major < 2 or (major == 2 and minor < 24) then
      -- `rev-parse --end-of-options` (2.24) is used to resolve every base; older git rejects it.
      health.error(out .. ": git >= 2.24 required")
    else
      health.ok(out)
    end
  else
    health.error("git not found in PATH")
    return
  end

  health.start("diffbase: integrations")
  local cfg = require("diffbase.config").options
  if pcall(require, "gitsigns") then
    local ver = plugin_version("gitsigns.nvim")
    health.ok("gitsigns.nvim found" .. (ver and (" (" .. ver .. ")") or ""))
  else
    health.info(
      "gitsigns.nvim not found: no line/word highlights (stats, new-file highlight and statusline still work)"
    )
  end
  if not cfg.gitsigns.enabled then
    health.info("gitsigns integration disabled in config")
  end
  if pcall(require, "neo-tree") then
    local ver = plugin_version("neo-tree.nvim")
    local found = "neo-tree.nvim found" .. (ver and (" (" .. ver .. ")") or "")
    if not cfg.neotree.git_base then
      health.ok(found)
      health.info("diffbase leaves neo-tree's git base alone (`neotree.git_base = false`): its markers show HEAD")
    elseif require("diffbase.integrations.neotree")._git_base_supported() == false then
      health.warn(
        found
          .. ", but it is too old to use a git base (needs 3.42.0 or newer, commit 6679b93): diffbase will not set it",
        { "Update neo-tree.nvim (e.g. :Lazy update neo-tree.nvim)", "Or set `neotree = { git_base = false }`" }
      )
    else
      health.ok(found .. "; diffbase sets its git base (`neotree.git_base = true`)")
    end
  else
    health.info("neo-tree.nvim not found: no file tree counts")
  end

  health.start("diffbase: repository")
  -- Reported first and independently of root detection: the health buffer is not a file buffer.
  local info = require("diffbase").get()
  if info.base then
    health.info(("active: %s (%s)"):format(info.label or "?", info.base))
  end
  if info.detached_from then
    health.warn("in commit view (HEAD detached); return with :DiffBase back -> " .. info.detached_from)
  end

  local git = require("diffbase.git")
  local util = require("diffbase.util")
  -- The current buffer is the health buffer: try the active repository, then the buffer :checkhealth was
  -- run from, then cwd.
  local root = info.root
  if not root then
    local alt = vim.fn.bufnr("#")
    if alt > 0 and vim.api.nvim_buf_is_valid(alt) then
      root = git.root(util.buf_dir(alt))
    end
  end
  root = root or git.root(util.buf_dir())
  if not root then
    health.info("no git repository found (active state, previous buffer, cwd)")
    return
  end
  health.ok("repository: " .. root)
  local db = git.default_branch(root, cfg.default_branch)
  if db then
    health.ok("default branch: " .. db .. (cfg.default_branch and " (from config)" or " (detected)"))
  else
    health.warn("default branch not detected; set `default_branch` or run `git remote set-head origin --auto`")
  end
end

return M
