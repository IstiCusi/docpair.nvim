# docpair.nvim

Read and edit source code beside a matching notes file. A documented view is
managed as a pair of windows, including across native Neovim tabs and buffer
switches. Notes are ordinary text files in `.documented/`.

**This version targets Neovim 0.12 and is tested on stable 0.12.6.**

![Source and sidecar notes](./pic.png)

## Install

```lua
return {
  "IstiCusi/docpair.nvim",
  lazy = false,
  opts = { info_filetype = "markdown" },
}
```

Native packages load `plugin/docpair.lua` without a plugin manager. Optional
configuration:

```lua
require("docpair").setup({ info_filetype = "markdown" })
```

## Open and navigate

```vim
:Documented src/main.c
:Documented src/main.c main_notes.md
:Documented!
```

`:Documented[!] [file] [infofile]` uses the active buffer if `file` is omitted.
The source starts on the left, notes on the right, regardless of `splitright`.
Without `!` it opens a new tab; `!` uses the current window and preserves other
splits. Repeating the command on the same pair keeps the layout and position,
and extends blank padding if the source grew.

| Native operation | Pair behavior |
| --- | --- |
| `:edit`, `:buffer`, `:bnext`, `:bprevious`, Ctrl-^, quickfix jump | Selecting a source inside either pane updates both panes. Notes are excluded from `:bnext`. |
| `:split`, `:tab split` of an associated file | The new source or notes view gets its own partner. |
| `gt`, `gT`, `:tabmove` | Each pair retains its own position; shared buffers retain shared text. |
| Ctrl-W T | The moved pane gets its partner in the destination tab. |
| `:only` | The retained pane gets its partner back. |
| `:close` or `:q` in a pair | Closes the pair, subject to Neovim's checks for modified files. `:q` on the final pair exits. |
| `:tabclose`, `:tabonly` | Removed tabs stay removed. |
| `:bdelete`, `:bwipeout` of a paired buffer | Removes its paired views; normal modified-buffer checks still apply. |
| `:mksession`, `:source Session.vim` | Restores associations using a small companion `Session.vim.docpair.json`. |
| `:saveas`, `:file` | The association follows the renamed buffer. The other file stays at its existing path. |

Registered files shown in other tabs are paired too. Unrelated files opened
outside a pair, help, quickfix, preview and floating windows remain independent.
Several pairs may coexist in one tab. Vertical movement synchronizes only the
actual partner, including wheel scrolling over an unfocused pane. Horizontal
scrolling and cursor columns are independent.

Additional commands:

- `:DocumentedClose` closes the current pair without forcing modified files.
- `:DocumentedDetach` keeps both windows and releases their association in this
  view, restoring the window options captured when it was paired. Run
  `:Documented!` to pair that view again.
- `:DocumentedRepair` reconciles the layout after commands that suppressed
  normal editor events.

## Files and saving

Default notes path: `<source-directory>/.documented/<source-basename>_info`.
A custom `infofile` uses only its basename. If the source directory is not
writable, the existing fallback convention is retained:
`~/.config/docpair/tree<absolute-source-directory>/<notes-name>`.

Opening a pair does **not** write source or notes to disk. It uses the current
loaded buffers, including unsaved text and undo history. Short notes are padded
with empty lines in memory to match the source length. Brand-new empty padding
is not marked as a user edit; padding an existing notes file is a buffer change.
The notes directory is created when notes are first written.

Use `:write` in the relevant pane, or `:wall` for all modified files. Edited notes
remain in a hidden buffer when switching away, even with `nohidden`; they are
included in `:wall` and prevent an unsafe `:qall`. Neovim's explicit force
commands such as `:qall!` retain their normal destructive meaning.

Session metadata stores file paths only, including custom note names. It is not
a backup of unsaved text. Save your work separately. After renaming a buffer,
keep the session metadata if you need the non-default association next time;
the plugin does not rename or copy its partner on disk.

## Limits

- **Line-based, not semantic:** line N corresponds to line N. Inserting or
  deleting lines does not relocate notes to follow a function. Extending blank
  padding cannot repair that semantic drift.
- Both buffers stay loaded. The notes pane shows the whole notes file, not only
  documentation for the current scope. Very long notes remain long physical
  lines because wrapping, folds and concealment are disabled to preserve line
  alignment. Markdown highlighting works; rendered Markdown layouts are not
  guaranteed to remain aligned.
- These are still two native Neovim buffers. The manager coordinates their
  windows; it does not introduce a new indivisible native window type. Manual
  window rearrangement may change their geometry, while their IDs and partner
  association remain intact. Insufficient screen space can prevent a split.
- Commands using `noautocmd`, session tools that skip native session events,
  and plugins that continually replace layouts may require
  `:DocumentedRepair` or explicit integration. Compatibility with every plugin
  is not claimed. Symlink aliases are not canonicalized.
- One source has one sidecar in a running session. Reusing an already associated
  notes path for another source is rejected. Comment extraction, scope anchors,
  independently scrolling document sections and switchable document providers
  are future work.

## Tests

The tests launch real Neovim processes; there are no mocked window APIs.
Python is needed only for development tests, not for using the plugin.

```sh
python -m pip install pynvim pexpect
python tests/run.py --nvim /path/to/nvim --output /tmp/docpair-results.json
python tests/tui.py --nvim /path/to/nvim --output /tmp/docpair-tui.json
```

The integration suite generates files with 50,000, 80,000 and 200,000 source
lines, including a 23 MB notes file and a 16,000-character line. It covers
sessions, multiple pairs, modified buffers, undo, native navigation, mouse
scrolling, resizing and C/Markdown syntax highlighting. The separate TUI test
types commands and navigation into a real terminal, including clean shutdown.

For help, use `:help docpair`. If needed, generate tags with
`:helptags {path-to-docpair.nvim}/doc`.

MIT license.
