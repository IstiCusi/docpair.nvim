-- Each pair has its own projection, cursor and reading position. Source text
-- remains in ONE ordinary file buffer. Projections are acwrite buffers whose
-- write command saves that source; they are never files on disk.
local M = {}
local api = vim.api
local storage = require("docpair.storage")
local comments = require("docpair.comments")
local config, callbacks = {}, {}
local states, watched, active, conceal = {}, {}, {}, {}
local serial, writing = 0, false

local function valid(window) return window and api.nvim_win_is_valid(window) end
local function source_valid(state) return api.nvim_buf_is_valid(state.source) and api.nvim_buf_is_loaded(state.source) end
local function notify(message) vim.notify("docpair: " .. tostring(message), vim.log.levels.WARN) end
local function snapshot(window) return api.nvim_win_call(window, vim.fn.winsaveview) end

local function set_text(state, lines)
  if #lines == 0 then lines = { "" } end
  local buffer = state.buffer
  if vim.deep_equal(api.nvim_buf_get_lines(buffer, 0, -1, false), lines) then
    vim.bo[buffer].modified = false; return
  end
  local positions = {}
  for _, window in ipairs(vim.fn.win_findbuf(buffer)) do positions[window] = snapshot(window) end
  state.updating = true
  local modifiable, undo = vim.bo[buffer].modifiable, vim.bo[buffer].undolevels
  vim.bo[buffer].modifiable = true
  -- Display refreshes do not belong to the user's source undo history. Normal
  -- u/C-r in a projection are routed to the authoritative source below.
  vim.bo[buffer].undolevels = -1
  api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].undolevels = undo
  vim.bo[buffer].modified, vim.bo[buffer].modifiable = false, modifiable
  state.updating, state.dirty = false, false
  for window, position in pairs(positions) do
    if valid(window) then
      position.lnum, position.topline = math.min(position.lnum, #lines), math.min(position.topline, #lines)
      api.nvim_win_call(window, function() vim.fn.winrestview(position) end)
    end
  end
end

local function label(pair, state)
  if not valid(pair.notes_window) then return end
  local name = pair.mode == "notes" and "Notes" or pair.mode == "raw" and "Original" or pair.mode == "markdown" and "Markdown" or "Text"
  local suffix = state and state.error and " | DRAFT: " .. state.error
    or state and state.item and (" | source line " .. (state.item.first + 1)
      .. (state.item.semantic and " | syntax scope" or " | nearest comment")) or " | no comment here"
  if pair.mode == "notes" then suffix = " | external file" end
  vim.wo[pair.notes_window].winbar = ("Docpair · " .. name .. suffix):gsub("%%", "%%%%")
end

local function save_position(pair)
  if not valid(pair.notes_window) then return end
  pair.doc_positions = pair.doc_positions or {}
  local key = pair.mode .. ":" .. tostring(pair.current_comment or "none")
  pair.doc_positions[key] = snapshot(pair.notes_window)
end

local function restore_position(pair)
  local key = pair.mode .. ":" .. tostring(pair.current_comment or "none")
  local saved = pair.doc_positions and pair.doc_positions[key]
  if saved then
    api.nvim_win_call(pair.notes_window, function() vim.fn.winrestview(saved) end)
  else api.nvim_win_set_cursor(pair.notes_window, { 1, 0 }) end
end

local function format_window(pair)
  local window = pair.notes_window
  vim.wo[window].scrollbind, vim.wo[window].cursorbind = false, false
  vim.wo[window].wrap, vim.wo[window].linebreak = pair.mode ~= "notes", pair.mode ~= "notes"
  vim.wo[window].conceallevel = pair.mode == "markdown" and 2 or 0
  vim.wo[window].concealcursor = "nc"
  local state = states[pair.doc_buffer]
  if state then
    local ft = pair.mode == "raw" and comments.filetype(state.source) or pair.mode == "markdown" and "markdown" or "text"
    if vim.bo[state.buffer].filetype ~= ft then vim.bo[state.buffer].filetype = ft end
    vim.bo[state.buffer].syntax = ft == "text" and "" or ft
  end
  label(pair, state)
end

function M.flush(state, quiet)
  if not state or state.updating or not state.dirty then return true end
  local ok, message = pcall(function()
    assert(source_valid(state), "source is unavailable; draft retained")
    assert(state.item, "no comment selected; use DocumentedAdd in the source")
    assert(vim.bo[state.source].modifiable and not vim.bo[state.source].readonly, "source is read-only; draft retained")
    local text = api.nvim_buf_get_lines(state.buffer, 0, -1, false)
    local raw = state.mode == "raw" and comments.validate_raw(state.source, state.item, text) or comments.encode(state.item, text)
    if not vim.deep_equal(raw, state.item.raw) then
      if state.pending_generation and state.pending_generation == state.join_generation
        and state.join_tick == api.nvim_buf_get_changedtick(state.source) then
        -- One continuous insertion in the doc pane should undo as one source
        -- edit. Never join across intervening source edits or Insert sessions.
        pcall(api.nvim_buf_call, state.source, function() vim.cmd("undojoin") end)
      end
      writing = true
      local succeeded, result = pcall(comments.replace, state.source, state.item, raw, state.mode == "raw")
      writing = false
      assert(succeeded, result)
      assert(result, "comment is no longer recognized; source and draft retained")
      state.item = result
      state.join_tick = api.nvim_buf_get_changedtick(state.source)
      state.join_generation = state.pending_generation
    end
    state.dirty, state.error = false, nil
    vim.bo[state.buffer].modified = false
  end)
  writing = false
  if not ok then
    state.error = tostring(message):gsub("^.-:%d+: ", "")
    if not quiet and state.reported ~= state.error then notify(state.error); state.reported = state.error end
  else state.reported = nil end
  for _, pair in pairs(active) do if pair.doc_buffer == state.buffer then label(pair, state) end end
  if ok then M.refresh_source(state.source) end
  return ok, state.error
end

function M.flush_source(buffer)
  for _, state in pairs(states) do
    if state.source == buffer then
      local ok, message = M.flush(state, true)
      assert(ok, "docpair: " .. tostring(message))
    end
  end
end

function M.can_leave(pair)
  local ok = M.flush(states[pair.doc_buffer])
  if not ok then notify("repair the draft or use :DocumentedDiscard before changing its view") end
  return ok
end

local function write_source(state, event)
  assert(source_valid(state), "docpair: source is no longer available")
  -- :write path / :saveas on a projection must not create a misleading file
  -- containing a fragment. Rename/export the ordinary source instead.
  assert(event.match == api.nvim_buf_get_name(state.buffer), "docpair: write the source buffer to another filename")
  M.flush_source(state.source)
  api.nvim_buf_call(state.source, function() vim.cmd("write") end)
  vim.bo[state.buffer].modified = false
end

local function make_state(record)
  local name
  repeat
    serial = serial + 1
    name = "docpair://" .. serial .. "/" .. vim.fs.basename(record.source)
  until vim.fn.bufnr(name) == -1
  local buffer = api.nvim_create_buf(false, true)
  local state = { buffer = buffer, source = record.source_buffer, record = record, mode = "text", name = name }
  states[buffer], storage.views[buffer] = state, record
  api.nvim_buf_set_name(buffer, name)
  vim.bo[buffer].buftype, vim.bo[buffer].bufhidden = "acwrite", "hide"
  vim.bo[buffer].swapfile, vim.bo[buffer].undofile = false, false
  api.nvim_create_autocmd("BufWriteCmd", { buffer = buffer, callback = function(event) write_source(state, event) end })
  api.nvim_create_autocmd("BufFilePre", { buffer = buffer, callback = function()
    error("docpair: rename or :saveas the source buffer, not its comment projection")
  end })
  api.nvim_create_autocmd("InsertEnter", { buffer = buffer, callback = function()
    state.insert_generation = (state.insert_generation or 0) + 1
  end })
  api.nvim_buf_attach(buffer, false, { on_lines = function()
    if state.updating then return end
    state.dirty = true
    state.pending_generation = api.nvim_get_mode().mode:sub(1, 1) == "i" and state.insert_generation or nil
    if not state.queued then
      state.queued = true
      vim.schedule(function()
        state.queued = false
        if api.nvim_buf_is_valid(buffer) then M.flush(state) end
      end)
    end
  end, on_detach = function() states[buffer], storage.views[buffer] = nil, nil end })
  for key, command in pairs({ u = "undo", ["<C-r>"] = "redo" }) do
    vim.keymap.set("n", key, function()
      if not M.flush(state) then return end
      local previous_id = state.item and state.item.id
      local previous_row = state.item and state.item.first or state.last_row or 0
      local ok, message = pcall(api.nvim_buf_call, state.source, function() vim.cmd(command) end)
      if not ok then notify(message) end
      -- Undo may resurrect a deleted range under a new anchor identity. This
      -- is an explicit history action, so reselect that location after undo.
      state.item = (previous_id and comments.by_id(state.source, previous_id)) or comments.at(state.source, previous_row)
      state.last_row, state.initialized = previous_row, false
      M.refresh_source(state.source)
    end, { buffer = buffer, silent = true, desc = "Docpair: " .. command .. " source edit" })
  end
  return state
end

local function map(buffer, name, callback)
  local old = vim.b[buffer]["docpair_mapping_" .. name]
  if old then pcall(vim.keymap.del, "n", old, { buffer = buffer }) end
  local key = config.mappings[name]
  if key and key ~= "" then
    vim.keymap.set("n", key, callback, { buffer = buffer, silent = true, desc = "Docpair: " .. name })
    vim.b[buffer]["docpair_mapping_" .. name] = key
  else vim.b[buffer]["docpair_mapping_" .. name] = nil end
end

function M.watch(record)
  local buffer = record.source_buffer
  map(buffer, "create", callbacks.create)
  map(buffer, "source", callbacks.source)
  if watched[buffer] then return end
  watched[buffer] = 0
  api.nvim_buf_attach(buffer, false, { on_lines = function()
    if watched[buffer] == nil then return end
    watched[buffer] = watched[buffer] + 1
    local generation = watched[buffer]
    vim.defer_fn(function()
      if not api.nvim_buf_is_valid(buffer) or not api.nvim_buf_is_loaded(buffer) then return end
      if watched[buffer] ~= generation then return end
      M.refresh_source(buffer)
    end, config.comments.debounce_ms)
  end, on_detach = function() watched[buffer] = nil end })
end

local function visible_row(buffer, row, backwards)
  local index, count = comments.index(buffer), api.nvim_buf_line_count(buffer)
  local function walk(candidate, reverse)
    for _ = 1, #index.items + 1 do
      if candidate < 0 or candidate >= count then return nil end
      local hidden, low, high = nil, 1, #index.items
      while low <= high do
        local middle = math.floor((low + high) / 2)
        local item = index.items[middle]
        if candidate < item.first then high = middle - 1
        elseif candidate >= item.last then low = middle + 1
        else hidden = item; break end
      end
      if not hidden then return candidate end
      candidate = reverse and hidden.first - 1 or hidden.last
    end
  end
  return walk(row, backwards) or walk(row, not backwards)
end

local function normalize_cursor(pair)
  if pair.mode == "notes" or pair.show_source or not config.comments.hide then return end
  local row = api.nvim_win_get_cursor(pair.source_window)[1] - 1
  local backwards = pair.last_source_row and row < pair.last_source_row
  local target = visible_row(pair.record.source_buffer, row, backwards)
  if target and target ~= row then api.nvim_win_set_cursor(pair.source_window, { target + 1, 0 }) end
  pair.last_source_row = target or row
end

function M.hide_source(buffer)
  if not source_valid({ source = buffer }) then return end
  local windows = {}
  for _, pair in pairs(active) do
    if pair.record.source_buffer == buffer and pair.mode ~= "notes" and valid(pair.source_window) and not pair.show_source and config.comments.hide then
      windows[#windows + 1] = pair.source_window
    end
  end
  local ns = conceal[buffer]
  if not ns then ns = api.nvim_create_namespace("docpair-hidden-" .. buffer); conceal[buffer] = ns end
  api.nvim_buf_clear_namespace(buffer, ns, 0, -1)
  if #windows == 0 then return end
  -- Stable 0.12 supports window-scoped namespaces. Unlike global buffer
  -- concealment, this leaves ordinary/preview windows of this file untouched.
  api.nvim__ns_set(ns, { wins = windows })
  for _, item in ipairs(comments.index(buffer).items) do
    if visible_row(buffer, item.first, false) then
      api.nvim_buf_set_extmark(buffer, ns, item.first, 0, { end_row = item.last - 1,
        end_col = #(item.raw[#item.raw] or ""), conceal_lines = "", strict = false })
    end
    if item.last < api.nvim_buf_line_count(buffer) then
      api.nvim_buf_set_extmark(buffer, ns, item.target_row or item.last, 0,
        { sign_text = "D", sign_hl_group = "Comment", priority = 5, strict = false })
    end
  end
  for _, window in ipairs(windows) do vim.wo[window].conceallevel = 2; vim.wo[window].concealcursor = "nc" end
end

local function display(pair, item)
  local state = states[pair.doc_buffer]
  if not state or state.dirty then return end
  if state.item == item and state.mode == pair.mode and state.initialized then return end
  local changed = pair.current_comment ~= (item and item.id)
  if changed then save_position(pair) end
  pair.current_comment, state.item, state.error = item and item.id, item, nil
  state.mode = pair.mode
  local lines = item and (pair.mode == "raw" and item.raw or comments.decode(item)) or { "" }
  set_text(state, lines)
  vim.bo[state.buffer].modifiable = item ~= nil and vim.bo[state.source].modifiable and not vim.bo[state.source].readonly
  if changed then restore_position(pair) end
  format_window(pair)
  state.initialized = true
end

function M.bind(pair, record, inherited)
  local old_buffer = pair.record_before and pair.record_before.source_buffer
  pair.mode = pair.mode or (inherited and inherited.mode) or config.initial_view
  active[pair.id] = pair
  M.watch(record)
  if pair.mode == "notes" then
    storage.prepare(record, config.info_filetype, false, true)
    pair.doc_buffer = record.notes_buffer
    vim.wo[pair.source_window].conceallevel = 0
  else
    local state = inherited and inherited.dirty and states[inherited.buffer] or states[pair.projection]
    if not state or state.source ~= record.source_buffer then
      state = make_state(record); pair.projection = state.buffer
    end
    pair.projection = state.buffer
    pair.doc_buffer = state.buffer
  end
  api.nvim_win_set_buf(pair.notes_window, pair.doc_buffer)
  if inherited and inherited.source_view then
    api.nvim_win_call(pair.source_window, function() vim.fn.winrestview(inherited.source_view) end)
  end
  map(pair.doc_buffer, "cycle", callbacks.cycle)
  if pair.mode ~= "notes" then
    local row = api.nvim_win_get_cursor(pair.source_window)[1] - 1
    local item = inherited and inherited.item and comments.by_id(record.source_buffer, inherited.item.id) or comments.at(record.source_buffer, row)
    display(pair, item)
    format_window(pair)
    if pair.mode == "markdown" and config.on_markdown then
      local ok, message = pcall(config.on_markdown, pair.doc_buffer, pair.notes_window)
      if not ok then notify(message) end
    end
  else format_window(pair) end
  M.hide_source(record.source_buffer)
  normalize_cursor(pair)
  if inherited and inherited.doc_view then
    api.nvim_win_call(pair.notes_window, function() vim.fn.winrestview(inherited.doc_view) end)
  end
  if old_buffer and old_buffer ~= record.source_buffer then M.hide_source(old_buffer) end
end

function M.inherit(buffer)
  local state = states[buffer]
  if not state then return nil end
  local source_view = state.last_source_view
  for _, pair in pairs(active) do
    if pair.doc_buffer == buffer and valid(pair.source_window) then source_view = snapshot(pair.source_window); break end
  end
  return { mode = state.mode, item = state.item, buffer = buffer, dirty = state.dirty,
    source_view = source_view, doc_view = state.session_doc_view }
end

function M.drafts()
  local result = {}
  for _, state in pairs(states) do
    if state.dirty and api.nvim_buf_is_valid(state.buffer) then result[#result + 1] = state end
  end
  return result
end

function M.cleanup()
  -- A clean projection is fully reproducible from source. Do not accumulate a
  -- second large document copy on every :edit / mode switch. Invalid drafts
  -- and projections still displayed by detached/native windows are retained.
  for _, state in ipairs(vim.tbl_values(states)) do
    if api.nvim_buf_is_valid(state.buffer) and not state.dirty and #vim.fn.win_findbuf(state.buffer) == 0 then
      pcall(api.nvim_buf_delete, state.buffer, { force = false })
    end
  end
end

function M.release(pair)
  local state = states[pair.doc_buffer]
  if state and valid(pair.source_window) then state.last_source_view = snapshot(pair.source_window) end
  active[pair.id] = nil
  M.hide_source(pair.record.source_buffer)
end

function M.follow(pair, origin)
  if pair.mode == "notes" then return false end
  if origin ~= pair.source_window or api.nvim_get_current_win() == pair.notes_window then return true end
  local cached = comments.cached(pair.record.source_buffer)
  if api.nvim_get_mode().mode:sub(1, 1) == "i" and cached
    and cached.tick ~= api.nvim_buf_get_changedtick(pair.record.source_buffer) then
    return true -- debounce source typing; old extmarks still track its edits
  end
  normalize_cursor(pair)
  local state = states[pair.doc_buffer]
  if state and not state.dirty then
    display(pair, comments.at(pair.record.source_buffer, api.nvim_win_get_cursor(pair.source_window)[1] - 1))
    state.last_source_view = snapshot(pair.source_window)
  end
  return true
end

function M.refresh_source(buffer)
  if writing or not source_valid({ source = buffer }) then return end
  local needs_comments = false
  for _, pair in pairs(active) do
    if pair.record.source_buffer == buffer and pair.mode ~= "notes" then needs_comments = true; break end
  end
  if not needs_comments then return end
  comments.index(buffer)
  for _, pair in pairs(active) do
    if pair.record.source_buffer == buffer and pair.mode ~= "notes" and valid(pair.notes_window) then
      local state = states[pair.doc_buffer]
      if state and not state.dirty then
        -- Editing in the doc window freezes the selection. Source changes may
        -- refresh that same identity, but must never silently choose another.
        local item
        if api.nvim_get_current_win() == pair.notes_window then
          item = state.item and comments.by_id(buffer, state.item.id)
        else item = comments.at(buffer, api.nvim_win_get_cursor(pair.source_window)[1] - 1) end
        display(pair, item)
        normalize_cursor(pair)
      end
    end
  end
  M.hide_source(buffer)
end

function M.change(pair, requested)
  if not M.can_leave(pair) then return end
  local next_mode = requested
  if not next_mode then
    local index = 1
    for i, name in ipairs(config.views) do if name == pair.mode then index = i; break end end
    next_mode = config.views[index % #config.views + 1]
  end
  assert(vim.tbl_contains(config.views, next_mode), "view is not enabled: " .. tostring(next_mode))
  if pair.mode == next_mode then return end
  save_position(pair)
  local item = states[pair.doc_buffer] and states[pair.doc_buffer].item
  pair.mode = next_mode
  M.bind(pair, pair.record, { mode = next_mode, item = item })
  restore_position(pair)
end

function M.create(pair)
  if not M.can_leave(pair) then return end
  local row = api.nvim_win_get_cursor(pair.source_window)[1] - 1
  local item = comments.at(pair.record.source_buffer, row)
  if not item then item = comments.insert(pair.record.source_buffer, row) end
  assert(item, "could not find a safe comment position")
  if pair.mode == "notes" then
    assert(vim.tbl_contains(config.views, "text"), "enable the text view to create inline documentation")
    M.change(pair, "text")
  end
  display(pair, item)
  M.hide_source(pair.record.source_buffer)
  api.nvim_set_current_win(pair.notes_window)
end

function M.toggle_source(pair)
  pair.show_source = not pair.show_source
  vim.wo[pair.source_window].conceallevel = pair.show_source and 0 or 2
  M.hide_source(pair.record.source_buffer)
  normalize_cursor(pair)
end

function M.discard(pair)
  local state = states[pair.doc_buffer]
  if not state or not state.dirty then return end
  state.dirty, state.error = false, nil
  state.initialized = false
  local item = state.item and comments.by_id(state.source, state.item.id)
  display(pair, item)
end

function M.before_session()
  -- Native sessions recreate acwrite panes with :file, unlike normal files.
  -- Remove clean old projections first to avoid E95 on the saved buffer name.
  -- Invalid drafts must prevent restoration, not be silently wiped.
  for _, state in pairs(states) do
    local ok, message = M.flush(state, true)
    assert(ok, "docpair: save or repair the draft before loading a session: " .. tostring(message))
  end
  for _, state in ipairs(vim.tbl_values(states)) do
    if api.nvim_buf_is_valid(state.buffer) then api.nvim_buf_delete(state.buffer, { force = false }) end
  end
end

function M.session()
  local result = {}
  for _, state in pairs(states) do
    if api.nvim_buf_is_valid(state.buffer) and #vim.fn.win_findbuf(state.buffer) > 0 then
      local inherited = M.inherit(state.buffer)
      result[#result + 1] = { name = api.nvim_buf_get_name(state.buffer), source = state.record.source,
        mode = state.mode, row = state.item and state.item.first, source_view = inherited.source_view,
        doc_view = snapshot(vim.fn.win_findbuf(state.buffer)[1]) }
    end
  end
  return result
end

function M.restore_session(entries)
  for _, entry in ipairs(entries or {}) do
    local record = storage.sources[entry.source]
    if record and type(entry.name) == "string" and vim.tbl_contains(config.views, entry.mode) then
      local buffer = vim.fn.bufnr(entry.name)
      if buffer ~= -1 then
        storage.prepare(record, config.info_filetype, false, false)
        local state = make_state(record)
        state.mode, state.item = entry.mode, comments.at(record.source_buffer, entry.row or 0)
        state.last_source_view, state.session_doc_view = entry.source_view, entry.doc_view
        for _, window in ipairs(vim.fn.win_findbuf(buffer)) do api.nvim_win_set_buf(window, state.buffer) end
        pcall(api.nvim_buf_delete, buffer, { force = false })
      end
    end
  end
end

function M.setup(options, hooks)
  config, callbacks = options, hooks
  local group = api.nvim_create_augroup("DocpairProjections", { clear = true })
  api.nvim_create_autocmd("BufWritePre", { group = group, callback = function(event) M.flush_source(event.buf) end })
  -- Flush before :wq / :qall, too. A failed flush leaves the acwrite draft
  -- modified, so Neovim's own unsaved-buffer protection remains effective.
  api.nvim_create_autocmd("QuitPre", { group = group, callback = function()
    for _, state in pairs(states) do M.flush(state, true) end
  end })
end

return M
