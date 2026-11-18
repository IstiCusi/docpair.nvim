# docpair.nvim

Edit source comments in a separate document pane while keeping **one ordinary
source file on disk**. The code pane hides standalone comment blocks; the
neighboring pane shows the comment associated with the code cursor. Each pane
has an independent cursor and scroll position. Existing `.documented` notebooks
remain available as another view.

Requires Neovim **0.12+**; tested on **0.12.6**. No runtime Python dependency.

## Install with lazy.nvim

```lua
return {
  "IstiCusi/docpair.nvim",
  lazy = false,
  opts = {
    initial_view = "text",
    views = { "text", "markdown", "raw", "notes" },
    mappings = {
      cycle = "g<Tab>",       -- Only in the documentation pane
      create = "<leader>dd",  -- Create/open a comment from the source
      source = "<leader>ds",  -- Reveal/hide the complete source
    },
    comments = { hide = true, debounce_ms = 80 },
    info_filetype = "markdown",
  },
}
```

All shown options have these defaults. Set a mapping to `false` to disable it.
`views` replaces the cycle list, including its order. For just two views use
`views = { "text", "notes" }`. Native package users can call
`require("docpair").setup({...})`; the plugin loader respects explicit setup.

To retain the previous notebook-first workflow use
`initial_view = "notes"`. Comment views can still be selected with `g<Tab>`.

## Everyday use

1. Open a source file and run `:Documented!` (current tab) or `:Documented`
   (new tab). Source stays left; documentation stays right.
2. Move the source cursor into a documented function/statement. Its comment
   appears on the right. Moving within the same section preserves the reading
   position. With syntax scopes, nested documented sections take precedence.
3. Use Ctrl-W L to enter the document pane. Read, scroll and edit there without
   moving the code cursor. The selected section stays fixed while you work.
4. Press **g then Tab** in that pane to cycle views. This is normal-mode input,
   not a simultaneous chord. The key can be changed in Lazy's `opts.mappings`.
5. Save with `:write` in a comment view or in the source pane. The complete
   source, including comments, is written to its ordinary filename.

| View | Content | Saving |
| --- | --- | --- |
| `text` (default) | Comment body without its language-specific delimiters | Writes the source file |
| `markdown` | The same body with Markdown filetype, highlighting and concealment | Writes the source file |
| `raw` | Exact original comment, including delimiters and indentation | Writes the source file |
| `notes` | Previous external notebook, associated with this source file | Writes the notebook |

Markdown uses Neovim's Markdown support; it is not a bundled rich renderer.
An optional `on_markdown = function(buffer, window) ... end` hook can attach a
renderer. Existing XML/Javadoc/reStructuredText content is preserved, not
converted to Markdown. Text and raw views require no renderer.

Changing views does not edit the source or add a source undo entry. There are
no projection files on disk. The `docpair://...` buffer names identify in-memory
views. The source buffer always contains its full, current text.

## Create documentation and reveal source

Place the code cursor in a function or at a suitable source line and press
`<leader>dd` or run `:DocumentedAdd`. Existing associated documentation is opened;
otherwise a comment is inserted at the syntax node's start (when available),
and the document pane receives focus. With no parser, insertion is before the
current whole source line. Known multiline strings, heredocs and explicit line
continuations are rejected as unsafe insertion points. Interpreter/encoding
headers keep their leading position.

A `D` sign indicates a hidden comment before its code. The code cursor is kept
on visible source lines. `<leader>ds` / `:DocumentedSource` reveals the complete
source in this pair, without modifying it. A file made entirely of comments
keeps a visible source cursor instead of hiding every line.

Concealment is scoped to managed source windows. Ordinary/floating views of the
same buffer are not concealed by Docpair. Neovim still operates on the actual
file: ranges, substitutions, line numbers and copy/delete operations include
physical comments. Reveal source before moving a function together with its
comment. A jump/search into a hidden comment selects its document and moves
the source cursor to a visible line; reveal source to inspect the exact match.

## Languages and association

Comment codecs are provided for C/C++, Zig, Rust, Lua, Python, JavaScript,
TypeScript, Java, C#, Go, Pascal/Delphi, shell, Ruby, SQL, HTML/XML, CSS and several
related filetypes. Round-trip fixtures cover 17 of these language families.
Only **standalone whole-line comment blocks** are projected. Trailing comments
remain in the source. Compiler/interpreter directives recognized by the
adapters stay visible. Python docstrings remain ordinary source strings and
are not edited as comments in this version.

With an installed Tree-sitter parser, Docpair verifies comment tokens and uses
the next syntax sibling (or containing scope) to associate the comment. For
example, a comment before a C function follows that function's scope; a comment
before a local declaration is a narrower section. The window bar says
`syntax scope` when this information is available.

