-- Files and views have separate lifetimes: several tabs may show the same
-- source at different positions while sharing one editable notes buffer.
local M = {}

function M.setup(options)
  -- Explicit setup in init.lua must not be replaced by the native plugin
  -- loader's defaults later in startup.
  vim.g.loaded_docpair = true
  local compat = require("docpair.compat")
  if not compat.capabilities().supported then
    -- An unsupported editor must not turn sourcing the entire user's config
    -- into an E5113 stack trace. Explain the minimum when the command is used.
    vim.api.nvim_create_user_command("Documented", function()
      vim.notify("docpair requires Neovim 0.10+; hiding source comments requires 0.11+. "
        .. "Use :version and :echo v:progpath to check the running editor.", vim.log.levels.WARN)
    end, { nargs = "*", bang = true, force = true })
    return false
  end
  local manager = require("docpair.manager")
  manager.setup(compat.configure(require("docpair.config").resolve(options)))
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
  vim.api.nvim_create_user_command("DocumentedView", function(command)
    manager.change_view(command.args ~= "" and command.args or nil)
  end, { nargs = "?", force = true, complete = function() return { "text", "markdown", "raw", "notes" } end,
    desc = "Cycle documentation views, or select a view by name" })
  vim.api.nvim_create_user_command("DocumentedAdd", manager.add_comment,
    { force = true, desc = "Create or open documentation at the source cursor" })
  vim.api.nvim_create_user_command("DocumentedSource", manager.toggle_source,
    { force = true, desc = "Show or hide comments in this source view" })
  vim.api.nvim_create_user_command("DocumentedDiscard", manager.discard_draft,
    { force = true, desc = "Discard an unapplied draft and reread the source comment" })
  vim.api.nvim_create_user_command("DocumentedDrafts", function()
    local drafts = require("docpair.views").drafts()
    if #drafts == 0 then vim.notify("docpair: no unapplied drafts"); return end
    vim.ui.select(drafts, { prompt = "Open unapplied draft", format_item = function(state)
      return state.record.source .. " — " .. (state.error or "pending edit")
    end }, function(state)
      if state then vim.cmd("tab sbuffer " .. state.buffer) end
    end)
  end, { force = true, desc = "Recover an unapplied draft after changing files" })
  return true
end

function M.inspect()
  return require("docpair.manager").inspect()
end

return M
