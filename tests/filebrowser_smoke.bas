' Smoke test: filebrowser.bas's pure logic (ListDirectory,
' ParseGitStatusLine, ComputeGitDecorations - none of these touch a
' widget) against a real, throwaway fixture directory + git repo (never
' this project's own working repo - see tests/gitui_smoke.bas's own doc
' comment on why). RefreshSidebarListBox/OnSidebarRowActivated (the
' widget-touching pieces) aren't exercised here - manual-verify only,
' per this sandbox's own lack of a usable GTK4 display.

#include "gtk4.iface.bas"
#include once "../src/filebrowser.bas"

Declare Function system Lib "c" (ByVal command AS ZSTRING) AS INTEGER

''' A stub - the real LoadFileIntoEditor lives in main.bas (it touches
''' gBuf/gCurrentPath/gHasPath, none of which exist outside the full
''' app), so OnSidebarRowActivated's own reference to it needs *something*
''' to resolve against when filebrowser.bas is compiled standalone, even
''' though this test never actually triggers a row activation.
SUB LoadFileIntoEditor(BYVAL path AS STRING)
END SUB

DIM setupOk AS INTEGER
setupOk = system("rm -rf /tmp/ebasic_editor_filebrowser_test && " & _
    "mkdir -p /tmp/ebasic_editor_filebrowser_test/subdir && " & _
    "cd /tmp/ebasic_editor_filebrowser_test && " & _
    "git init -q && " & _
    "git config user.email test@test && " & _
    "git config user.name test && " & _
    "echo original > tracked.bas && " & _
    "git add tracked.bas && " & _
    "git commit -q -m first && " & _
    "echo modified >> tracked.bas && " & _
    "echo new > untracked.bas")
PRINT setupOk

''' Returns the index of `name` in gSidebarEntries (searching all
''' gSidebarCount valid slots), or -1 if not found - order isn't
''' guaranteed (g_dir_read_name's own filesystem-dependent order, no
''' sort), so tests look entries up by name rather than assuming position.
FUNCTION FindEntryIndex(BYVAL name AS STRING) AS INTEGER
    DIM i AS INTEGER
    FOR i = 0 TO gSidebarCount - 1
        IF gSidebarEntries(i) = name THEN
            FindEntryIndex = i
            EXIT FUNCTION
        END IF
    NEXT i
    FindEntryIndex = -1
END FUNCTION

' --- ListDirectory ---------------------------------------------------

CALL ListDirectory("/tmp/ebasic_editor_filebrowser_test")
PRINT gSidebarCount                        ' 5: "..", .git, tracked.bas, untracked.bas, subdir
PRINT gSidebarEntries(0)                   ' ".." is always entry 0 for a non-root folder
PRINT gSidebarIsDir(0)

DIM idx AS INTEGER
idx = FindEntryIndex("tracked.bas")
PRINT idx >= 0
PRINT gSidebarIsDir(idx)                   ' 0 - a file

idx = FindEntryIndex("subdir")
PRINT idx >= 0
PRINT gSidebarIsDir(idx)                   ' -1 - a directory

idx = FindEntryIndex(".git")
PRINT idx >= 0
PRINT gSidebarIsDir(idx)                   ' -1 - a directory

idx = FindEntryIndex("untracked.bas")
PRINT idx >= 0

idx = FindEntryIndex("nonexistent.bas")
PRINT idx                                  ' -1 - not found

' A subdirectory listing (subdir is empty) - just ".." plus nothing else.
CALL ListDirectory("/tmp/ebasic_editor_filebrowser_test/subdir")
PRINT gSidebarCount                        ' 1: only ".."
PRINT gSidebarEntries(0)

' --- ParseGitStatusLine ------------------------------------------------

DIM glyph AS STRING
DIM name AS STRING
DIM parsed AS INTEGER

parsed = ParseGitStatusLine(" M lib.bas", glyph, name)
PRINT parsed
PRINT glyph
PRINT name

parsed = ParseGitStatusLine("?? scratch.bas", glyph, name)
PRINT parsed
PRINT glyph
PRINT name

parsed = ParseGitStatusLine("A  new.bas", glyph, name)
PRINT parsed
PRINT glyph
PRINT name

parsed = ParseGitStatusLine("R  old.bas -> new.bas", glyph, name)
PRINT parsed
PRINT glyph
PRINT name                                 ' "old.bas -> new.bas" - a real limitation (renames aren't split), documented

parsed = ParseGitStatusLine("", glyph, name)
PRINT parsed                               ' 0 - too short to parse

' --- ComputeGitDecorations (a real subprocess, against the fixture repo) ---

CALL ListDirectory("/tmp/ebasic_editor_filebrowser_test")
CALL ComputeGitDecorations()

idx = FindEntryIndex("tracked.bas")
PRINT gSidebarGlyph(idx)                   ' " M" - modified, unstaged

idx = FindEntryIndex("untracked.bas")
PRINT gSidebarGlyph(idx)                   ' "??" - untracked

idx = FindEntryIndex("subdir")
PRINT gSidebarGlyph(idx)                   ' "" - no status (nothing inside it)

idx = FindEntryIndex(".git")
PRINT gSidebarGlyph(idx)                   ' "" - never reported by git status itself

PRINT "filebrowser smoke ok"
