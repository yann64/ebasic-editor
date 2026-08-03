' File/project browser sidebar: a flat list of the currently browsed
' folder's immediate contents (never a recursive tree - see this
' project's own locked-in scope cut), decorated with git status glyphs.
'
' Split the same way buildrun.bas/gitui.bas already are: pure, headlessly
' testable logic (ListDirectory, ParseGitStatusLine, ComputeGitDecorations
' - none of these ever touch a GTK widget) versus widget-touching code
' (RefreshSidebarListBox, OnSidebarRowActivated) that can only be verified
' by hand, since this sandbox has no usable GTK4 display (confirmed by
' direct reproduction - even a bare GtkLabel segfaults here).

#include once "glibextra.bas"
#include once "buildrun.bas"

' GLib's real directory-listing API (glib/gdir.h, part of glib-2.0,
' already linked) - not bound anywhere yet. `g_dir_read_name` returns a
' *borrowed* name (never freed by the caller, unlike a g_malloc'd string)
' or a real NULL once exhausted - declared ANY PTR (not ZSTRING directly)
' so that NULL-vs-real-value is checked the same explicit way as every
' other GLib borrowed-pointer result in this project (e.g.
' DataInputStreamReadLine's own gotLine convention), rather than relying
' on any implicit null-to-ZSTRING behavior.
Declare Function g_dir_open Lib "glib-2.0" (ByVal path AS ZSTRING, ByVal flags AS INTEGER, ByVal error AS ANY PTR) AS ANY PTR
Declare Function g_dir_read_name Lib "glib-2.0" (ByVal dir AS ANY PTR) AS ANY PTR
Declare Sub g_dir_close Lib "glib-2.0" (ByVal dir AS ANY PTR)

' GFileTest (glib/gfileutils.h) - G_FILE_TEST_EXISTS already lives in
' buildrun.bas; this is the one other flag this file needs.
CONST G_FILE_TEST_IS_DIR = 4

DIM gSidebarFolder AS STRING
DIM gSidebarCount AS INTEGER
DIM gSidebarEntries() AS STRING
DIM gSidebarIsDir() AS INTEGER
DIM gSidebarGlyph() AS STRING

''' Lists `folder`'s immediate contents into gSidebarEntries/gSidebarIsDir
''' (gSidebarCount of them are valid - the arrays may be padded to at
''' least 1 slot even when empty, purely so REDIM always has a
''' non-negative bound to work with). Entry 0 is always ".." unless
''' `folder` is a filesystem root (DirOf(folder) = folder) - pure logic,
''' touches no widget, so a real headless test can call this directly.
SUB ListDirectory(BYVAL folder AS STRING)
    gSidebarFolder = folder
    DIM isRoot AS INTEGER
    isRoot = (DirOf(folder) = folder)

    ' First pass: count real entries (g_dir_read_name never yields "."/
    ' ".." itself - that's GDir's own documented behavior, not something
    ' this file filters).
    DIM count AS INTEGER
    count = 0
    DIM dir1 AS ANY PTR
    dir1 = g_dir_open(folder, 0, 0)
    IF dir1 <> 0 THEN
        DIM rawName1 AS ANY PTR
        rawName1 = g_dir_read_name(dir1)
        DO WHILE rawName1 <> 0
            count = count + 1
            rawName1 = g_dir_read_name(dir1)
        LOOP
        CALL g_dir_close(dir1)
    END IF

    DIM total AS INTEGER
    total = count
    IF isRoot = 0 THEN
        total = total + 1
    END IF
    DIM capacity AS INTEGER
    capacity = total
    IF capacity < 1 THEN
        capacity = 1
    END IF

    REDIM gSidebarEntries(capacity - 1)
    REDIM gSidebarIsDir(capacity - 1)
    REDIM gSidebarGlyph(capacity - 1)
    gSidebarCount = 0

    IF isRoot = 0 THEN
        gSidebarEntries(0) = ".."
        gSidebarIsDir(0) = 1
        gSidebarGlyph(0) = ""
        gSidebarCount = 1
    END IF

    ' Second pass: fill in real entries (g_dir_open again - GDir has no
    ' rewind-and-reuse story simple enough to prefer over just reopening).
    DIM dir2 AS ANY PTR
    dir2 = g_dir_open(folder, 0, 0)
    IF dir2 <> 0 THEN
        DIM rawName2 AS ANY PTR
        rawName2 = g_dir_read_name(dir2)
        DO WHILE rawName2 <> 0
            DIM viaZstring AS ZSTRING
            viaZstring = rawName2
            DIM name AS STRING
            name = viaZstring

            DIM fullPath AS STRING
            fullPath = folder & "/" & name

            gSidebarEntries(gSidebarCount) = name
            gSidebarGlyph(gSidebarCount) = ""
            IF g_file_test(fullPath, G_FILE_TEST_IS_DIR) <> 0 THEN
                gSidebarIsDir(gSidebarCount) = 1
            ELSE
                gSidebarIsDir(gSidebarCount) = 0
            END IF
            gSidebarCount = gSidebarCount + 1

            rawName2 = g_dir_read_name(dir2)
        LOOP
        CALL g_dir_close(dir2)
    END IF
END SUB

''' Splits one `git status --porcelain=v1` line ("XY PATH") into its
''' 2-character status code and the path, via the string standard
''' library (Left/Mid/Len) - returns 0 (leaving `glyph`/`name` untouched)
''' if `line` is too short to be a real porcelain line. Pure logic - no
''' subprocess or widget involved, so a real headless test can feed it
''' literal captured lines directly.
FUNCTION ParseGitStatusLine(BYVAL line AS STRING, BYREF glyph AS STRING, BYREF name AS STRING) AS INTEGER
    IF Len(line) < 4 THEN
        ParseGitStatusLine = 0
        EXIT FUNCTION
    END IF
    glyph = Left(line, 2)
    name = Mid(line, 4, Len(line))
    ParseGitStatusLine = 1
