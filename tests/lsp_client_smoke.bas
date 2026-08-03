' Smoke test: the LSP client (src/lsp.bas) driving a real, spawned
' ebasic_lsp end to end - display-independent (GtkSourceBuffer/GtkTextTag
' never render anything themselves and need no GTK4 display backend to
' construct, unlike a real GtkWidget - see eb-gtk4's own
' idiomatic_smoke.bas doc comment on why this test uses LspInitHeadless,
' not LspInit, to avoid constructing a real GtkLabel; this file also
' drives GLib's own main loop by hand via g_main_context_iteration, no
' GtkApplication/window needed at all), so this runs safely under `ebpm
' test`. Exercises the full Content-Length-framed JSON-RPC round trip
' against the real server binary: initialize, didOpen with a real Sema
' error, the resulting publishDiagnostics rendering as a real GtkTextTag
' application, a didChange that fixes it, hover, go-to-definition, and
' completion.

#include "gtk4.iface.bas"
#include once "../src/lsp.bas"

DIM buf AS SourceBuffer
buf = NewSourceBuffer()

CALL LspInitHeadless(buf)

DIM started AS INTEGER
started = LspStart("ebasic_lsp")
PRINT started

DIM ready AS INTEGER
ready = LspInitialize()
PRINT ready

' A document with one real Sema error (assigning a STRING to an INTEGER) -
' the exact same error the compiler's own LSP diagnostics_test.sh uses.
' Written as a single logical line via ":" (eBasic's statement separator)
' since eBasic's STRING has no CHR$ equivalent yet to embed a real
' newline byte directly - a real, valid multi-statement eBasic program
' either way.
DIM diagCountBefore AS INTEGER

diagCountBefore = gLspDiagUpdateCount
CALL LspDidOpen("file:///tmp/lsp_client_smoke.bas", "DIM x AS INTEGER : x = ""oops""")
CALL LspWaitForDiagUpdate(diagCountBefore)
PRINT gLspLastStatus

' Fix the error via a didChange - the server should re-publish an empty
' diagnostics set, clearing the status back to "no problems".
diagCountBefore = gLspDiagUpdateCount
CALL LspDidChange("DIM x AS INTEGER : x = 5 : PRINT x")
CALL LspWaitForDiagUpdate(diagCountBefore)
PRINT gLspLastStatus

' Hover over "x" in "DIM x AS INTEGER" (0-based line 0, column 4).
CALL LspRequestHover(0, 4)
PRINT gLspLastStatus

' Go to definition of "x" from its use in "PRINT x" (column 33 in
' "DIM x AS INTEGER : x = 5 : PRINT x") - should place the cursor back on
' line 0 (its own DIM statement) - column 0, not 4: a declaration's
' recorded location is the statement's own start, not the identifier's
' (same "one point per node" granularity as diagnostic ranges - see
' docs/guide/lsp.md in the main eBasic repo).
CALL LspRequestDefinition(0, 33)
PRINT gLspLastStatus
PRINT TextBufferGetCursorLine(buf)
PRINT TextBufferGetCursorColumn(buf)

' Completion after "PRIN" (column 27..30 in "DIM x AS INTEGER : x = 5 :
' PRINT x") - offering every reserved keyword/in-scope name (see
' lsp.md's own LSP-6 notes), so PRINT itself is guaranteed present.
CALL LspRequestCompletion(0, 27)
PRINT gLspLastStatus

CALL LspStop()
PRINT started
PRINT ready
PRINT "lsp client smoke ok"
