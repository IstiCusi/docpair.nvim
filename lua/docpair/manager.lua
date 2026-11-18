-- A storage record identifies files; a pair identifies TWO window IDs.
-- Multiple pairs can show one record, even in the same tab. Native scrollbind
-- groups and relative window numbers cannot express that ownership.
local M = {}
local api = vim.api
local storage = require("docpair.storage")
local views = require("docpair.views")
local pairs_by_id, owner_by_window, ignored_windows = {}, {}, {}
local next_pair_id, busy, pending, exiting, syncing = 0, false, false, false, false
local config = { info_filetype = "markdown" }
local reconcile
local session_restoring = false
local recent_pair
local window_options = { "wrap", "linebreak", "foldenable", "conceallevel", "scrolloff",
  "sidescrolloff", "scrollbind", "cursorbind", "concealcursor", "winbar" }

local function prepare(record, extend, mode)
  return storage.prepare(record, config.info_filetype, extend, (mode or config.initial_view) == "notes")
end

local function valid(window)
  return window and api.nvim_win_is_valid(window)
end

local function ordinary_window(window)
  return valid(window) and api.nvim_win_get_config(window).relative == ""
    and not vim.wo[window].previewwindow and vim.fn.win_gettype(window) == ""
end

local function last_normal_window()
  local count = 0
  for _, window in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(window).relative == "" then count = count + 1 end
  end
  return count == 1
end

local function read_options(window)
  local options = {}
  for _, name in ipairs(window_options) do options[name] = vim.wo[window][name] end
  return options
end

local function restore_options(window, options)
  if not valid(window) then return end
  for name, value in pairs(options or {}) do vim.wo[window][name] = value end
end

local function configure_window(window)
  -- Every enabled native cursorbind/scrollbind window participates. Disable
  -- them on our own panes and synchronize only the registered partner below.
  for name, value in pairs({ wrap = false, linebreak = false, foldenable = false,
    conceallevel = 0, scrolloff = 0, sidescrolloff = 0,
    scrollbind = false, cursorbind = false }) do vim.wo[window][name] = value end
end

local function view(window)
  return api.nvim_win_call(window, vim.fn.winsaveview)
end

local function sync_pair(pair, origin)
  if syncing or not valid(pair.source_window) or not valid(pair.notes_window) then return end
  if views.follow(pair, origin) then return end
  local target = origin == pair.source_window and pair.notes_window or pair.source_window
  if not valid(origin) then return end
  syncing = true
  local ok, message = pcall(function()
    local origin_view, target_view = view(origin), view(target)
    local count = api.nvim_buf_line_count(api.nvim_win_get_buf(target))
    target_view.lnum = math.min(origin_view.lnum, count)
    target_view.topline = math.min(origin_view.topline, count)
    target_view.topfill, target_view.skipcol = 0, 0
    -- Each pane keeps its own horizontal offset and cursor column. Long prose
    -- must never scroll source code sideways.
    api.nvim_win_call(target, function() vim.fn.winrestview(target_view) end)
    pair.last_driver = origin
    pair.last_views = { [origin] = view(origin), [target] = view(target) }
  end)
  syncing = false
  if not ok then vim.notify("docpair synchronization: " .. tostring(message), vim.log.levels.WARN) end
end

local function bind(pair, source_window, notes_window, record, inherited)
  pair.record_before = pair.record
  pair.source_window, pair.notes_window, pair.record = source_window, notes_window, record
  pair.source_options = pair.source_options or read_options(source_window)
  pair.notes_options = pair.notes_options or read_options(notes_window)
  owner_by_window[source_window], owner_by_window[notes_window] = pair.id, pair.id
  ignored_windows[source_window], ignored_windows[notes_window] = nil, nil
  configure_window(source_window)
  configure_window(notes_window)
  api.nvim_win_set_buf(source_window, record.source_buffer)
  views.bind(pair, record, inherited)
end

