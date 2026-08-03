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
plus `Ctrl+S`), undo/redo, and a modified-indicator in the window title -
no LSP, `ebpm`, or `git` integration yet; each lands in its own slice.

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
libraries themselves.

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
