' Smoke test: the LSP client (src/lsp.bas) driving a real, spawned
' ebasic_lsp end to end - display-independent (GtkSourceBuffer/GtkTextTag/
' plain TextBuffer never render anything themselves and need no GTK4
' display backend to construct, unlike a real GtkWidget - see eb-gtk4's
' own idiomatic_smoke.bas doc comment on why this test uses
' LspInitHeadless, not LspInit, to avoid constructing a real GtkLabel or
' GtkSourceCompletion; this file also drives GLib's own main loop by hand
' via g_main_context_iteration, no GtkApplication/window needed at all),
' so this runs safely under `ebpm test`. Exercises the full
' Content-Length-framed JSON-RPC round trip against the real server
' binary: initialize, didOpen with a real Sema error, the resulting
' publishDiagnostics rendering as a real GtkTextTag application, a
' didChange that fixes it, hover, go-to-definition, and the background
' completion-words refresh (LspRefreshCompletionWords, fired
' automatically by didOpen/didChange - see lsp.bas's own doc comments).

#include "gtk4.iface.bas"
#include once "../src/lsp.bas"

DIM buf AS SourceBuffer
buf = NewSourceBuffer()

DIM completionWordsBuf AS TextBuffer
completionWordsBuf = NewTextBuffer()

CALL LspInitHeadless(buf, completionWordsBuf)

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

' The completion-words buffer should already be populated by now (both
' the didOpen above and the didChange fix each triggered their own
' background LspRefreshCompletionWords) - wait for the most recent one to
' finish, then confirm it holds every reserved keyword/in-scope name (see
' lsp.md's own LSP-6 notes), so PRINT itself is guaranteed present, as is
' the "x" variable this document itself declares.
CALL LspWaitForCompletionRefresh()
DIM rawWords AS ANY PTR
rawWords = TextBufferGetText(completionWordsBuf)
DIM wordsZ AS ZSTRING
wordsZ = rawWords
DIM words AS STRING
words = wordsZ
CALL FreeGMallocString(rawWords)
PRINT INSTR(words, "PRINT") > 0
PRINT INSTR(words, "x") > 0

CALL LspStop()
PRINT started
PRINT ready
PRINT "lsp client smoke ok"