local function forget(pair)
  views.release(pair)
  owner_by_window[pair.source_window], owner_by_window[pair.notes_window] = nil, nil
  restore_options(pair.source_window, pair.source_options)
  restore_options(pair.notes_window, pair.notes_options)
  pairs_by_id[pair.id] = nil
end

local function split_partner(window, buffer, direction)
  -- win_call restores focus, including for a background tab. Placement is
  -- explicit and does not depend on the user's 'splitright' setting.
  return api.nvim_win_call(window, function()
    vim.cmd(direction .. " vsplit")
    local partner = api.nvim_get_current_win()
    api.nvim_win_set_buf(partner, buffer)
    return partner
  end)
end

local function new_pair(source_window, notes_window, record, mode)
  local inherited = notes_window and views.inherit(api.nvim_win_get_buf(notes_window))
  if not mode and not inherited and recent_pair and recent_pair.record == record then mode = recent_pair.mode end
  prepare(record, false, mode or (inherited and inherited.mode))
  if not source_window then source_window = split_partner(notes_window, record.source_buffer, "leftabove") end
  if not notes_window then notes_window = split_partner(source_window, record.notes_buffer or record.source_buffer, "rightbelow") end
  next_pair_id = next_pair_id + 1
  local pair = { id = next_pair_id, record = record, mode = mode }
  pairs_by_id[pair.id] = pair
  bind(pair, source_window, notes_window, record, inherited)
  sync_pair(pair, source_window)
  return pair
end

local function suspend()
  return exiting or vim.g.SessionLoad == 1 or vim.v.exiting ~= vim.NIL
end

local function schedule()
  if busy or pending or suspend() then return end
  pending = true
  vim.schedule(function()
    pending = false
    if not suspend() then M.reconcile() end
  end)
end

local function close_pair(pair)
  local windows = { pair.notes_window, pair.source_window }
  forget(pair)
  for _, window in ipairs(windows) do
    if valid(window) then
      -- Never force-close a modified source. If Neovim refuses, the surviving
      -- associated view will receive a companion again on reconciliation.
      local ok, message = pcall(api.nvim_win_close, window, false)
      if not ok then
        -- Floating popups do not count as another normal editing window.
        if last_normal_window() and pair.quit_requested then
          local quit_ok, quit_error = pcall(vim.cmd, "quit")
          if not quit_ok then vim.notify("docpair: " .. tostring(quit_error), vim.log.levels.WARN) end
        elseif last_normal_window() and not vim.bo[api.nvim_win_get_buf(window)].modified then
          api.nvim_win_set_buf(window, api.nvim_create_buf(true, false))
        else
          vim.notify("docpair: " .. tostring(message), vim.log.levels.WARN)
        end
      end
    end
  end
end

local function window_record(window)
  if not ordinary_window(window) then return nil end
  return storage.find(api.nvim_win_get_buf(window))
end

