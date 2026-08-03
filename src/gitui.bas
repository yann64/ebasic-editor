' Source Control integration: status/diff/stage/unstage/commit/push/pull
' via the real `git` CLI (never `libgit2` - matching `ebpm`'s own
' established "shell out to the real tool" precedent), spawned the same
' way buildrun.bas spawns `ebpm` - the plan's own locked-in git scope
' (status + diff + stage/commit + push/pull; no branch management, no
' merge UI, no commit-log/history view).
'
' `git` needs no package-root discovery the way `ebpm` does - any
' subcommand run from *any* directory inside a repo works (git itself
' walks up looking for `.git`), so the currently open file's own
' directory is always a valid `cwd` (see buildrun.bas's own DirOf).

#include once "glibextra.bas"
#include once "buildrun.bas"
#include once "filebrowser.bas"

DIM gGitProc AS Subprocess
DIM gGitOutPipe AS DataInputStream
DIM gGitOutputBuf AS TextBuffer
DIM gGitRunning AS INTEGER

DIM gCommitWin AS Window
DIM gCommitEntry AS Entry
DIM gCommitHasPath AS INTEGER
DIM gCommitPath AS STRING

''' Stashes the Source Control output panel's own buffer - call once, at
''' startup.
SUB GitUiInit(outputBuf AS TextBuffer)
    gGitOutputBuf = outputBuf
    gGitRunning = 0
END SUB

SUB AppendGitOutput(BYVAL line AS STRING)
    CALL TextBufferAppendLine(gGitOutputBuf, line)
END SUB

SUB OnGitExit(source AS GObj PTR, res AS ANY PTR, data AS ANY PTR)
    CALL SubprocessWaitFinish(gGitProc, res)
    IF SubprocessGetSuccessful(gGitProc) <> 0 THEN
        CALL AppendGitOutput("(finished successfully)")
    ELSE
        CALL AppendGitOutput("(exited with a non-zero status)")
    END IF
    gGitRunning = 0

    ' Stage/Unstage/Commit (and anything else run here) can change git's
    ' own status output - refresh the sidebar's glyphs so they don't go
    ' stale (see filebrowser.bas). Guarded on the sidebar actually having
    ' been set up (FileBrowserInit called, a real widget behind
    ' gSidebarBox) - this file's own headless test never does, and this
    ' sandbox has no display to construct a real ListBox row on anyway.
    IF gSidebarBox.handle <> 0 THEN
        CALL ComputeGitDecorations()
        CALL RefreshSidebarListBox(gSidebarBox)
    END IF
END SUB

SUB OnGitLine(source AS GObj PTR, res AS ANY PTR, data AS ANY PTR)
    DIM gotLine AS INTEGER
    DIM rawLine AS ANY PTR
    rawLine = DataInputStreamReadLineFinish(gGitOutPipe, res, gotLine)
    IF gotLine = 0 THEN
        CALL SubprocessWaitAsync(gGitProc, @OnGitExit, 0)
        EXIT SUB
    END IF

    DIM viaZstring AS ZSTRING
    viaZstring = rawLine
    DIM line AS STRING
    line = viaZstring
    CALL FreeGMallocString(rawLine)
    CALL AppendGitOutput(line)

    CALL DataInputStreamReadLineAsync(gGitOutPipe, @OnGitLine, 0)
END SUB

