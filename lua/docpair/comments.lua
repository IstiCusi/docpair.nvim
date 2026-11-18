-- Comment discovery and a lossless codec. The source buffer is authoritative.
-- Only whole-line comments are projected: trailing comments and directives
-- are deliberately left visible. Tree-sitter supplies semantic scope when a
-- parser exists; the lexer otherwise provides a labelled positional fallback.
local M = {}
local api = vim.api
local anchors = api.nvim_create_namespace("docpair-comment-anchors")
local caches, next_id = {}, 0
local profiles = {}
local function profile(names, value)
  for name in names:gmatch("%S+") do profiles[name] = value end
end
profile("c cpp java javascript javascriptreact typescript typescriptreact cs go kotlin swift scala dart objc objcpp php rust",
  { line = { "///", "//!", "//" }, blocks = { { "/*", "*/" } }, create = "///" })
profile("zig", { line = { "///", "//!", "//" }, blocks = {}, create = "///" })
profile("python ruby sh bash zsh fish yaml toml r perl", { line = { "#" }, blocks = {}, create = "#" })
profile("lua", { line = { "---", "--" }, blocks = {}, create = "---", lua = true })
profile("sql", { line = { "--" }, blocks = { { "/*", "*/" } }, create = "--" })
profile("pascal delphi", { line = { "//" }, blocks = { { "(*", "*)" }, { "{", "}" } }, create = "//" })
profile("html xml vue svelte", { line = {}, blocks = { { "<!--", "-->" } }, create_block = { "<!--", "-->" } })
profile("css scss less", { line = {}, blocks = { { "/*", "*/" } }, create_block = { "/**", "*/" } })
profile("haskell", { line = { "--" }, blocks = { { "{-", "-}" } }, create = "--" })
profile("elixir erlang", { line = { "#", "%" }, blocks = {}, create = "#" })
profile("vim", { line = { '"' }, blocks = {}, create = '"' })

local extensions = { h = "c", hpp = "cpp", cc = "cpp", cxx = "cpp", js = "javascript", ts = "typescript",
  jsx = "javascriptreact", tsx = "typescriptreact", py = "python", rs = "rust", rb = "ruby", pas = "pascal",
  pp = "pascal", lpr = "pascal", kt = "kotlin", md = "markdown", yml = "yaml" }

function M.filetype(buffer)
  local ft = vim.bo[buffer].filetype
  if ft ~= "" then return ft end
  local ext = api.nvim_buf_get_name(buffer):match("%.([^./]+)$") or ""
  return extensions[ext] or ext
end

function M.supported(buffer) return profiles[M.filetype(buffer)] ~= nil end