reconcile = function()
  -- Native commands may emit events before completing a layout change. Work
  -- from the finished layout in the scheduled callback, not recursively from
  -- inside BufEnter/WinClosed while window creation is still in progress.
  local snapshot = vim.tbl_values(pairs_by_id)
  table.sort(snapshot, function(left, right) return left.id < right.id end)
  for _, pair in ipairs(snapshot) do
    local source_valid, notes_valid = valid(pair.source_window), valid(pair.notes_window)
    if not source_valid and not notes_valid then
      forget(pair)
    elseif pair.close_requested then
      close_pair(pair)
    elseif not source_valid or not notes_valid then
      local survivor = source_valid and pair.source_window or pair.notes_window
      local record = pair.record
      forget(pair)
      if window_record(survivor) == record then
        new_pair(source_valid and survivor or nil, notes_valid and survivor or nil, record, pair.mode)
      end
    elseif api.nvim_win_get_tabpage(pair.source_window) ~= api.nvim_win_get_tabpage(pair.notes_window) then
      forget(pair)
    else
      pair.quit_requested = nil
      local source_buffer = api.nvim_win_get_buf(pair.source_window)
      local notes_buffer = api.nvim_win_get_buf(pair.notes_window)
      local source_changed = source_buffer ~= pair.record.source_buffer
      local notes_changed = notes_buffer ~= pair.doc_buffer
      if source_changed or notes_changed then
        local changed = notes_changed and pair.notes_window or pair.source_window
        if source_changed and notes_changed then
          local current = api.nvim_get_current_win()
          changed = current == pair.notes_window and current or pair.source_window
        end
        local replacement = api.nvim_win_get_buf(changed)
        if storage.regular(replacement) or storage.find(replacement) then
          local record = storage.find(replacement) or storage.for_source(replacement)
          prepare(record, false, pair.mode)
          bind(pair, pair.source_window, pair.notes_window, record)
          -- A source selected in the notes pane still belongs on the source
          -- side. Known notes are never recursively documented as source.
          if changed == api.nvim_get_current_win() and not storage.is_notes(replacement) then
            api.nvim_set_current_win(pair.source_window)
          end
          sync_pair(pair, pair.source_window)
        else
          local companion = changed == pair.source_window and pair.notes_window or pair.source_window
          forget(pair)
          if valid(companion) then pcall(api.nvim_win_close, companion, false) end
        end
      end
    end
  end

  -- Attach registered files shown by :split, :tab split, :buffer, quickfix,
  -- session restore or a plugin's normal window API. Unrelated files opened
  -- outside a managed pane remain ordinary editor windows.
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    local unowned = {}
    for _, window in ipairs(api.nvim_tabpage_list_wins(tab)) do
      if not owner_by_window[window] and not ignored_windows[window] then
        local record = window_record(window)
        if record then unowned[#unowned + 1] = { window = window, record = record } end
      end
    end
    for _, item in ipairs(unowned) do
      if valid(item.window) and not owner_by_window[item.window] then
        local notes_side = storage.is_notes(api.nvim_win_get_buf(item.window))
        local counterpart
        for _, other in ipairs(unowned) do
          if other.window ~= item.window and other.record == item.record
            and not owner_by_window[other.window]
            and storage.is_notes(api.nvim_win_get_buf(other.window)) ~= notes_side then
            counterpart = other.window
            break
          end
        end
        local source_window, notes_window
        if notes_side then
          source_window, notes_window = counterpart, item.window
        else
          source_window, notes_window = item.window, counterpart
        end
        new_pair(source_window, notes_window, item.record)
      end
    end
  end
end

function M.reconcile()
  if busy or suspend() then return end
  busy = true
  local ok, message = xpcall(reconcile, debug.traceback)
  if ok then views.cleanup() end
  busy = false
  if not ok then vim.notify("docpair: " .. message, vim.log.levels.ERROR) end
end

function M.open(arguments, use_current_tab)
  assert(#arguments <= 2, "Usage: :Documented[!] [file] [infofile]")
  local buffer = #arguments > 0 and storage.buffer(storage.path(arguments[1])) or api.nvim_get_current_buf()
  assert(storage.regular(buffer) or storage.find(buffer), "Documented requires a named, ordinary file buffer")
  local record = storage.find(buffer) or storage.for_source(buffer, arguments[2])
  if arguments[2] then record = storage.for_source(buffer, arguments[2]) end
  local mode = arguments[2] and "notes" or config.initial_view
  prepare(record, true, mode)
  local active = owner_by_window[api.nvim_get_current_win()]
  if active and pairs_by_id[active].record == record then M.reconcile(); return end
  busy = true
  local ok, message = xpcall(function()
    -- :tabnew would leave an unused listed [No Name] buffer in :bnext.
    if not use_current_tab then vim.cmd("tab split") end
    local source_window = api.nvim_get_current_win()
    local previous = owner_by_window[source_window]
    if previous then
      local pair = pairs_by_id[previous]
      bind(pair, pair.source_window, pair.notes_window, record)
      api.nvim_set_current_win(pair.source_window)
    else
      api.nvim_win_set_buf(source_window, record.source_buffer)
      new_pair(source_window, nil, record, mode)
    end
  end, debug.traceback)
  busy = false
  if not ok then error(message) end
  schedule()
end

function M.close_current()
  local pair = pairs_by_id[owner_by_window[api.nvim_get_current_win()]]
  if not pair then return end
  busy = true
  close_pair(pair)
  busy = false
  schedule()
end

function M.detach_current()
  local pair = pairs_by_id[owner_by_window[api.nvim_get_current_win()]]
  if not pair then return end
  ignored_windows[pair.source_window], ignored_windows[pair.notes_window] = true, true
  forget(pair)
end

function M.inspect()
  local output = {}
  for _, pair in pairs(pairs_by_id) do
    output[#output + 1] = { id = pair.id, source_window = pair.source_window, notes_window = pair.notes_window,
      source = pair.record.source, notes = pair.record.notes,
      source_buffer = pair.record.source_buffer, notes_buffer = pair.record.notes_buffer,
      doc_buffer = pair.doc_buffer, view = pair.mode, comment_id = pair.current_comment }
  end
  table.sort(output, function(left, right) return left.id < right.id end)
  return output
end

local function save_session()
  local filename = vim.v.this_session
  if filename == "" then return end
  local records = {}
  for _, record in pairs(storage.sources) do records[#records + 1] = { source = record.source, notes = record.notes } end
  -- Native sessions retain their usual format. JSON stores only associations
  -- (including custom note filenames), never source text or private notes.
  local ok, message = pcall(vim.fn.writefile, { vim.json.encode({ version = 1, records = records, views = views.session() }) },
    filename .. ".docpair.json")
  if not ok then vim.notify("docpair session: " .. tostring(message), vim.log.levels.ERROR) end
end

local function load_session()
  -- :mksession uses :doautoall SessionLoadPost: it fires once per buffer.
  -- Rebuilding projection identities repeatedly would orphan the first set.
  if session_restoring then return end
  local filename = vim.v.this_session .. ".docpair.json"
  if vim.fn.filereadable(filename) == 0 then schedule(); return end
  local ok, data = pcall(function() return vim.json.decode(table.concat(vim.fn.readfile(filename), "\n")) end)
  if not ok or type(data) ~= "table" or data.version ~= 1 or type(data.records) ~= "table" then
    vim.notify("docpair: invalid session metadata: " .. filename, vim.log.levels.WARN)
    return
  end
  session_restoring = true
  for _, pair in ipairs(vim.tbl_values(pairs_by_id)) do forget(pair) end
  ignored_windows = {}
  storage.reset()
  for _, record in ipairs(data.records) do
    if type(record.source) == "string" and type(record.notes) == "string" then
      local registered, message = pcall(storage.register, record.source, record.notes)
      if not registered then vim.notify("docpair: " .. tostring(message), vim.log.levels.WARN) end
    end
  end
  views.restore_session(data.views)
  -- SessionLoadPost runs while g:SessionLoad is still 1. Wait until :source
  -- has returned before inspecting windows; schedule() would discard this
  -- request during the native session's restoration guard.
  vim.schedule(function() session_restoring = false; schedule() end)
end

function M.setup(options)
  config = options
  views.setup(config, { cycle = function() M.change_view() end, create = function() M.add_comment() end,
    source = function() M.toggle_source() end })
  local group = api.nvim_create_augroup("DocpairLifecycle", { clear = true })
  api.nvim_create_autocmd("WinLeave", { group = group, callback = function()
    local pair = pairs_by_id[owner_by_window[api.nvim_get_current_win()]]
    if pair then recent_pair = { record = pair.record, mode = pair.mode } end
  end })
  api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "WinEnter", "WinNew", "TabEnter", "TabClosed", "BufDelete" },
    { group = group, callback = schedule })
  api.nvim_create_autocmd("WinClosed", { group = group, callback = function(event)
    if busy or suspend() then return end
    local window = tonumber(event.match)
    local pair = pairs_by_id[owner_by_window[window]]
    -- :close/:q of the focused pane closes the pair. :only closes nonfocused
    -- panes, so its survivor is repaired instead. Tab teardown leaves no
    -- survivor and therefore never causes a new tab to be created.
    if pair and api.nvim_get_current_win() == window then pair.close_requested = true end
    ignored_windows[window] = nil
    schedule()
  end })
  api.nvim_create_autocmd("QuitPre", { group = group, callback = function()
    local pair = pairs_by_id[owner_by_window[api.nvim_get_current_win()]]
    if pair then pair.quit_requested = true end
    schedule()
  end })
  api.nvim_create_autocmd("BufDelete", { group = group, callback = function(event)
    if busy or suspend() then return end
    for _, pair in pairs(pairs_by_id) do
      if pair.record.source_buffer == event.buf or pair.record.notes_buffer == event.buf or pair.doc_buffer == event.buf then
        pair.close_requested = true
      end
    end
    schedule()
  end })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, { group = group, callback = function()
    if busy or syncing or suspend() then return end
    local current = api.nvim_get_current_win()
    local pair = pairs_by_id[owner_by_window[current]]
    if pair then sync_pair(pair, current) end
  end })
  api.nvim_create_autocmd("WinScrolled", { group = group, callback = function()
    if busy or syncing or suspend() then return end
    -- A wheel can scroll the unfocused pane. Its window ID, not the focused
    -- window, is the driver. Ignore delayed events caused by our own previous
    -- winrestview; otherwise the two views can bounce back on the next redraw.
    local drivers = {}
    for key in pairs(vim.v.event) do
      local window = tonumber(key)
      local pair = window and pairs_by_id[owner_by_window[window]]
      if pair and valid(window) then
        local before = pair.last_views and pair.last_views[window]
        local now = view(window)
        if not before or now.topline ~= before.topline or now.lnum ~= before.lnum then
          if not drivers[pair.id] or window == api.nvim_get_current_win() then drivers[pair.id] = window end
        end
      end
    end
    for id, driver in pairs(drivers) do sync_pair(pairs_by_id[id], driver) end
  end })
  api.nvim_create_autocmd("BufWritePre", { group = group, callback = function(event)
    if storage.is_notes(event.buf) then vim.fn.mkdir(vim.fs.dirname(api.nvim_buf_get_name(event.buf)), "p") end
  end })
  api.nvim_create_autocmd("BufFilePost", { group = group, callback = function(event)
    local ok, message = pcall(storage.rename, event.buf)
    if not ok then vim.notify("docpair: " .. tostring(message), vim.log.levels.ERROR) end
    schedule()
  end })
  api.nvim_create_autocmd("SessionWritePost", { group = group, callback = save_session })
  api.nvim_create_autocmd("SourcePre", { group = group, callback = function(event)
    if vim.fn.filereadable(event.file .. ".docpair.json") == 0 then return end
    busy = true
    local ok, message = pcall(function()
      views.before_session()
      for _, pair in ipairs(vim.tbl_values(pairs_by_id)) do forget(pair) end
    end)
    busy = false
    if not ok then error(message) end
  end })
  api.nvim_create_autocmd("SessionLoadPost", { group = group, callback = load_session })
  -- ExitPre may occur even when :qall is cancelled. Only committed shutdown
  -- sets this flag; normal events must keep working after a cancelled quit.
  api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function() exiting = true end })
end

local function current_action(action, ...)
  local pair = pairs_by_id[owner_by_window[api.nvim_get_current_win()]]
  if not pair then vim.notify("docpair: open :Documented first", vim.log.levels.WARN); return end
  busy = true
  local ok, message = pcall(action, pair, ...)
  busy = false
  if not ok then vim.notify("docpair: " .. tostring(message), vim.log.levels.ERROR) end
  schedule()
end

function M.change_view(name) current_action(views.change, name) end
function M.add_comment() current_action(views.create) end
function M.toggle_source() current_action(views.toggle_source) end
function M.discard_draft() current_action(views.discard) end

return M
