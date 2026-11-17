-- A record associates actual files, independently of tabs and window IDs.
-- bufload() reuses loaded buffers, preserving unsaved text and undo history.
local M = { sources = {}, notes = {} }
local api = vim.api

function M.path(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

function M.regular(buffer)
  return api.nvim_buf_is_valid(buffer) and vim.bo[buffer].buftype == ""
    and api.nvim_buf_get_name(buffer) ~= ""
end

function M.find(buffer)
  if not api.nvim_buf_is_valid(buffer) then return nil end
  local path = api.nvim_buf_get_name(buffer)
  return M.sources[path] or M.notes[path]
end

function M.is_notes(buffer)
  return api.nvim_buf_is_valid(buffer) and M.notes[api.nvim_buf_get_name(buffer)] ~= nil
end

local function notes_directory(source)
  local directory = vim.fs.dirname(source)
  local adjacent = directory .. "/.documented"
  local target = vim.fn.isdirectory(adjacent) == 1 and adjacent or directory
  if vim.fn.filewritable(target) == 2 then return adjacent end
  -- Keep existing fallback notes discoverable.
  return vim.fn.expand("~/.config/docpair/tree") .. directory
end

function M.register(source, notes_path)
  source, notes_path = M.path(source), M.path(notes_path)
  assert(source ~= notes_path, "source and notes must be different files")
  local previous = M.sources[source]
  assert(not previous or previous.notes == notes_path,
    "this source already has another notes file")
  local owner = M.notes[notes_path]
  assert(not owner or owner.source == source,
    "this notes file already belongs to another source")
  local record = previous or { source = source, notes = notes_path }
  M.sources[source], M.notes[notes_path] = record, record
  return record
end

function M.for_source(buffer, notes_name)
  assert(M.regular(buffer), "Documented requires a named, ordinary file buffer")
  local source = api.nvim_buf_get_name(buffer)
  if M.notes[source] then return M.notes[source] end
  if M.sources[source] and not notes_name then return M.sources[source] end
  local name = notes_name and vim.fs.basename(notes_name) or vim.fs.basename(source) .. "_info"
  assert(name ~= "" and name ~= "." and name ~= "..", "invalid notes filename")
  return M.register(source, notes_directory(source) .. "/" .. name)
end

function M.buffer(path)
  local buffer = vim.fn.bufadd(path)
  vim.fn.bufload(buffer)
  return buffer
end

function M.prepare(record, filetype, extend_padding)
  record.source_buffer = M.buffer(record.source)
  record.notes_buffer = M.buffer(record.notes)
  vim.bo[record.source_buffer].buflisted = true
  local notes_buffer = record.notes_buffer
  if vim.bo[notes_buffer].filetype ~= filetype then vim.bo[notes_buffer].filetype = filetype end
  -- :bnext should select source files, not auxiliary notebooks. Hidden edited
  -- notes still participate in :wall and prevent an unsafe :qall.
  vim.bo[notes_buffer].buflisted = false
  vim.bo[notes_buffer].bufhidden = "hide"
  if not record.prepared or extend_padding then
    local source_count = api.nvim_buf_line_count(record.source_buffer)
    local notes_count = api.nvim_buf_line_count(notes_buffer)
    local new_empty = vim.fn.filereadable(record.notes) == 0
      and not vim.bo[notes_buffer].modified and notes_count == 1
      and api.nvim_buf_get_lines(notes_buffer, 0, 1, false)[1] == ""
    if notes_count < source_count and vim.bo[notes_buffer].modifiable then
      local padding = {}
      for _ = notes_count + 1, source_count do padding[#padding + 1] = "" end
      api.nvim_buf_set_lines(notes_buffer, notes_count, notes_count, false, padding)
      -- Blank padding in a brand-new notebook is not a user edit. The first
      -- actual note marks it modified; writing persists all its blank lines.
      if new_empty then vim.bo[notes_buffer].modified = false end
    end
    record.prepared = true
  end
  return record
end

function M.reset()
  M.sources, M.notes = {}, {}
end

function M.rename(buffer)
  -- :file/:saveas rename buffers without changing their handles. Keep the
  -- association attached to that buffer, and never move a notes file on disk
  -- merely because its source was renamed. Sessions persist the new mapping.
  local path = api.nvim_buf_get_name(buffer)
  for _, record in pairs(M.sources) do
    if record.source_buffer == buffer and record.source ~= path then
      assert(not M.sources[path] and not M.notes[path], "renamed source conflicts with an existing pair")
      M.sources[record.source] = nil
      record.source = path
      M.sources[path] = record
      return
    elseif record.notes_buffer == buffer and record.notes ~= path then
      assert(not M.sources[path] and not M.notes[path], "renamed notes conflict with an existing pair")
      M.notes[record.notes] = nil
      record.notes = path
      M.notes[path] = record
      return
    end
  end
end

return M
