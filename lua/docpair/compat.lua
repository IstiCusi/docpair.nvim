-- Gate only the APIs we actually need. Whole-line concealment and scoped
-- namespaces landed in 0.11, not 0.12. On 0.10 the editable projections still
-- work; their source comments must remain visible.
local M = {}

function M.capabilities()
  return {
    supported = vim.fn.has("nvim-0.10") == 1,
    hide_comments = vim.fn.has("nvim-0.11") == 1 and type(vim.api.nvim__ns_set) == "function",
    executable = vim.v.progpath,
    version = vim.version(),
  }
end

function M.configure(options)
  local capabilities = M.capabilities()
  options.capabilities = capabilities
  if not capabilities.hide_comments then options.comments.hide = false end
  return options
end

return M
