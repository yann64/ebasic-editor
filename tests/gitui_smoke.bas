' Smoke test: gitui.bas's status/diff/stage/unstage against a real,
' throwaway git repository (never the actual ebasic-editor working repo
' itself - running `git add`/`git restore --staged` against a real
' project's own repo as a side effect of an automated test would be a
' genuinely unwanted side effect, not just a test-hygiene nicety).
' push/pull/commit aren't exercised here - they'd mutate a real remote/
' history, which a test must never do; RunGitCommit/Push/Pull are
' otherwise-identical thin wrappers around the same StartGitSpawn plumbing
' status/diff/stage/unstage already verify end to end.
'
' `system()` (libc) builds the throwaway fixture repo - test-only setup,
' not part of the shipped app (which never shells out except via
' GSubprocess, see gitui.bas's own top doc comment).

#include "gtk4.iface.bas"
#include once "../src/gitui.bas"

Declare Function system Lib "c" (ByVal command AS ZSTRING) AS INTEGER

DIM setupOk AS INTEGER
setupOk = system("rm -rf /tmp/ebasic_editor_gitui_test && " & _
    "mkdir -p /tmp/ebasic_editor_gitui_test && " & _
    "cd /tmp/ebasic_editor_gitui_test && " & _
    "git init -q && " & _
    "git config user.email test@test && " & _
    "git config user.name test && " & _
    "echo hello > file.bas && " & _
    "git add file.bas && " & _
    "git commit -q -m first && " & _
    "echo changed >> file.bas")
PRINT setupOk

DIM outputBuf AS TextBuffer
outputBuf = NewTextBuffer()
CALL GitUiInit(outputBuf)

DIM path AS STRING
path = "/tmp/ebasic_editor_gitui_test/file.bas"

' git status - a real, dirty (unstaged-change) working tree.
CALL RunGitStatus(1, path)
DIM tries AS INTEGER
tries = 0
DO WHILE gGitRunning <> 0 AND tries < 500
    CALL g_main_context_iteration(0, -1)
    tries = tries + 1
LOOP

DIM rawText AS ANY PTR
rawText = TextBufferGetText(outputBuf)
DIM viaZstring AS ZSTRING
viaZstring = rawText
DIM text AS STRING
text = viaZstring
CALL FreeGMallocString(rawText)
PRINT text

' git diff - the real unstaged "changed" line should show up.
CALL RunGitDiff(1, path)
tries = 0
DO WHILE gGitRunning <> 0 AND tries < 500
    CALL g_main_context_iteration(0, -1)
    tries = tries + 1
LOOP
DIM rawDiff AS ANY PTR
rawDiff = TextBufferGetText(outputBuf)
DIM viaZstring2 AS ZSTRING
viaZstring2 = rawDiff
DIM diffText AS STRING
diffText = viaZstring2
CALL FreeGMallocString(rawDiff)
PRINT diffText

' Stage, then unstage - both are real `git add`/`git restore --staged`
' against the throwaway repo.
CALL RunGitStage(1, path)
tries = 0
DO WHILE gGitRunning <> 0 AND tries < 500
    CALL g_main_context_iteration(0, -1)
    tries = tries + 1
LOOP
PRINT gGitRunning

CALL RunGitUnstage(1, path)
tries = 0
DO WHILE gGitRunning <> 0 AND tries < 500
    CALL g_main_context_iteration(0, -1)
    tries = tries + 1
LOOP
PRINT gGitRunning

' No file open at all - a real no-op, not a spawn attempt.
CALL RunGitStatus(0, "")
DIM rawText3 AS ANY PTR
rawText3 = TextBufferGetText(outputBuf)
DIM viaZstring3 AS ZSTRING
viaZstring3 = rawText3
DIM text3 AS STRING
text3 = viaZstring3
CALL FreeGMallocString(rawText3)
PRINT text3

PRINT "gitui smoke ok"
