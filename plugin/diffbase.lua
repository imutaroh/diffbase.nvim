if vim.g.loaded_diffbase then
  return
end
vim.g.loaded_diffbase = true

if vim.fn.has("nvim-0.10") ~= 1 then
  vim.notify("diffbase: requires Neovim >= 0.10", vim.log.levels.WARN)
  return
end

vim.api.nvim_create_user_command("DiffBase", function(cmd)
  local ok, err = pcall(function()
    require("diffbase")._command(cmd.fargs)
  end)
  if not ok then
    vim.notify("diffbase: " .. tostring(err), vim.log.levels.WARN)
  end
end, {
  nargs = "*",
  bar = true, -- ":DiffBase off | DiffBase main"; refs cannot contain "|"
  desc = "Choose what to diff against (pick, main, previous, unpushed, commit, back, off, refresh, ref <ref>)",
  complete = function(arglead, cmdline)
    local ok, diffbase = pcall(require, "diffbase")
    if not ok then
      return {}
    end
    -- Arguments before the one being completed. Parse the command line so modifiers and ranges
    -- (":silent DiffBase ", ":vert DiffBase ref ") do not shift the words.
    local before = cmdline:sub(1, #cmdline - #arglead)
    local args
    local pok, parsed = pcall(vim.api.nvim_parse_cmd, before, {})
    if pok and type(parsed) == "table" and type(parsed.args) == "table" then
      args = parsed.args
    else
      local rest = before:match("DiffB%a*!?%s+(.*)$") or ""
      args = vim.split(rest, "%s+", { trimempty = true })
    end
    if #args >= 1 then
      if args[1] == "ref" and #args == 1 then
        local refs = vim.fn.systemlist({
          "git",
          "-C",
          require("diffbase.util").buf_dir(),
          "for-each-ref",
          "--format=%(refname:short)",
          "refs/heads",
          "refs/remotes",
          "refs/tags",
        })
        if vim.v.shell_error ~= 0 then
          return {}
        end
        table.insert(refs, 1, "HEAD")
        return vim.tbl_filter(function(r)
          return vim.startswith(r, arglead)
        end, refs)
      end
      return {}
    end
    return vim.tbl_filter(function(s)
      return vim.startswith(s, arglead)
    end, diffbase._subcommands())
  end,
})