Without a parser, a string-aware lexer recognizes supported comment forms and
uses the **nearest preceding comment**, up to the next comment. The bar says
`nearest comment`; this is positional, not guaranteed function-scope detection.
Install the relevant Tree-sitter parser for semantic association. Complex
language dialects, embedded languages, directives not recognized by an adapter,
and incomplete syntax need care; reveal source when in doubt. Unsupported
filetypes can still use external notes.

## Editing, undo, and conflicting changes

Edits update the loaded source buffer, not the disk. Both panes share source
changes across tabs. Each pair remembers its own selected section, view and
reading positions. Normal-mode `u` / Ctrl-R in a comment pane operate on the
source undo history; continuous insert-mode typing is grouped while no other
source edit intervenes. The source pane keeps native undo. A view switch adds
no source undo step. Opening and saving an unedited comment preserves its
original formatting, including line endings and indentation.

A projection is checked against its source snapshot before replacement. A
conflicting source edit, missing comment, invalid raw comment, closing block
delimiter in text, or unsafe C/C++ line splice leaves the document as a
**modified draft** and does not overwrite the source. Its window bar explains
the problem. Repair the text, or use `:DocumentedDiscard` to explicitly discard
the unapplied draft and reread the source. View changes are blocked while such
a draft exists. `:DocumentedDrafts` recovers drafts after changing files.

`:write` from a comment view flushes pending edits and writes the source.
`:wall` also saves edited external notebooks. Rename or `:saveas` the **source**
buffer, not a projection. Native forced quit commands retain their destructive
meaning. There is no promise of preserving unflushed drafts after a crash;
applied edits are in the normal source buffer and use its ordinary recovery.

## Paired windows and tabs

| Native operation | Behavior |
| --- | --- |
| `:edit`, `:buffer`, `:bnext`, Ctrl-^ in either pane | Updates the corresponding pair; auxiliary buffers stay out of `:bnext` |
| `:split`, `:tab split` | Creates another pair with independent view/cursor state |
| `gt`, `gT`, `:tabmove` | Retains each pair in its own tab |
| Ctrl-W T | Gives the moved pane a partner in its destination tab |
| `:only` | Keeps/reconstructs the complete pair |
| `:close`, `:q` | Closes the pair with native unsaved-buffer protection |
| `:tabclose`, `:tabonly` | Removed tabs stay removed |
| `:bdelete`, `:bwipeout` of a paired buffer | Removes the affected pair |
| `:mksession`, `:source Session.vim` | Restores file associations and current comment views using a JSON companion |
| `:saveas`, `:file` on source | Keeps the association with the renamed source buffer |

Multiple pairs can share one tab. External notebooks retain the legacy vertical
line coupling; comment views scroll independently. One source has one external
notebook per session. Notebook paths are
`<source-directory>/.documented/<source-basename>_info`; a custom filename is
accepted by `:Documented file custom.md`. Read-only directories retain the
`~/.config/docpair/tree<absolute-source-directory>/...` fallback. Notes are
loaded/padded when that view is first used, and written only on save.

Session metadata contains associations, view names and positions, not content
backups. Save source and notebooks before restoring a session. Invalid drafts
block restoration. Tools that suppress native editor events or replace layouts
may need `:DocumentedRepair`; compatibility with every plugin is not claimed.
Window-scoped hiding currently uses Neovim 0.12's namespace scoping API.

## Commands

- `:Documented[!] [file] [infofile]`: open/reuse a pair; an explicit infofile opens notes.
- `:DocumentedView [text|markdown|raw|notes]`: select an enabled view, or cycle.
- `:DocumentedAdd`: create/open documentation at the source cursor.
- `:DocumentedSource`: show/hide source comments in this pair.
- `:DocumentedDiscard`: discard an unapplied draft.
- `:DocumentedDrafts`: find and reopen unapplied drafts.
- `:DocumentedClose`: close the current pair.
- `:DocumentedDetach`: retain the panes, release pair management and restore options.
- `:DocumentedRepair`: reconcile pairs after suppressed editor events.

## Development tests

```sh
python -m pip install pynvim pexpect
python tests/run.py --nvim /path/to/nvim
python tests/comments.py --nvim /path/to/nvim
python tests/tui.py --nvim /path/to/nvim
python tests/comments_tui.py --nvim /path/to/nvim
```

These launch real Neovim processes. The two TUI tests type keys into real
pseudo-terminals. Stress fixtures include 200,000 code lines, a roughly 23 MB
inline document, 20,000 small comments, and large external notebooks. Result
JSON files are in `tests/results/`. C compilation is checked when `cc` exists.
See `examples/lazy.lua`, `examples/tutorial.c` and `doc/COMMENT_VIEWS_DE.md`.

MIT license.
