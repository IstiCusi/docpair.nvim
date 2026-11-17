-- Files and views have separate lifetimes: several tabs may show the same
-- source at different positions while sharing one editable notes buffer.
local M = {}

function M.setup(options)
  -- Explicit setup in init.lua must not be replaced by the native plugin
  -- loader's defaults later in startup.
  vim.g.loaded_docpair = true
  local manager = require("docpair.manager")
  manager.setup(vim.tbl_extend("force", { info_filetype = "markdown" }, options or {}))
  vim.api.nvim_create_user_command("Documented", function(command)
    local ok, message = pcall(manager.open, command.fargs, command.bang)
    if not ok then vim.notify("docpair: " .. tostring(message), vim.log.levels.ERROR) end
  end, { nargs = "*", bang = true, complete = "file", force = true,
    desc = "Open source and notes as a managed window pair" })
  vim.api.nvim_create_user_command("DocumentedClose", manager.close_current,
    { desc = "Close the pair; retain edited buffers", force = true })
  vim.api.nvim_create_user_command("DocumentedDetach", manager.detach_current,
    { desc = "Release this pair without closing its windows", force = true })
  vim.api.nvim_create_user_command("DocumentedRepair", manager.reconcile,
    { desc = "Repair pairs after commands that suppressed events", force = true })
end

function M.inspect()
  return require("docpair.manager").inspect()
end

return M
