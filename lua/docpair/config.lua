local M = {}

M.defaults = {
  info_filetype = "markdown",
  initial_view = "text",
  views = { "text", "markdown", "raw", "notes" },
  mappings = { cycle = "g<Tab>", create = "<leader>dd", source = "<leader>ds" },
  comments = { hide = true, debounce_ms = 80 },
  -- Optional renderer integration; called only on entering Markdown view.
  on_markdown = false,
}

function M.resolve(options)
  local result = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), options or {})
  -- Lists are replacements, not merges with the default tail.
  if options and options.views then result.views = vim.deepcopy(options.views) end
  local allowed, seen = { text = true, markdown = true, raw = true, notes = true }, {}
  assert(type(result.views) == "table" and #result.views > 0, "views must not be empty")
  for _, name in ipairs(result.views) do
    assert(allowed[name] and not seen[name], "unknown or duplicate view: " .. tostring(name))
    seen[name] = true
  end
  assert(seen[result.initial_view], "initial_view must be included in views")
  for name, key in pairs(result.mappings) do
    assert(type(key) == "string" or key == false, "mapping " .. name .. " must be a string or false")
  end
  assert(type(result.comments.debounce_ms) == "number" and result.comments.debounce_ms >= 0,
    "comments.debounce_ms must be nonnegative")
  assert(result.on_markdown == false or type(result.on_markdown) == "function", "on_markdown must be a function or false")
  return result
end

return M
