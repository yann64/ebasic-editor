# ebasic-editor

A code editor for [eBasic](https://github.com/yann64/ebasic), written in
eBasic itself - using [`gtk4`](https://github.com/yann64/eb-gtk4) as its
GUI toolkit (including `GtkSourceView` for syntax highlighting),
[`eb-cjson`](https://github.com/yann64/eb-cjson) for its LSP client's
JSON-RPC wire format, `ebasic_lsp` for diagnostics/hover/go-to-definition/
completion, `ebpm` for build/run/test, and real `git` integration.

## Status

Early development, Linux-only (matching `eb-gtk4`'s own current scope). A
single window with a `GtkSourceView`, real eBasic syntax highlighting
(`data/language-specs/ebasic.lang`), Open/Save (via `GtkFileChooserNative`,
plus `Ctrl+S`), undo/redo, a modified-indicator in the window title, a
real `ebasic_lsp` client (live diagnostics, hover (`F1`),
go-to-definition (`F12`), and completion (`Ctrl+Space`)), and now
Build/Run/Test buttons spawning real `ebpm` commands with a streaming
output panel. No `git` integration yet - the final slice.

## Build/Run/Test (`ebpm`)

The header bar's Build/Run/Test buttons spawn `ebpm build`/`run`/`test`
(found on `PATH`, alongside `ebc`/`ebasic_lsp`) via the same
`GSubprocess` primitive `src/lsp.bas` uses - see `src/buildrun.bas`. The
package root is found by walking up from the currently open file's own
directory looking for `ebasic.toml`, the same convention `ebpm`/
`ebasic_lsp` themselves use ("open a file inside an `ebpm` package
first" if none is found). Output streams into a read-only panel below
the editor (a resizable `GtkPaned` split) one line at a time as it
arrives - async, so a slow build never freezes the window - followed by
a `(finished successfully)`/`(exited with a non-zero status)` line once
the process exits.

## Language server (`ebasic_lsp`)

`src/lsp.bas` spawns `ebasic_lsp` (found on `PATH`, alongside `ebc`/
`ebpm`) via `gtk4`'s `GSubprocess` bindings and speaks its real
`Content-Length`-framed JSON-RPC protocol over stdio (see
[`docs/guide/lsp.md`](https://github.com/yann64/ebasic/blob/main/docs/guide/lsp.md)
in the main `ebasic` repo) - the wire format itself is built with
`eb-cjson`.

- **Diagnostics**: every edit sends a `textDocument/didChange`
  notification; the resulting `textDocument/publishDiagnostics` is
  rendered as a real `GtkTextTag` squiggle (`PANGO_UNDERLINE_ERROR`/
  `_SINGLE`, see `gtk4`'s own `TextBufferCreateUnderlineTag` - added
  specifically for this), plus a problem count in the status bar.
- **Hover** (`F1`), **go-to-definition** (`F12`), and **completion**
  (`Ctrl+Space`) all show their result in the status bar - not an
  interactive tooltip/popover/completion-list popup. This is a
  deliberate v1 scope cut: `gtk4` has no tooltip-forcing or popover
  bindings yet, and building one specifically for this would be new,
  unverifiable-in-this-sandbox GTK surface rather than reusing what
  already exists. Completion in particular just prints the (up to 8)
  candidate labels as text to type from, not something to click.
- **Single-document scope**: a `publishDiagnostics` for a file other than
  the one currently open (e.g. an `#include`d file) isn't rendered
  inline; a go-to-definition landing in a different file reports where
  it is instead of jumping (this editor has no multi-file/tab support
  yet - see the main repo's own roadmap for that scope cut).
- **No debouncing**: every keystroke sends a full-text `didChange` -
  matching the server's own full-text-replace sync model and its own
  reasoning ("files are small enough that incremental sync isn't worth
  the complexity" - see `lsp.md`).
- `tests/lsp_client_smoke.bas` drives the whole client against a real,
  spawned `ebasic_lsp` headlessly (`GtkSourceBuffer`/`GtkTextTag` need no
  display to construct or operate on, unlike a real `GtkWidget` - see
  `eb-gtk4`'s own `idiomatic_smoke.bas` doc comment) - initialize, a real
  Sema error surfacing and clearing, hover, go-to-definition, and
  completion, all verified end to end under `ebpm test`.

## Editing

Open/Save buttons in the header bar (and `Ctrl+S`) read/write the buffer's
content via `gtk4`'s plain-path file I/O (`ReadFileContents`/
`WriteFileContents`); Undo/Redo buttons call `GtkSourceView`'s own built-in
undo manager directly - `Ctrl+Z`/`Ctrl+Shift+Z` already work out of the
box via the widget's own default key bindings, no extra wiring needed for
those. The window title shows the current file's name with a leading `*`
while there are unsaved changes, kept in sync via the buffer's own
`"modified-changed"` signal.

## Syntax highlighting

`data/language-specs/ebasic.lang` is a real GtkSourceView language-spec
file for eBasic (keywords/types/booleans/comments/doc-comments/
preprocessor directives/strings, all pulled from the real lexer's own
keyword table, not guessed) - loaded via a custom search path (this
repo's own directory), no system install needed:

```basic
DIM mgr AS SourceLanguageManager
mgr = SourceLanguageManagerGetDefault()
CALL SourceLanguageManagerAppendSearchPath(mgr, "data/language-specs")

DIM lang AS SourceLanguage
lang = SourceLanguageManagerGetLanguage(mgr, "ebasic")
```

## Building

```sh
ebpm build
ebpm run
```

Requires a real GTK4 display backend to actually show a window (this is a
GUI application - there's no headless mode). Requires `ebc`/`ebpm` built
from a version including the upstream compiler fixes `eb-gtk4` itself
needed (see its own README) - both are automatically fetched via `ebpm`'s
registry (`gtk4`/`eb-cjson`), no manual setup beyond the GTK4 dev
libraries themselves. `ebasic_lsp` must be on `PATH` (built alongside
`ebc`/`ebpm` from the main `ebasic` repo) for diagnostics/hover/
go-to-definition/completion to work - the editor itself still runs fine
without it, just with those features disabled (see the status bar's own
startup message).

## Architecture

- The editor itself is a real eBasic program (an `ebpm [bin]` package) -
  the only way anything can "use `gtk4` as its GUI toolkit" is by being
  written in eBasic and depending on it, exactly like any other consumer
  of a `[lib]` package.
- `ebasic_lsp` is spawned as a child process via `gtk4`'s `GSubprocess`
  bindings - the same portable, async-capable subprocess primitive used
  for `ebpm`/`git` too, so there's exactly one way this program ever talks
  to another process.
- See [`docs/architecture/roadmap.md`](https://github.com/yann64/ebasic/blob/main/docs/architecture/roadmap.md)
  in the main `ebasic` repo for the full plan this was built from,
  including its explicit scope cuts (Linux-only, single-document editing,
  no branch/merge UI, a flat file list rather than a recursive tree).