local function starts(text, at, token) return text:sub(at, at + #token - 1) == token end
local function directive(text)
  return text:match("^%s*[({]%*?%$") or text:match("^%s*#!")
    or text:match("^%s*#%s*[a-zA-Z_-]*coding[:=]")
    or text:match("^%s*//%s*go:") or text:match("^%s*//%s*%+build")
    or text:match("^%s*///%s*<reference") or text:match("^%s*//[/!]%s*<reference")
end

-- The lexer never rewrites text. Its string state prevents comment-looking
-- text inside ordinary, multiline, raw, or Lua long strings being projected.
local function scan(lines, p, ft)
  local found, state, pending, heredocs, protected = {}, nil, nil, {}, {}
  for row, line in ipairs(lines) do
    if state or #heredocs > 0 then protected[row - 1] = true end
    if #heredocs > 0 then
      local ending = line:gsub("^%s+", ""):gsub(";%s*$", "")
      if ending == heredocs[1] then table.remove(heredocs, 1) end
      pending = nil
    else
    local col, line_comment = 1, nil
    while col <= #line do
      if state then
        if state.kind == "quote" then
          if line:sub(col, col) == "\\" and not state.raw then col = col + 2
          elseif starts(line, col, state.close) then col = col + #state.close; state = nil
          else col = col + 1 end
        else
          if state.nested and starts(line, col, state.open) then state.depth = state.depth + 1; col = col + #state.open
          elseif starts(line, col, state.close) then
            state.depth = state.depth - 1
            if state.depth == 0 then
              if state.whole and line:sub(col + #state.close):match("^%s*$") then
                found[#found + 1] = { first = state.row - 1, last = row, kind = "block",
                  open = state.open, close = state.close }
              end
              col = col + #state.close; state = nil
            else col = col + #state.close end
          else col = col + 1 end
        end
      else
        local consumed = false
        -- Lua long comments and long strings use matching '=' counts.
        if p.lua then
          local equals = line:sub(col):match("^%-%-%[(=*)%[")
          local string_equals = line:sub(col):match("^%[(=*)%[")
          if equals then
            local opening = "--[" .. equals .. "["
            state = { kind = "block", open = opening, close = "]" .. equals .. "]", row = row,
              whole = line:sub(1, col - 1):match("^%s*$") ~= nil, depth = 1 }
            col = col + #opening; consumed = true
          elseif string_equals then
            state = { kind = "quote", close = "]" .. string_equals .. "]", raw = true }
            col = col + #string_equals + 2; consumed = true
          end
        end
        if not consumed then
          for _, delimiters in ipairs(p.blocks) do
            if starts(line, col, delimiters[1]) then
              state = { kind = "block", open = delimiters[1], close = delimiters[2], row = row,
                whole = line:sub(1, col - 1):match("^%s*$") ~= nil and not directive(line), depth = 1,
                nested = ft == "rust" or ft == "haskell" or ft == "swift" }
              col = col + #delimiters[1]; consumed = true; break
            end
          end
        end
        if not consumed then
          for _, marker in ipairs(p.line) do
            if starts(line, col, marker) then
              if line:sub(1, col - 1):match("^%s*$") and not directive(line) then line_comment = marker end
              col = #line + 1; consumed = true; break
            end
          end
        end
        if not consumed then
          if ft == "sh" or ft == "bash" or ft == "zsh" or ft == "ruby" or ft == "php" then
            local token = line:sub(col):match("^<<<*[-~]?%s*['\"]?([%a_][%w_]*)['\"]?")
            if token and (col == 1 or line:sub(col - 1, col - 1) ~= "<") then heredocs[#heredocs + 1] = token end
          end
          local raw_cpp = line:sub(col):match('^R"([^%s%(%)\\]*)%(')
          local raw_rust = ft == "rust" and line:sub(col):match('^r(#*)"')
          if raw_cpp then
            state = { kind = "quote", close = ")" .. raw_cpp .. '"', raw = true }; col = col + #raw_cpp + 3
          elseif raw_rust then
            state = { kind = "quote", close = '"' .. raw_rust, raw = true }; col = col + #raw_rust + 2
          else
            local char = line:sub(col, col)
            if char == '"' or char == "'" or char == "`" then
              local triple_language = ft == "python" or ft == "java" or ft == "kotlin" or ft == "scala" or ft == "swift"
              local triple = triple_language and starts(line, col, char:rep(3))
              -- Rust lifetimes are not strings. A char literal has a close quote.
              if ft == "rust" and char == "'" and not line:sub(col + 1):match("^.-'") then col = col + 1
              else
                local close = triple and char:rep(3) or char
                state = { kind = "quote", close = close }; col = col + #close
              end
            else col = col + 1 end
          end
        end
      end
    end
    if line_comment then
      if pending and pending.last == row - 1 and pending.marker == line_comment then pending.last = row
      else
        pending = { first = row - 1, last = row, kind = "line", marker = line_comment }
        found[#found + 1] = pending
      end
    else pending = nil end
    end
  end
  table.sort(found, function(a, b) return a.first < b.first end)
  return found, protected
end

local function syntax_root(buffer)
  local language = vim.treesitter.language.get_lang(M.filetype(buffer)) or M.filetype(buffer)
  local ok, parser = pcall(vim.treesitter.get_parser, buffer, language, { error = false })
  if not ok or not parser then return nil end
  local parsed, trees = pcall(parser.parse, parser)
  return parsed and trees and trees[1] and trees[1]:root() or nil
end

local function is_comment(node) return node and node:type():find("comment") ~= nil end
local function scope_for(item, root, count, next_comment)
  item.scope_first, item.scope_last, item.semantic = item.first, next_comment or count, false
  if item.marker == "//!" then item.scope_first, item.scope_last = 0, count; return end
  if not root then return end
  local col = #(item.raw[1]:match("^%s*") or "")
  local node = root:named_descendant_for_range(item.first, col, item.first, col + 1)
  while node and not is_comment(node) and node:parent() do
    if node:start() < item.first then break end
    node = node:parent()
  end
  if not is_comment(node) then item.not_comment = true; return end
  local following = node:next_named_sibling()
  while is_comment(following) do following = following:next_named_sibling() end
  if following then
    local sr = following:start()
    local er, ec = following:end_()
    item.scope_last, item.semantic = er + (ec > 0 and 1 or 0), true
    item.target_row, item.target_type = sr, following:type()
  else
    local parent = node:parent()
    if parent then
      local sr = parent:start()
      local er, ec = parent:end_()
      item.scope_first, item.scope_last, item.semantic = sr, er + (ec > 0 and 1 or 0), true
    end
  end
end

function M.position(buffer, item)
  local mark = api.nvim_buf_get_extmark_by_id(buffer, anchors, item.id, { details = true })
  if #mark == 0 or mark[3].invalid then return nil end
  return mark[1], mark[3].end_row
end

function M.index(buffer)
  local tick = api.nvim_buf_get_changedtick(buffer)
  if caches[buffer] and caches[buffer].tick == tick then return caches[buffer] end
  local ft, lines = M.filetype(buffer), api.nvim_buf_get_lines(buffer, 0, -1, false)
  local p, old = profiles[ft], caches[buffer]
  local candidates, protected = {}, {}
  if p then candidates, protected = scan(lines, p, ft) end
  local root = syntax_root(buffer)
  local by_row = {}
  for _, item in ipairs(old and old.items or {}) do
    local first = M.position(buffer, item)
    if first then by_row[first] = item end
  end
  local items, keep = {}, {}
  for i, item in ipairs(candidates) do
    item.filetype = ft
    item.raw = vim.list_slice(lines, item.first + 1, item.last)
    scope_for(item, root, #lines, candidates[i + 1] and candidates[i + 1].first)
    if not item.not_comment then
      local previous = by_row[item.first]
      if previous and previous.kind == item.kind then item.id = previous.id
      else next_id = next_id + 1; item.id = next_id end
      keep[item.id] = true
      api.nvim_buf_set_extmark(buffer, anchors, item.first, 0,
        { id = item.id, end_row = item.last, end_col = 0, right_gravity = true,
          end_right_gravity = false, invalidate = true, undo_restore = true, strict = false })
      items[#items + 1] = item
    end
  end
  -- Invalid old anchors are retained for undo restoration, but never selected
  -- as active comments. Prune valid replaced ones to avoid ambiguous matches.
  for _, item in ipairs(old and old.items or {}) do
    if not keep[item.id] and M.position(buffer, item) then api.nvim_buf_del_extmark(buffer, anchors, item.id) end
  end
  local result = { tick = tick, items = items, root = root, filetype = ft, supported = p ~= nil, protected = protected }
  caches[buffer] = result
  return result
end

function M.at(buffer, row)
  local best
  for _, item in ipairs(M.index(buffer).items) do
    if row >= item.first and row < item.last then return item end
    if row >= item.scope_first and row < item.scope_last then
      if not best or item.scope_last - item.scope_first <= best.scope_last - best.scope_first then best = item end
    end
  end
  return best
end

function M.by_id(buffer, id)
  for _, item in ipairs(M.index(buffer).items) do if item.id == id then return item end end
end

function M.cached(buffer) return caches[buffer] end

function M.replace(buffer, item, raw, structural)
  local first, last = M.position(buffer, item)
  assert(first and last, "comment was removed; draft retained")
  assert(vim.deep_equal(api.nvim_buf_get_lines(buffer, first, last, false), item.raw),
    "source comment changed elsewhere; draft retained")
  local before = M.index(buffer)
  api.nvim_buf_set_lines(buffer, first, last, false, raw)
  -- Replacing a full range invalidates its old mark. Reuse the identity for
  -- this intentional edit, before the scheduled source listener reparses it.
  api.nvim_buf_set_extmark(buffer, anchors, first, 0, { id = item.id,
    end_row = first + #raw, end_col = 0, right_gravity = true,
    end_right_gravity = false, invalidate = true, undo_restore = true, strict = false })
  if not structural then
    -- A validated text edit cannot change code syntax. Shift immutable scope
    -- snapshots instead of reparsing a 20 MB source on every document keypress.
    -- Keep the old snapshots intact so concurrent drafts still detect conflict.
    local delta, updated = #raw - (last - first), {}
    local function moved(row) return row >= last and row + delta or row end
    for _, previous in ipairs(before.items) do
      local copy = vim.tbl_extend("force", {}, previous)
      copy.first, copy.last = moved(previous.first), moved(previous.last)
      copy.scope_first, copy.scope_last = moved(previous.scope_first), moved(previous.scope_last)
      if previous.target_row then copy.target_row = moved(previous.target_row) end
      if previous.id == item.id then copy.first, copy.last, copy.raw = first, first + #raw, raw end
      updated[#updated + 1] = copy
    end
    caches[buffer] = { tick = api.nvim_buf_get_changedtick(buffer), items = updated,
      filetype = before.filetype, supported = before.supported, root_dirty = true, protected = {} }
  end
  return M.by_id(buffer, item.id)
end

function M.decode(item)
  local text, prefixes = {}, {}
  local indent = item.raw[1]:match("^%s*") or ""
  if item.kind == "line" then
    for i, line in ipairs(item.raw) do
      local leading = line:match("^%s*") or ""
      local prefix = leading .. item.marker
      if line:sub(#prefix + 1, #prefix + 1) == " " then prefix = prefix .. " " end
      text[i], prefixes[i] = line:sub(#prefix + 1), prefix
    end
    return text, { prefixes = prefixes, prefix = indent .. item.marker .. " " }
  end
  local opening = item.open
  if opening == "/*" and (#item.raw > 1 or #item.raw[1] - #indent >= 5)
    and item.raw[1]:sub(#indent + 1, #indent + 3) == "/**" then opening = "/**" end
  local first = item.raw[1]:sub(#indent + #opening + 1)
  local last = item.raw[#item.raw]
  if #item.raw == 1 then
    local content = first:sub(1, #first - #item.close):gsub("%s+$", ""):gsub("^ ", "")
    return { content }, { indent = indent, open = opening, close = item.close, single = true }
  end
  if first:match("%S") then text[#text + 1] = first:gsub("^ ", "") end
  for i = 2, #item.raw - 1 do
    local line = item.raw[i]
    local prefix = line:match("^(%s*%* ?)") or (line:sub(1, #indent) == indent and indent or "")
    text[#text + 1], prefixes[#text + 1] = line:sub(#prefix + 1), prefix
  end
  local tail = last:sub(1, #last - #item.close):gsub("%s+$", "")
  if tail:match("%S") then text[#text + 1] = tail:gsub("^%s*%*? ?", "") end
  if #text == 0 then text = { "" } end
  return text, { indent = indent, open = opening, close = item.close, prefixes = prefixes,
    prefix = indent .. (item.open == "/*" and " * " or ""), single = false }
end

function M.encode(item, text)
  local original, format = M.decode(item)
  if vim.deep_equal(original, text) then return vim.deepcopy(item.raw) end
  if item.filetype == "c" or item.filetype == "cpp" or item.filetype == "objc" or item.filetype == "objcpp" then
    for _, line in ipairs(text) do
      assert(not line:match("\\%s*$"), "a trailing backslash can splice C/C++ source lines; draft retained")
    end
  end
  if item.kind == "line" then
    local output = {}
    for i, line in ipairs(text) do output[i] = (format.prefixes[i] or format.prefix) .. line end
    return output
  end
  for _, line in ipairs(text) do
    assert(not line:find(item.close, 1, true), "text contains closing delimiter " .. item.close .. "; draft retained")
    if item.open == "/*" then assert(not line:find("/*", 1, true), "nested block delimiter is unsafe; draft retained") end
  end
  if format.single and #text == 1 then return { format.indent .. format.open .. " " .. text[1] .. " " .. format.close } end
  local output = { format.indent .. format.open }
  for i, line in ipairs(text) do output[#output + 1] = (format.prefixes and format.prefixes[i] or format.prefix
    or format.indent .. (item.open == "/*" and " * " or "")) .. line end
  output[#output + 1] = format.indent .. (item.open == "/*" and " " or "") .. format.close
  return output
end

function M.validate_raw(buffer, item, lines)
  local p = profiles[M.filetype(buffer)]
  local found = p and scan(lines, p, M.filetype(buffer)) or {}
  assert(#found == 1 and found[1].first == 0 and found[1].last == #lines
    and found[1].kind == item.kind, "original view must remain one complete standalone comment; draft retained")
  if item.filetype == "c" or item.filetype == "cpp" then
    for _, line in ipairs(lines) do assert(not line:match("\\%s*$"), "C/C++ line splicing is unsafe; draft retained") end
  end
  return lines
end

function M.insert(buffer, row)
  local p = profiles[M.filetype(buffer)]
  assert(p, "no comment adapter for " .. M.filetype(buffer))
  assert(vim.bo[buffer].modifiable and not vim.bo[buffer].readonly, "source is read-only")
  local existing = M.at(buffer, row)
  if existing and row >= existing.first and row < existing.last then return existing end
  local index = M.index(buffer)
  if index.root_dirty then
    -- Creation needs fresh lexical protection and a syntax node, unlike a
    -- validated edit of the already selected comment body.
    index.tick = -1
    index = M.index(buffer)
  end
  local root = index.root
  if root then
    local line = api.nvim_buf_get_lines(buffer, row, row + 1, false)[1] or ""
    local col = #(line:match("^%s*") or "")
    local node = root:named_descendant_for_range(row, col, row, col)
    while node and node:parent() do
      local kind = node:type()
      if kind:find("function") or kind:find("method") or kind:find("class") or kind:find("struct")
        or kind:find("declaration") then row = node:start(); break end
      node = node:parent()
    end
  end
  assert(not index.protected[row], "cannot insert documentation inside a multiline string or non-projectable comment")
  local previous = row > 0 and api.nvim_buf_get_lines(buffer, row - 1, row, false)[1] or ""
  assert(not previous:match("\\%s*$"), "cannot insert documentation after an explicit line continuation")
  -- Keep interpreter/encoding headers in their required leading positions.
  if row == 0 then
    local header = api.nvim_buf_get_lines(buffer, 0, 2, false)
    while header[row + 1] and (header[row + 1]:match("^#!") or header[row + 1]:match("coding[:=]")) do row = row + 1 end
  end
  local line = api.nvim_buf_get_lines(buffer, row, row + 1, false)[1] or ""
  local indent = line:match("^%s*") or ""
  local raw = p.create and { indent .. p.create .. " " }
    or { indent .. p.create_block[1], indent .. " ", indent .. p.create_block[2] }
  api.nvim_buf_set_lines(buffer, row, row, false, raw)
  return M.at(buffer, row)
end

return M
