' ebpm integration: Build/Run/Test actions, spawned via gtk4's
' GSubprocess bindings (the same portable, async-capable primitive
' src/lsp.bas uses for ebasic_lsp) - streams the child's combined stdout/
' stderr into a read-only output panel line by line as it arrives (async,
' so a slow build never freezes the GTK main loop), then reports the
' exit status once the process finishes.

#include once "glibextra.bas"

' Returns a newly `g_malloc`'d string (the path's directory component) -
' the caller frees it via g_free (see glibextra.bas), same as any other
' g_malloc'd string in this project.
Declare Function g_path_get_dirname Lib "glib-2.0" (ByVal file_name AS ZSTRING) AS ANY PTR
Declare Function g_file_test Lib "glib-2.0" (ByVal filename AS ZSTRING, ByVal test AS INTEGER) AS INTEGER

' GFileTest (glib/gfileutils.h) - only EXISTS is needed here.
CONST G_FILE_TEST_EXISTS = 16

DIM gBuildProc AS Subprocess
DIM gBuildOutPipe AS DataInputStream
DIM gBuildOutputBuf AS TextBuffer
DIM gBuildRunning AS INTEGER

''' Stashes the output panel's own buffer - call once, at startup.
SUB BuildRunInit(outputBuf AS TextBuffer)
    gBuildOutputBuf = outputBuf
    gBuildRunning = 0
END SUB

''' Appends a line to the output panel - gtk4's own TextBufferAppendLine
''' (v0.5.0+), added specifically for this: rewriting the whole buffer's
''' text via TextBufferSetText on every line would be wasteful.
SUB AppendBuildOutput(BYVAL line AS STRING)
    CALL TextBufferAppendLine(gBuildOutputBuf, line)
END SUB

''' Walks up from `startDir` looking for a directory containing
''' `ebasic.toml` (the same convention `ebpm`/`ebasic_lsp` themselves use
''' to find "the package rooted here") - "" if none is found within a
''' generous 64-directory search (a real filesystem root is reached long
''' before that; the cap just guards against an unexpected infinite loop).
FUNCTION FindPackageRoot(BYVAL startDir AS STRING) AS STRING
    DIM current AS STRING
    current = startDir

    DIM depth AS INTEGER
    depth = 0
    DO WHILE depth < 64
        DIM tomlPath AS STRING
        tomlPath = current & "/ebasic.toml"
        IF g_file_test(tomlPath, G_FILE_TEST_EXISTS) <> 0 THEN
            FindPackageRoot = current
            EXIT FUNCTION
        END IF

        DIM rawParent AS ANY PTR
        rawParent = g_path_get_dirname(current)
        DIM parentZ AS ZSTRING
        parentZ = rawParent
        DIM parent AS STRING
        parent = parentZ
        CALL g_free(rawParent)

        IF parent = current THEN
            EXIT DO
        END IF
        current = parent
        depth = depth + 1
    LOOP

    FindPackageRoot = ""
END FUNCTION

''' The directory portion of a file path (`g_path_get_dirname`, see
''' FindPackageRoot's own doc comment on why this needs no eBasic-level
''' string parsing at all).
FUNCTION DirOf(BYVAL path AS STRING) AS STRING
    DIM rawDir AS ANY PTR
    rawDir = g_path_get_dirname(path)
    DIM viaZstring AS ZSTRING
    viaZstring = rawDir
    DIM result AS STRING
    result = viaZstring
    CALL g_free(rawDir)
    DirOf = result
END FUNCTION

SUB OnBuildExit(source AS GObj PTR, res AS ANY PTR, data AS ANY PTR)
    CALL SubprocessWaitFinish(gBuildProc, res)
    DIM successful AS INTEGER
    successful = SubprocessGetSuccessful(gBuildProc)
    IF successful <> 0 THEN
        CALL AppendBuildOutput("(finished successfully)")
    ELSE
        CALL AppendBuildOutput("(exited with a non-zero status)")
    END IF
    gBuildRunning = 0
END SUB

SUB OnBuildLine(source AS GObj PTR, res AS ANY PTR, data AS ANY PTR)
    DIM gotLine AS INTEGER
    DIM rawLine AS ANY PTR
    rawLine = DataInputStreamReadLineFinish(gBuildOutPipe, res, gotLine)
    IF gotLine = 0 THEN
        CALL SubprocessWaitAsync(gBuildProc, @OnBuildExit, 0)
        EXIT SUB
    END IF

    DIM viaZstring AS ZSTRING
    viaZstring = rawLine
    DIM line AS STRING
    line = viaZstring
    CALL FreeGMallocString(rawLine)
    CALL AppendBuildOutput(line)

    CALL DataInputStreamReadLineAsync(gBuildOutPipe, @OnBuildLine, 0)
END SUB

''' Runs `ebpm <subcommand>` (build/run/test) with its cwd set to the
''' package root found by walking up from the currently open file's own
''' directory - a no-op (with an explanatory output-panel line) if no
''' file is open yet, or no `ebasic.toml` is found above it.
SUB RunEbpmCommand(BYVAL subcommand AS STRING, hasPath AS INTEGER, BYVAL currentPath AS STRING)
    IF gBuildRunning <> 0 THEN
        CALL AppendBuildOutput("(a command is already running)")
        EXIT SUB
    END IF

    IF hasPath = 0 THEN
        CALL TextBufferSetText(gBuildOutputBuf, "(open a file inside an ebpm package first)")
        EXIT SUB
    END IF

    DIM root AS STRING
    root = FindPackageRoot(DirOf(currentPath))
    IF root = "" THEN
        CALL TextBufferSetText(gBuildOutputBuf, "(no ebasic.toml found above the current file)")
        EXIT SUB
    END IF

    CALL TextBufferSetText(gBuildOutputBuf, "$ ebpm " & subcommand & " (in " & root & ")")

    DIM launcher AS SubprocessLauncher
    launcher = NewSubprocessLauncher(G_SUBPROCESS_FLAGS_STDOUT_PIPE OR G_SUBPROCESS_FLAGS_STDERR_MERGE)
    CALL SubprocessLauncherSetCwd(launcher, root)

    DIM argv(2) AS ZSTRING
    argv(0) = "ebpm"
    argv(1) = subcommand
    ' argv(2) stays unassigned - the argv NUL terminator.

    gBuildProc = SubprocessLauncherSpawnv(launcher, @argv(0))
    IF gBuildProc.handle = 0 THEN
        CALL AppendBuildOutput("(failed to spawn ebpm - is it on PATH?)")
        EXIT SUB
    END IF

    gBuildRunning = 1
    DIM outPipe AS InputStream
    outPipe = SubprocessGetStdoutPipe(gBuildProc)
    gBuildOutPipe = NewDataInputStream(outPipe)
    CALL DataInputStreamReadLineAsync(gBuildOutPipe, @OnBuildLine, 0)
END SUB
