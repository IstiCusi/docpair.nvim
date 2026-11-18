local M = {}

function M.check()
  local c = require("docpair.compat").capabilities()
  vim.health.start("docpair.nvim")
  vim.health.info("Running Neovim: " .. c.version.major .. "." .. c.version.minor .. "." .. c.version.patch)
  vim.health.info("Executable: " .. c.executable)
  if not c.supported then
    vim.health.error("Neovim 0.10+ is required; the plugin remains disabled on this editor.")
  elseif not c.hide_comments then
    vim.health.ok("Editable comment views, external notes and window pairs are available.")
    vim.health.warn("Source comments stay visible. Whole-line hiding requires Neovim 0.11+.")
  else
    vim.health.ok("Editable comment views and window-scoped comment hiding are available.")
  end
end

return M
