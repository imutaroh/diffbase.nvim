-- Files absent in the base (added on this branch, or untracked) get no hunks from gitsigns when the file
-- is brand new to it, so paint every line green with extmarks.
local M = {}

M.ns = vim.api.nvim_create_namespace("diffbase_newfile")

-- buf -> line count at the time it was marked; lets TextChanged skip work when nothing moved.
---@type table<integer, integer>
local marked = {}

---@param buf integer
function M.clear(buf)
  marked[buf] = nil
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  end
end

function M.clear_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    M.clear(buf)
  end
  marked = {}
end

---@param buf integer
---@param is_new fun(path: string): boolean called with the buffer name; normalizes it itself
---@param force? boolean re-mark even if the line count did not change
function M.mark(buf, is_new, force)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= "" then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or not is_new(name) then
    if marked[buf] then
      M.clear(buf)
    end
    return
  end
  local count = vim.api.nvim_buf_line_count(buf)
  if not force and marked[buf] == count then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for row = 0, count - 1 do
    vim.api.nvim_buf_set_extmark(buf, M.ns, row, 0, {
      line_hl_group = "DiffBaseNewLine",
      number_hl_group = "DiffBaseNewNr",
      priority = 5,
    })
  end
  marked[buf] = count
end

---@param is_new fun(path: string): boolean
function M.mark_all(is_new)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    M.mark(buf, is_new, true)
  end
end

return M
