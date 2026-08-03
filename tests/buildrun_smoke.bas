' Smoke test: buildrun.bas's package-root discovery (pure path logic, no
' subprocess) and its real ebpm Build integration end to end - spawns a
' real `ebpm build` against this very package (found by walking up from
' "tests", the same way `ebpm`/`ebasic_lsp` themselves discover a
' package root) and streams its output into a real GtkTextBuffer,
' headlessly (a GtkTextBuffer holds text but never renders anything
' itself, unlike a real GtkWidget - see eb-gtk4's own idiomatic_smoke.bas
' doc comment), driving GLib's own main loop by hand.

#include "gtk4.iface.bas"
#include once "../src/buildrun.bas"

PRINT DirOf("tests/buildrun_smoke.bas")
PRINT FindPackageRoot("tests")
PRINT FindPackageRoot("/nonexistent/deeply/nested/path/that/does/not/exist")

DIM outputBuf AS TextBuffer
outputBuf = NewTextBuffer()
CALL BuildRunInit(outputBuf)
CALL RunEbpmCommand("build", 1, "tests/buildrun_smoke.bas")

' Pump (bounded) until the build finishes - gBuildRunning flips back to 0
' once OnBuildExit fires.
DIM tries AS INTEGER
tries = 0
DO WHILE gBuildRunning <> 0 AND tries < 2000
    CALL g_main_context_iteration(0, -1)
    tries = tries + 1
LOOP
PRINT gBuildRunning

DIM rawText AS ANY PTR
rawText = TextBufferGetText(outputBuf)
DIM viaZstring AS ZSTRING
viaZstring = rawText
DIM text AS STRING
text = viaZstring
CALL FreeGMallocString(rawText)
PRINT text

' No file open at all - a real no-op, not a spawn attempt.
DIM outputBuf2 AS TextBuffer
outputBuf2 = NewTextBuffer()
CALL BuildRunInit(outputBuf2)
CALL RunEbpmCommand("build", 0, "")
DIM rawText2 AS ANY PTR
rawText2 = TextBufferGetText(outputBuf2)
DIM viaZstring2 AS ZSTRING
viaZstring2 = rawText2
DIM text2 AS STRING
text2 = viaZstring2
CALL FreeGMallocString(rawText2)
PRINT text2

PRINT "buildrun smoke ok"
