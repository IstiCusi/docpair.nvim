return {
  "IstiCusi/docpair.nvim",
  lazy = false,
  opts = {
    initial_view = "text",
    views = { "text", "markdown", "raw", "notes" },
    mappings = { cycle = "g<Tab>", create = "<leader>dd", source = "<leader>ds" },
    comments = { hide = true, debounce_ms = 80 },
  },
}
