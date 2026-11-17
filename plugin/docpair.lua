if vim.g.loaded_docpair then return end
vim.g.loaded_docpair = true
require("docpair").setup()
