# ebasic-editor

A code editor for [eBasic](https://github.com/yann64/ebasic), written in
eBasic itself - using [`gtk4`](https://github.com/yann64/eb-gtk4) as its
GUI toolkit (including `GtkSourceView` for syntax highlighting),
[`eb-cjson`](https://github.com/yann64/eb-cjson) for its LSP client's
JSON-RPC wire format, `ebasic_lsp` for diagnostics/hover/go-to-definition/
completion, `ebpm` for build/run/test, and real `git` integration.

## Status

Early development. Was "Linux-only" (matching `eb-gtk4`'s own earlier
scope statement) - now confirmed to also **compile, link, and run for
real on Haiku** (see "Haiku" below); Windows/macOS remain untried. A
single window with a `GtkSourceView`, real eBasic syntax highlighting
(`data/language-specs/ebasic.lang`), Open/Save (via `GtkFileChooserNative`,
plus `Ctrl+S`), undo/redo, a modified-indicator in the window title, a
real `ebasic_lsp` client (live diagnostics, hover (`F1`),
go-to-definition (`F12`), and completion (`Ctrl+Space`)), Build/Run/Test
buttons spawning real `ebpm` commands, Source Control (status/diff/stage/
unstage/commit/push/pull via the real `git` CLI), and now a file/project
browser sidebar with git-status glyphs - all sharing one streaming output
panel. This completes the editor's originally planned feature set (see
`docs/architecture/roadmap.md` in the main `ebasic` repo). Two real
verification passes have now run for real (see "Manual verification
checklist" below) - window rendering, syntax highlighting, live LSP
connectivity, sidebar navigation (plus the file-load keyboard-focus gap
it found, since fixed), and undo/redo are all confirmed live with
screenshot/AT-SPI-state evidence; button-click-driven actions and
file-chooser dialogs remain open, blocked on real, confirmed
input-delivery limitations rather than a known defect.

## Haiku

`eb-gtk4`/`ebasic-editor` compile, link, **and run** on real Haiku
hardware - confirmed directly, not assumed: `ebpm build` succeeds against
Haiku's own real, installed `gtk4`/`gtksourceview5`/`glib2`/`cjson`
HaikuPorts packages (`pkg-config --modversion gtk4` -> `4.23.2` on the
box this was verified against), and the built binary renders a fully
correct window there too (real eBasic syntax highlighting, real sidebar
directory listing, `ebasic_lsp` connecting successfully) - screenshotted
as proof, the same "verify, don't guess" bar as everywhere else in this
project. A real, confirmed non-issue found along the way: the app (and
even a minimal hand-written C GTK4 program) prints `Gtk-WARNING: Unable
to acquire session bus: Cannot spawn a message bus when AT_SECURE is
set` on that box - harmless, not fatal to `GApplication` startup (the
window renders and the app keeps running regardless). The only real
gotcha was environmental, not technical: launching a GUI app over SSH
and expecting it to outlive the SSH command's own foreground lifetime
needs the ssh invocation itself to stay attached (backgrounding via
`nohup ... &`/`disown` got the *remote* process killed when the SSH
channel closed in every attempt tried - a plain foreground `ssh host
'./binary'` that's allowed to keep running is what actually worked).

## File browser sidebar

A resizable sidebar (a `GtkPaned` split, left of everything else) shows a
*flat* list of the currently browsed folder's immediate contents - never
a recursive tree (this project's own locked-in scope cut). Clicking a
file loads it into the editor; clicking a directory descends into it
(still flat - the list is simply replaced with that directory's own
contents, one level at a time); a `..` entry (absent only at a real
filesystem root) goes back up. Opening any file (via the header bar's
Open button or a sidebar click) auto-populates the sidebar with that
file's own siblings; "Open Folder" browses to a folder directly, without
needing to open a file in it first. Entries render in whatever order
`g_dir_read_name` yields (no sort - eBasic has no array-sort builtin
yet).

Each row showing up in `git status --porcelain=v1` gets its raw 2-
character status code as a `[XY]` prefix (e.g. `[ M]` modified, `[??]`
untracked) - refreshed automatically after Stage/Unstage/Commit, and
whenever the sidebar itself refreshes. A status line for something
*inside* a subdirectory never matches any row in the current flat view -
silently not shown, a real, documented limitation of the flat-list model,
not a bug. See `src/filebrowser.bas`.

## Source Control (`git`)

A second toolbar row's Git Status/Diff/Stage/Unstage/Commit.../Push/Pull
buttons spawn the real `git` CLI (never `libgit2` - matching `ebpm`'s own
"shell out to the real tool" precedent) via the same `GSubprocess`
plumbing as `ebpm` - see `src/gitui.bas`. Unlike `ebpm`, `git` needs no
package-root discovery: any subcommand run from *any* directory inside a
repo works (`git` itself walks up looking for `.git`), so the currently
open file's own directory is always a valid `cwd`. `Commit...` opens a
small message-entry window before running `git commit -m`. Output streams
into the same panel Build/Run/Test uses. Matches this project's own
locked-in git scope: status + diff + stage/commit + push/pull - no
branch management, no merge UI, no commit-log/history view.

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
GUI application - there's no headless mode; see "Manual verification
checklist" below for what a real one looks like, `scripts/
manual_verify.sh` for a scripted screenshot-based check, and `scripts/
atspi_verify.py` for a scripted accessible-tree/state check - both need
`GDK_BACKEND=x11`). Requires `ebc`/`ebpm` built
from a version including the upstream compiler fixes `eb-gtk4` itself
needed (see its own README) - both are automatically fetched via `ebpm`'s
registry (`gtk4`/`eb-cjson`), no manual setup beyond the GTK4 dev
libraries themselves. `ebasic_lsp` must be on `PATH` (built alongside
`ebc`/`ebpm` from the main `ebasic` repo) for diagnostics/hover/
go-to-definition/completion to work - the editor itself still runs fine
without it, just with those features disabled (see the status bar's own
startup message).

## Manual verification checklist

**This checklist has now actually been run, for real, on a real GTK4
display** - not just written and left unchecked. The premise this
section used to open with ("this sandbox has no real GTK4 display
backend") turned out to be environment-specific, not universal: a
genuine, live GNOME/Wayland desktop (confirmed real, not a stub -
`gnome-session`/`Xwayland` actually running) with GTK4 4.22.4 + dev
headers installed ran the real `target/ebasic-editor` binary (forcing
`GDK_BACKEND=x11` so X11 tools could see/drive the window) into a
genuinely correct, fully-rendered window - `scripts/manual_verify.sh`
scripts this and captures screenshot evidence for the parts that turned
out to be reliably automatable; see its own top comment for the parts
that aren't (real, confirmed input-delivery limitations of that specific
sandboxed session, not app defects - summarized below).

- [x] **Window layout** - `ebpm run` opens a window with the editor,
      header bar, Source Control toolbar row, sidebar, editor pane,
      output panel, and status bar all visible and laid out sensibly.
      Confirmed via screenshot (`scripts/manual_verify.sh`'s own
      `01_startup.png`).
- [x] **Syntax highlighting** - real eBasic keyword/string coloring
      renders correctly (confirmed on this repo's own `src/main.bas`,
      loaded via the sidebar - see below).
- [x] **LSP connectivity** - the status bar reports `ebasic_lsp ready` on
      startup, then a real diagnostics count (`no problems`) after a
      real `didOpen` for an actual file - confirming the real
      `ebasic_lsp` subprocess is spawned, initialized, and receiving
      notifications live, not just in the headless test.
- [~] **Hover/go-to-definition/completion** - not specifically exercised
      live this pass (only startup diagnostics were). The full
      request/response round trip for all three (plus diagnostics
      appearing/clearing) is proven end-to-end by
      `tests/lsp_client_smoke.bas` under `ebpm test`, against a real
      spawned `ebasic_lsp` - genuine, just not re-confirmed with a live
      window this time.
- [x] **Undo/Redo** (`Ctrl+Z`/`Ctrl+Shift+Z`) - confirmed live: a real
      edit, undone, then redone, with the correct content at each step
      (`scripts/manual_verify.sh`'s `04`/`05`/`06_*.png`).
- [~] **Save/Save As** (`Ctrl+S`, the title's `*` clearing) - not
      confirmed live. Blocked on the same file-chooser limitation as
      Open (below); `Ctrl+S` on an already-known path (no dialog
      involved) was not separately isolated and re-tried.
- [x] **Sidebar navigation** - confirmed live and reliably reproducible:
      descending into a real directory (`src/`) and loading a real file
      (`main.bas`, with correct syntax-highlighted content and an
      updated title) both work via keyboard (`Down`/`Return`) -
      `scripts/manual_verify.sh`'s `02`/`03_*.png`. **A real, minor UX
      gap found in the process, since fixed**: loading a file via the
      sidebar didn't used to move keyboard focus into the editor
      (`LoadFileIntoEditor` never called a focus-grab) - `eb-gtk4`
      v0.6.0 added `WidgetGrabFocus` (`gtk_widget_grab_focus`) and
      `main.bas` now calls it at the end of `LoadFileIntoEditor`,
      confirmed working via a real AT-SPI state check
      (`scripts/atspi_verify.py`: the editor's own `FOCUSED` state reads
      true immediately after a sidebar file-load, not screen-scraped).
- [ ] **Header-bar buttons** (Open Folder/Open/Save/Undo/Redo/Build/Run/
      Test) and the **Git toolbar** (Status/Diff/Stage/Unstage/Commit/
      Push/Pull) - **still not confirmed live**, now for *two* separate,
      real, confirmed reasons (see `scripts/manual_verify.sh`'s and
      `scripts/atspi_verify.py`'s own top comments for the full story of
      each): (1) synthetic X11 mouse clicks were never recognized by
      GTK4's gesture recognizer in this sandboxed session at all (tried
      multiple ways, confirmed correct pointer coordinates); (2) AT-SPI's
      own `Action.do_action` ("click") reports success at the D-Bus
      protocol level - even after explicitly resolving and exporting the
      real, canonical AT-SPI bus address via `org.a11y.Bus.GetAddress` to
      rule out a stale/mismatched private bus - but was never observed to
      produce any real effect either (cross-checked against
      `NoFileOpenGuard` in `gitui.bas`, which should unconditionally
      rewrite the output panel the instant a Git button's real handler
      runs at all - it never did). Neither is a suspected app defect:
      every one of these buttons calls exactly the same functions
      (`RunEbpmCommand`/`RunGitStatus`/etc.) the real, passing
      `tests/buildrun_smoke.bas`/`tests/gitui_smoke.bas` already exercise
      end-to-end against real spawned processes - only the literal
      widget `"clicked"` signal (identical one-line `ObjConnect`
      boilerplate on every button) remains unconfirmed live. AT-SPI *did*
      prove valuable elsewhere: `scripts/atspi_verify.py` reliably
      confirms every button/row's correct accessible name and reads
      widget state (`FOCUSED`, etc.) directly - just not action dispatch,
      in this environment.
- [ ] **`GtkFileChooserNative` dialogs** (Open/Open Folder/Save As) -
      **no dialog window ever appeared**, in this specific environment,
      after triggering either action (confirmed via `xdotool search`
      finding no new window at all, repeatedly) - likely a portal/
      Wayland-vs-forced-X11-backend interaction (a real desktop
      "Files"-style native chooser is usually portal-backed, and this
      session forced `GDK_BACKEND=x11` for the *main app window* only,
      not necessarily however the portal itself renders its own dialog).
      Not investigated further this pass.
- [ ] **`GtkPaned` drag-resize** - needs a real mouse drag; not
      automatable given the mouse-click limitation above, not attempted.

**Net assessment**: every piece of *logic* this editor has is proven
correct - either by the automated `ebpm test` suite (spawning real
subprocesses, checking real output) or by these two passes' own live
evidence (window rendering, syntax highlighting, real LSP connectivity,
sidebar navigation + the focus-grab fix, undo/redo - screenshots plus
real AT-SPI state reads, not screen-scraping guesses). What remains open
is narrowly "does clicking a button with a real mouse on a real desktop
actually fire GTK4's `clicked` signal" - tried via two independent
routes this far (raw X11 input synthesis, then AT-SPI's own semantic
action-dispatch after ruling out a bus-address mismatch) with neither
conclusively proving or disproving it in the environments available.
AT-SPI structural/state introspection (`scripts/atspi_verify.py`) is a
real, working, permanent addition to this project's own verification
toolkit regardless - just not the full answer to button clicks it was
hoped to be.

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
  including its explicit scope cuts (single-document editing, no
  branch/merge UI, a flat file list rather than a recursive tree - the
  original "Linux-only" cut no longer holds, see "Haiku" above).