END FUNCTION

''' Runs a fresh, silent `git status --porcelain=v1` in gSidebarFolder
''' (its own blocking subprocess - not gitui.bas's shared visible-output
''' one, so refreshing the sidebar never spams the Source Control panel)
''' and fills gSidebarGlyph for any entry whose name matches a reported
''' path exactly. A path git reports for something *inside* a
''' subdirectory (e.g. "sub/dir/file.bas") never matches any entry in
''' this flat view - silently skipped, a real, documented limitation, not
''' a bug (see this file's own top doc comment). Must run after
''' ListDirectory (reads gSidebarEntries/gSidebarCount, all sized to
''' gSidebarFolder's own current listing). Touches no widget - a real
''' headless test can call this directly against a real throwaway git
''' repo and inspect gSidebarGlyph afterward.
SUB ComputeGitDecorations()
    DIM launcher AS SubprocessLauncher
    launcher = NewSubprocessLauncher(G_SUBPROCESS_FLAGS_STDOUT_PIPE)
    CALL SubprocessLauncherSetCwd(launcher, gSidebarFolder)

    DIM argv(3) AS ZSTRING
    argv(0) = "git"
    argv(1) = "status"
    argv(2) = "--porcelain=v1"
    ' argv(3) stays unassigned - the argv NUL terminator.

    DIM proc AS Subprocess
    proc = SubprocessLauncherSpawnv(launcher, @argv(0))
    IF proc.handle = 0 THEN
        EXIT SUB
    END IF

    DIM outPipe AS InputStream
    outPipe = SubprocessGetStdoutPipe(proc)
    DIM reader AS DataInputStream
    reader = NewDataInputStream(outPipe)

    DIM gotLine AS INTEGER
    DIM rawLine AS ANY PTR
    rawLine = DataInputStreamReadLine(reader, gotLine)
    DO WHILE gotLine <> 0
        DIM viaZstring AS ZSTRING
        viaZstring = rawLine
        DIM line AS STRING
        line = viaZstring
        CALL FreeGMallocString(rawLine)

        DIM glyph AS STRING
        DIM name AS STRING
        IF ParseGitStatusLine(line, glyph, name) <> 0 THEN
            DIM i AS INTEGER
            FOR i = 0 TO gSidebarCount - 1
                IF gSidebarEntries(i) = name THEN
                    gSidebarGlyph(i) = glyph
                END IF
            NEXT i
        END IF

        rawLine = DataInputStreamReadLine(reader, gotLine)
    LOOP

    CALL SubprocessWait(proc)
END SUB

''' Rebuilds the sidebar ListBox's rows from gSidebarEntries/gSidebarIsDir/
''' gSidebarGlyph (all already populated via ListDirectory +
''' ComputeGitDecorations) - a trailing "/" marks a directory row, a
''' leading "[XY] " marks one with a known git status. Widget-touching -
''' manual-verify only.
SUB RefreshSidebarListBox(box AS ListBox)
    CALL ListBoxRemoveAll(box)
    DIM i AS INTEGER
    FOR i = 0 TO gSidebarCount - 1
        DIM rowText AS STRING
        rowText = gSidebarEntries(i)
        IF gSidebarIsDir(i) <> 0 AND rowText <> ".." THEN
            rowText = rowText & "/"
        END IF
        IF gSidebarGlyph(i) <> "" THEN
            rowText = "[" & gSidebarGlyph(i) & "] " & rowText
        END IF

        DIM lbl AS Label
        lbl = NewLabel(rowText)
        CALL ListBoxAppend(box, lbl)
    NEXT i
END SUB

''' The one entry point callers use: lists `folder`, computes its git
''' decoration, and rebuilds `box`'s rows - in that order, since
''' decoration/row-building both read the listing ListDirectory just
''' produced.
SUB RefreshSidebar(box AS ListBox, BYVAL folder AS STRING)
    CALL ListDirectory(folder)
    CALL ComputeGitDecorations()
    CALL RefreshSidebarListBox(box)
END SUB

' The sidebar's own ListBox - stashed so OnSidebarRowActivated (a signal
' handler, so it can't take the box as an ordinary parameter) can call
' RefreshSidebar on it directly for ".."/directory rows.
DIM gSidebarBox AS ListBox

SUB FileBrowserInit(box AS ListBox)
    gSidebarBox = box
END SUB

''' A sidebar row was clicked: ".." goes up one directory, a directory
''' entry descends into it (still flat - a fresh listing replaces the
''' current one, never an expanded tree), a file entry loads it into the
''' editor via `LoadFileIntoEditor` (main.bas) - the same helper the
''' Open dialog itself now calls, so both paths behave identically.
SUB OnSidebarRowActivated(box AS GObj PTR, row AS GObj PTR, data AS ANY PTR)
    DIM r AS ListBoxRow
    r = WrapListBoxRow(row)
    DIM index AS INTEGER
    index = ListBoxRowGetIndex(r)
    IF index < 0 OR index >= gSidebarCount THEN
        EXIT SUB
    END IF

    DIM name AS STRING
    name = gSidebarEntries(index)

    IF name = ".." THEN
        CALL RefreshSidebar(gSidebarBox, DirOf(gSidebarFolder))
        EXIT SUB
    END IF

    IF gSidebarIsDir(index) <> 0 THEN
        CALL RefreshSidebar(gSidebarBox, gSidebarFolder & "/" & name)
        EXIT SUB
    END IF

    CALL LoadFileIntoEditor(gSidebarFolder & "/" & name)
END SUB