''' Spawns `git` with the given argv (built by each RunGit* caller, see
''' SubprocessLauncherSpawnv's own doc comment on the argv convention)
''' with its cwd set to `cwd`, and starts streaming its output.
SUB StartGitSpawn(argvFirst AS ANY PTR, BYVAL cwd AS STRING)
    IF gGitRunning <> 0 THEN
        CALL AppendGitOutput("(a git command is already running)")
        EXIT SUB
    END IF

    DIM launcher AS SubprocessLauncher
    launcher = NewSubprocessLauncher(G_SUBPROCESS_FLAGS_STDOUT_PIPE OR G_SUBPROCESS_FLAGS_STDERR_MERGE)
    CALL SubprocessLauncherSetCwd(launcher, cwd)

    gGitProc = SubprocessLauncherSpawnv(launcher, argvFirst)
    IF gGitProc.handle = 0 THEN
        CALL AppendGitOutput("(failed to spawn git - is it on PATH?)")
        EXIT SUB
    END IF

    gGitRunning = 1
    DIM outPipe AS InputStream
    outPipe = SubprocessGetStdoutPipe(gGitProc)
    gGitOutPipe = NewDataInputStream(outPipe)
    CALL DataInputStreamReadLineAsync(gGitOutPipe, @OnGitLine, 0)
END SUB

''' Prints an explanatory line and returns 1 if no file is open yet (a
''' real no-op for every RunGit* entry point below) - 0 otherwise.
FUNCTION NoFileOpenGuard(hasPath AS INTEGER) AS INTEGER
    IF hasPath = 0 THEN
        CALL TextBufferSetText(gGitOutputBuf, "(open a file inside a git repo first)")
        NoFileOpenGuard = 1
    ELSE
        NoFileOpenGuard = 0
    END IF
END FUNCTION

SUB RunGitStatus(hasPath AS INTEGER, BYVAL currentPath AS STRING)
    IF NoFileOpenGuard(hasPath) <> 0 THEN
        EXIT SUB
    END IF

    DIM cwd AS STRING
    cwd = DirOf(currentPath)
    CALL TextBufferSetText(gGitOutputBuf, "$ git status (in " & cwd & ")")

    DIM argv(2) AS ZSTRING
    argv(0) = "git"
    argv(1) = "status"
    CALL StartGitSpawn(@argv(0), cwd)
END SUB

SUB RunGitDiff(hasPath AS INTEGER, BYVAL currentPath AS STRING)
    IF NoFileOpenGuard(hasPath) <> 0 THEN
        EXIT SUB
    END IF

    DIM cwd AS STRING
    cwd = DirOf(currentPath)
    CALL TextBufferSetText(gGitOutputBuf, "$ git diff -- " & currentPath)

    DIM argv(4) AS ZSTRING
    argv(0) = "git"
    argv(1) = "diff"
    argv(2) = "--"
    argv(3) = currentPath
    CALL StartGitSpawn(@argv(0), cwd)
END SUB

SUB RunGitStage(hasPath AS INTEGER, BYVAL currentPath AS STRING)
    IF NoFileOpenGuard(hasPath) <> 0 THEN
        EXIT SUB
    END IF

    DIM cwd AS STRING
    cwd = DirOf(currentPath)
    CALL TextBufferSetText(gGitOutputBuf, "$ git add -- " & currentPath)

    DIM argv(4) AS ZSTRING
    argv(0) = "git"
    argv(1) = "add"
    argv(2) = "--"
    argv(3) = currentPath
    CALL StartGitSpawn(@argv(0), cwd)
END SUB

SUB RunGitUnstage(hasPath AS INTEGER, BYVAL currentPath AS STRING)
    IF NoFileOpenGuard(hasPath) <> 0 THEN
        EXIT SUB
    END IF

    DIM cwd AS STRING
    cwd = DirOf(currentPath)
    CALL TextBufferSetText(gGitOutputBuf, "$ git restore --staged -- " & currentPath)

    DIM argv(5) AS ZSTRING
    argv(0) = "git"
    argv(1) = "restore"
    argv(2) = "--staged"
    argv(3) = "--"
    argv(4) = currentPath
    CALL StartGitSpawn(@argv(0), cwd)
END SUB

SUB RunGitPush(hasPath AS INTEGER, BYVAL currentPath AS STRING)
    IF NoFileOpenGuard(hasPath) <> 0 THEN
        EXIT SUB
    END IF

    DIM cwd AS STRING
    cwd = DirOf(currentPath)
    CALL TextBufferSetText(gGitOutputBuf, "$ git push (in " & cwd & ")")

    DIM argv(2) AS ZSTRING
    argv(0) = "git"
    argv(1) = "push"
    CALL StartGitSpawn(@argv(0), cwd)
END SUB

SUB RunGitPull(hasPath AS INTEGER, BYVAL currentPath AS STRING)
    IF NoFileOpenGuard(hasPath) <> 0 THEN
        EXIT SUB
    END IF

    DIM cwd AS STRING
    cwd = DirOf(currentPath)
    CALL TextBufferSetText(gGitOutputBuf, "$ git pull (in " & cwd & ")")

    DIM argv(2) AS ZSTRING
    argv(0) = "git"
    argv(1) = "pull"
    CALL StartGitSpawn(@argv(0), cwd)
END SUB

''' Commits with `message` - the currently open file's own directory is
''' used as `cwd` (see this file's own top doc comment); this project's
''' own scope (see the main eBasic repo's roadmap) never stages/commits
''' anything beyond what the user explicitly chose via RunGitStage, so
''' this is a plain `git commit -m`, not `-a`.
SUB RunGitCommit(hasPath AS INTEGER, BYVAL currentPath AS STRING, BYVAL message AS STRING)
    IF NoFileOpenGuard(hasPath) <> 0 THEN
        EXIT SUB
    END IF

    DIM cwd AS STRING
    cwd = DirOf(currentPath)
    DIM quote AS STRING
    quote = Chr34()
    CALL TextBufferSetText(gGitOutputBuf, "$ git commit -m " & quote & message & quote)

    DIM argv(4) AS ZSTRING
    argv(0) = "git"
    argv(1) = "commit"
    argv(2) = "-m"
    argv(3) = message
    CALL StartGitSpawn(@argv(0), cwd)
END SUB

''' A double-quote as a ZSTRING - see src/lsp.bas's own IntToDecimalZstring
''' doc comment on why eBasic's own STRING literals can't express one
''' via escaping (no CHR$ equivalent, and `""` inside a literal is
''' already how eBasic itself escapes a literal quote, not useful here).
FUNCTION Chr34() AS ZSTRING
    DIM buf AS ANY PTR
    buf = g_malloc(2)
    DIM bp AS BYTE PTR
    bp = buf
    *bp = 34
    *(bp + 1) = 0
    Chr34 = buf
END FUNCTION

SUB OnCommitConfirm(btn AS GObj PTR, data AS ANY PTR)
    DIM message AS STRING
    message = EntryGetText(gCommitEntry)
    CALL WidgetSetVisible(gCommitWin, 0)
    CALL RunGitCommit(gCommitHasPath, gCommitPath, message)
END SUB

SUB OnCommitCancel(btn AS GObj PTR, data AS ANY PTR)
    CALL WidgetSetVisible(gCommitWin, 0)
END SUB

''' Shows a small commit-message dialog; confirming spawns RunGitCommit.
''' A plain child Window with an Entry, not a full GtkDialog (this
''' project has no dialog-button-response-signal bindings yet, and a
''' single-purpose window + two buttons covers this one need directly).
SUB ShowCommitDialog(hasPath AS INTEGER, BYVAL currentPath AS STRING)
    IF NoFileOpenGuard(hasPath) <> 0 THEN
        EXIT SUB
    END IF

    gCommitHasPath = hasPath
    gCommitPath = currentPath

    gCommitWin = NewWindow()
    CALL WindowSetTitle(gCommitWin, "Commit message")
    CALL WindowSetDefaultSize(gCommitWin, 400, 120)

    gCommitEntry = NewEntry()
    CALL EntrySetText(gCommitEntry, "")

    DIM confirmBtn AS Button
    confirmBtn = NewButton("Commit")
    CALL ObjConnect(confirmBtn, "clicked", @OnCommitConfirm, 0)

    DIM cancelBtn AS Button
    cancelBtn = NewButton("Cancel")
    CALL ObjConnect(cancelBtn, "clicked", @OnCommitCancel, 0)

    DIM btnRow AS Box
    btnRow = NewBox(GTK_ORIENTATION_HORIZONTAL, 6)
    CALL BoxAppend(btnRow, confirmBtn)
    CALL BoxAppend(btnRow, cancelBtn)

    DIM col AS Box
    col = NewBox(GTK_ORIENTATION_VERTICAL, 6)
    CALL BoxAppend(col, gCommitEntry)
    CALL BoxAppend(col, btnRow)

    CALL WindowSetChild(gCommitWin, col)
    CALL WindowPresent(gCommitWin)
END SUB
