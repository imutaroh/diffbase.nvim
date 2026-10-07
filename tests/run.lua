-- Test runner: nvim --headless --clean -l tests/run.lua [filter]
-- Discovers tests/*_spec.lua (each returns { ["test name"] = fn, ... }), runs them in sorted order and exits
-- non-zero on any failure. No external dependencies.

local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(vim.fn.fnamemodify(source, ":p"), ":h:h")
vim.opt.rtp:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

-- Isolate git from the user's configuration (signing, hooks, templates, default branch, identity).
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_NOSYSTEM = "1"
vim.env.GIT_AUTHOR_NAME = "diffbase test"
vim.env.GIT_AUTHOR_EMAIL = "test@example.com"
vim.env.GIT_COMMITTER_NAME = "diffbase test"
vim.env.GIT_COMMITTER_EMAIL = "test@example.com"
vim.env.GIT_TERMINAL_PROMPT = "0"

-- --clean implies -u NONE, which skips plugin/ scripts.
vim.cmd("runtime! plugin/diffbase.lua")

local h = require("helpers")
h.init(root)
-- tests/.tmp lives inside this plugin's own checkout: stop git discovery there so "not a repository" cases
-- are real and fixtures never resolve to the plugin repo.
-- (git still walks up from the ceiling directory itself, so use its parent.)
vim.env.GIT_CEILING_DIRECTORIES = vim.fs.dirname(h.tmp)

local filter = _G.arg and _G.arg[1] or nil

local files = vim.fn.glob(root .. "/tests/*_spec.lua", false, true)
table.sort(files)

local passed, failed, failures = 0, 0, {}

for _, file in ipairs(files) do
  local suite = vim.fn.fnamemodify(file, ":t:r")
  local ok, tests = pcall(dofile, file)
  if not ok or type(tests) ~= "table" then
    failed = failed + 1
    failures[#failures + 1] = ("%s: failed to load: %s"):format(suite, tostring(tests))
    io.write(("FAIL %s (load)\n  %s\n"):format(suite, tostring(tests)))
  else
    local names = vim.tbl_keys(tests)
    table.sort(names)
    for _, name in ipairs(names) do
      local full = suite .. " :: " .. name
      if not filter or full:find(filter, 1, true) then
        h.reset()
        local tok, err = xpcall(tests[name], debug.traceback)
        local notes = vim.deepcopy(h.notifications())
        local cok, cerr = pcall(h.reset)
        if tok and not cok then
          tok, err = false, "reset failed: " .. tostring(cerr)
        end
        if tok then
          passed = passed + 1
          io.write("ok   " .. full .. "\n")
        else
          failed = failed + 1
          failures[#failures + 1] = full .. "\n    " .. tostring(err):gsub("\n", "\n    ")
          io.write("FAIL " .. full .. "\n")
          if #notes > 0 then
            io.write("    notifications:\n")
            for _, n in ipairs(notes) do
              io.write("      [" .. n.level .. "] " .. n.msg:gsub("\n", " | ") .. "\n")
            end
          end
        end
      end
    end
  end
end

h.teardown()

if #failures > 0 then
  io.write("\nFailures:\n")
  for _, f in ipairs(failures) do
    io.write("  " .. f .. "\n")
  end
end
io.write(("\n%d passed, %d failed\n"):format(passed, failed))
io.flush()
os.exit(failed > 0 and 1 or 0)
