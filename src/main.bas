' ebasic-editor - a code editor for eBasic, written in eBasic, using
' gtk4/eb-cjson as its GUI toolkit and JSON library.
'
' C0-C7: dependency wiring, real eBasic syntax highlighting, file I/O
' (Open/Save via GtkFileChooserNative, Ctrl+S), undo/redo, a modified-
' indicator in the window title, a real ebasic_lsp client (diagnostics
' squiggles, hover, go-to-definition, completion - see src/lsp.bas),
' Build/Run/Test actions spawning `ebpm` (see src/buildrun.bas), Source
' Control actions spawning real `git` (see src/gitui.bas), and now a
' file/project browser sidebar with git-status glyphs (see
' src/filebrowser.bas) - all sharing one streaming output panel.

#include once "gtk4.iface.bas"
#include once "lsp.bas"
#include once "buildrun.bas"
#include once "gitui.bas"
#include once "filebrowser.bas"

' A code editor's own keybindings, not general-purpose GDK constants -
' kept local rather than added to gtk4 (see raw/gtk_eventkey.bas's own
' GDK_KEY_s for the general-purpose ones). Values verified against the
' real installed gdk/gdkkeysyms.h (eBasic has no hex literal syntax, so
' these are written out in decimal: 0xffbe/0xffc9/0x20).
CONST GDK_KEY_F1 = 65470
CONST GDK_KEY_F12 = 65481
CONST GDK_KEY_space = 32

' Module-level globals - eBasic has no closures, so state shared across
' several independent signal handlers (a button click, a key press, a
' dialog's own "response") lives here instead, matching this project's
' own hello_window example precedent (its clickCount global).
DIM gWin AS Window
DIM gBuf AS SourceBuffer
DIM gCurrentPath AS STRING
DIM gHasPath AS INTEGER
DIM gStatusLabel AS Label

''' Sets the window title to the current file's name (or "Untitled"),
''' with a leading "*" while there are unsaved changes.
SUB UpdateTitle()
    DIM name AS STRING
    IF gHasPath = 0 THEN
        name = "Untitled"
    ELSE
        name = gCurrentPath
    END IF

    DIM modified AS INTEGER
    modified = TextBufferGetModified(gBuf)

    IF modified <> 0 THEN
        CALL WindowSetTitle(gWin, "*" & name & " - ebasic-editor")
    ELSE
        CALL WindowSetTitle(gWin, name & " - ebasic-editor")
    END IF
END SUB

SUB OnBufferModifiedChanged(buffer AS GObj PTR, data AS ANY PTR)
    CALL UpdateTitle()
END SUB

''' Reports the buffer's current content to ebasic_lsp on every edit -
''' see lsp.bas's own LspDidChange doc comment on why no debouncing is
''' done here yet.
SUB OnBufferChanged(buffer AS GObj PTR, data AS ANY PTR)
    DIM rawText AS ANY PTR
    rawText = TextBufferGetText(gBuf)
    DIM viaZstring AS ZSTRING
    viaZstring = rawText
    DIM text AS STRING
    text = viaZstring
    CALL FreeGMallocString(rawText)

    CALL LspDidChange(text)
END SUB

''' Tells ebasic_lsp about the file now backing the buffer (after an
''' Open or a first Save As) - "file://" + an absolute path, no percent-
''' encoding (a deliberate v1 scope cut: Linux-only, plain local paths,
''' matching the LSP's own test suite convention of unencoded file://
''' URIs).
SUB EnsureLspDoc()
    IF gHasPath = 0 THEN
        EXIT SUB
    END IF

    DIM rawText AS ANY PTR
    rawText = TextBufferGetText(gBuf)
    DIM viaZstring AS ZSTRING
    viaZstring = rawText
    DIM text AS STRING
    text = viaZstring
    CALL FreeGMallocString(rawText)

    CALL LspDidOpen("file://" & gCurrentPath, text)
END SUB

''' Writes the buffer's current content to `path`, records it as the
''' current file, and clears the modified flag.
SUB SaveToPath(path AS STRING)
    DIM rawText AS ANY PTR
    rawText = TextBufferGetText(gBuf)
    DIM viaZstring AS ZSTRING
    viaZstring = rawText
    DIM text AS STRING
    text = viaZstring
    CALL FreeGMallocString(rawText)

    DIM wasHasPath AS INTEGER
    DIM wasPath AS STRING
    wasHasPath = gHasPath
    wasPath = gCurrentPath

    CALL WriteFileContents(path, text)
    CALL TextBufferSetModified(gBuf, 0)
    gCurrentPath = path
    gHasPath = 1
    CALL UpdateTitle()

    ' Only a brand-new Save As (or the first Save of an untitled buffer)
    ' needs a fresh didOpen - LspDidOpen itself already didClose's any
    ' previously open document first (see lsp.bas), so calling it again
    ' for a plain re-save of the *same* path would needlessly restart the
    ' server's own diagnostics state for no reason. A Save As into a new
    ' folder (or a brand-new file appearing in the current one) always
    ' refreshes the sidebar either way - cheap enough to not bother
    ' checking whether the folder actually changed.
    IF wasHasPath = 0 OR wasPath <> path THEN
        CALL EnsureLspDoc()
        CALL RefreshSidebar(gSidebarBox, DirOf(path))
    END IF
END SUB

SUB OnSaveResponse(dialog AS GObj PTR, responseId AS INTEGER, data AS ANY PTR)
    DIM fc AS FileChooserNative
    fc = WrapFileChooserNative(dialog)

    IF responseId = GTK_RESPONSE_ACCEPT THEN
        DIM rawPath AS ANY PTR
        rawPath = FileChooserGetFilePath(fc)
        IF rawPath <> 0 THEN
            DIM viaZstring AS ZSTRING
            viaZstring = rawPath
            DIM path AS STRING
            path = viaZstring
            CALL FreeGMallocString(rawPath)
            CALL SaveToPath(path)
        END IF
    END IF
    CALL FileChooserNativeDestroy(fc)
END SUB

''' Saves to the current file if one is already known, otherwise shows a
''' Save As dialog first - shared by the Save button and Ctrl+S.
SUB DoSave()
    IF gHasPath <> 0 THEN
        CALL SaveToPath(gCurrentPath)
    ELSE
        DIM fc AS FileChooserNative
        fc = NewFileChooserNative("Save File", gWin, GTK_FILE_CHOOSER_ACTION_SAVE, "_Save", "_Cancel")
        CALL ObjConnect(fc, "response", @OnSaveResponse, 0)
        CALL FileChooserNativeShow(fc)
    END IF
END SUB

SUB OnSaveClicked(btn AS GObj PTR, data AS ANY PTR)
    CALL DoSave()
END SUB

''' Loads `path` into the editor buffer, records it as the current file,
''' and refreshes the sidebar to `path`'s own directory - shared by the
''' Open dialog and a sidebar file-row click (see filebrowser.bas's own
''' OnSidebarRowActivated), so both behave identically. A no-op (silent)
''' if `path` can't be read.
SUB LoadFileIntoEditor(BYVAL path AS STRING)
    DIM ok AS INTEGER
    DIM rawContents AS ANY PTR
    rawContents = ReadFileContents(path, ok)
    IF ok = 0 THEN
        EXIT SUB
    END IF

    DIM viaZstring AS ZSTRING
    viaZstring = rawContents
    DIM contents AS STRING
    contents = viaZstring
    CALL FreeGMallocString(rawContents)

    CALL TextBufferSetText(gBuf, contents)
    CALL TextBufferSetModified(gBuf, 0)
    gCurrentPath = path
    gHasPath = 1
    CALL UpdateTitle()
    CALL EnsureLspDoc()
    CALL RefreshSidebar(gSidebarBox, DirOf(path))
END SUB

SUB OnOpenResponse(dialog AS GObj PTR, responseId AS INTEGER, data AS ANY PTR)
    DIM fc AS FileChooserNative
    fc = WrapFileChooserNative(dialog)

    IF responseId = GTK_RESPONSE_ACCEPT THEN
        DIM rawPath AS ANY PTR
        rawPath = FileChooserGetFilePath(fc)
        IF rawPath <> 0 THEN
            DIM viaZstring AS ZSTRING
            viaZstring = rawPath
            DIM path AS STRING
            path = viaZstring
            CALL FreeGMallocString(rawPath)
            CALL LoadFileIntoEditor(path)
        END IF
    END IF
    CALL FileChooserNativeDestroy(fc)
END SUB

SUB OnOpenClicked(btn AS GObj PTR, data AS ANY PTR)
    DIM fc AS FileChooserNative
    fc = NewFileChooserNative("Open File", gWin, GTK_FILE_CHOOSER_ACTION_OPEN, "_Open", "_Cancel")
    CALL ObjConnect(fc, "response", @OnOpenResponse, 0)
    CALL FileChooserNativeShow(fc)
END SUB

SUB OnOpenFolderResponse(dialog AS GObj PTR, responseId AS INTEGER, data AS ANY PTR)
    DIM fc AS FileChooserNative
    fc = WrapFileChooserNative(dialog)

    IF responseId = GTK_RESPONSE_ACCEPT THEN
        DIM rawPath AS ANY PTR
        rawPath = FileChooserGetFilePath(fc)
        IF rawPath <> 0 THEN
            DIM viaZstring AS ZSTRING
            viaZstring = rawPath
            DIM path AS STRING
            path = viaZstring
            CALL FreeGMallocString(rawPath)
            CALL RefreshSidebar(gSidebarBox, path)
        END IF
    END IF
    CALL FileChooserNativeDestroy(fc)
END SUB

''' Browses to a folder without necessarily opening any file in it - the
''' Open dialog/sidebar file clicks already establish sidebar context
''' from whatever file you open; this is for starting from an empty or
''' otherwise unopened folder instead.
SUB OnOpenFolderClicked(btn AS GObj PTR, data AS ANY PTR)
    DIM fc AS FileChooserNative
    fc = NewFileChooserNative("Open Folder", gWin, GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER, "_Open", "_Cancel")
    CALL ObjConnect(fc, "response", @OnOpenFolderResponse, 0)
    CALL FileChooserNativeShow(fc)
END SUB

SUB OnUndoClicked(btn AS GObj PTR, data AS ANY PTR)
    CALL TextBufferUndo(gBuf)
END SUB

SUB OnRedoClicked(btn AS GObj PTR, data AS ANY PTR)
    CALL TextBufferRedo(gBuf)
END SUB

SUB OnBuildClicked(btn AS GObj PTR, data AS ANY PTR)
    CALL RunEbpmCommand("build", gHasPath, gCurrentPath)
END SUB

SUB OnRunClicked(btn AS GObj PTR, data AS ANY PTR)
    CALL RunEbpmCommand("run", gHasPath, gCurrentPath)
END SUB

SUB OnTestClicked(btn AS GObj PTR, data AS ANY PTR)
    CALL RunEbpmCommand("test", gHasPath, gCurrentPath)
END SUB

SUB OnGitStatusClicked(btn AS GObj PTR, data AS ANY PTR)
    CALL RunGitStatus(gHasPath, gCurrentPath)
END SUB

SUB OnGitDiffClicked(btn AS GObj PTR, data AS ANY PTR)
    CALL RunGitDiff(gHasPath, gCurrentPath)
END SUB

SUB OnGitStageClicked(btn AS GObj PTR, data AS ANY PTR)
    CALL RunGitStage(gHasPath, gCurrentPath)
END SUB

SUB OnGitUnstageClicked(btn AS GObj PTR, data AS ANY PTR)
    CALL RunGitUnstage(gHasPath, gCurrentPath)
END SUB

SUB OnGitCommitClicked(btn AS GObj PTR, data AS ANY PTR)
    CALL ShowCommitDialog(gHasPath, gCurrentPath)
END SUB

SUB OnGitPushClicked(btn AS GObj PTR, data AS ANY PTR)
    CALL RunGitPush(gHasPath, gCurrentPath)
END SUB

SUB OnGitPullClicked(btn AS GObj PTR, data AS ANY PTR)
    CALL RunGitPull(gHasPath, gCurrentPath)
END SUB

''' Ctrl+S saves; F1 shows hover info; F12 jumps to a definition; Ctrl+Space
''' requests completion (all shown/acted on via lsp.bas - see its own
''' LspRequestHover/Definition/Completion doc comments). Every other key
''' is left to GtkSourceView's own default handling (including its
''' built-in Ctrl+Z/Ctrl+Shift+Z undo/redo, which needs no wiring here).
FUNCTION OnKeyPressed(controller AS GObj PTR, keyval AS INTEGER, keycode AS INTEGER, state AS INTEGER, data AS ANY PTR) AS INTEGER
    DIM ctrlHeld AS INTEGER
    ctrlHeld = ((state AND GDK_CONTROL_MASK) <> 0)

    IF keyval = GDK_KEY_s AND ctrlHeld THEN
        CALL DoSave()
        OnKeyPressed = 1
    ELSEIF keyval = GDK_KEY_F1 THEN
        CALL LspRequestHover(TextBufferGetCursorLine(gBuf), TextBufferGetCursorColumn(gBuf))
        OnKeyPressed = 1
    ELSEIF keyval = GDK_KEY_F12 THEN
        CALL LspRequestDefinition(TextBufferGetCursorLine(gBuf), TextBufferGetCursorColumn(gBuf))
        OnKeyPressed = 1
    ELSEIF keyval = GDK_KEY_space AND ctrlHeld THEN
        CALL LspRequestCompletion(TextBufferGetCursorLine(gBuf), TextBufferGetCursorColumn(gBuf))
        OnKeyPressed = 1
    ELSE
        OnKeyPressed = 0
    END IF
END FUNCTION

SUB OnActivate(rawApp AS GObj PTR, data AS ANY PTR)
    DIM app AS Application
    app = WrapApplication(rawApp)

    gWin = NewApplicationWindow(app)
    CALL WindowSetDefaultSize(gWin, 800, 600)

    DIM langMgr AS SourceLanguageManager
    langMgr = SourceLanguageManagerGetDefault()
    CALL SourceLanguageManagerAppendSearchPath(langMgr, "data/language-specs")
    DIM lang AS SourceLanguage
    lang = SourceLanguageManagerGetLanguage(langMgr, "ebasic")

    gBuf = NewSourceBufferWithLanguage(lang)
    CALL SourceBufferSetHighlightSyntax(gBuf, 1)
    CALL TextBufferSetText(gBuf, "PRINT ""Hello from ebasic-editor!""")
    CALL TextBufferSetModified(gBuf, 0)
    CALL ObjConnect(gBuf, "modified-changed", @OnBufferModifiedChanged, 0)
    CALL ObjConnect(gBuf, "changed", @OnBufferChanged, 0)

    DIM view AS SourceView
    view = NewSourceViewWithBuffer(gBuf)
    CALL TextViewSetMonospace(view, 1)
    CALL TextViewSetWrapMode(view, GTK_WRAP_NONE)
    CALL SourceViewSetShowLineNumbers(view, 1)
    CALL SourceViewSetHighlightCurrentLine(view, 1)

    DIM keyCtrl AS EventControllerKey
    keyCtrl = NewEventControllerKey()
    CALL ObjConnect(keyCtrl, "key-pressed", @OnKeyPressed, 0)
    CALL WidgetAddController(view, keyCtrl)

    DIM scroller AS ScrolledWindow
    scroller = NewScrolledWindow()
    CALL ScrolledWindowSetChild(scroller, view)

    ' A read-only output panel, shared by Build/Run/Test's streamed ebpm
    ' output (see buildrun.bas) and Source Control's streamed git output
    ' (see gitui.bas) - a plain GtkTextView, not a SourceView (no syntax
    ' highlighting needed for tool output).
    DIM outputBuf AS TextBuffer
    outputBuf = NewTextBuffer()
    DIM outputView AS TextView
    outputView = NewTextView()
    CALL TextViewSetBuffer(outputView, outputBuf)
    CALL TextViewSetEditable(outputView, 0)
    CALL TextViewSetMonospace(outputView, 1)
    DIM outputScroller AS ScrolledWindow
    outputScroller = NewScrolledWindow()
    CALL ScrolledWindowSetChild(outputScroller, outputView)
    CALL WidgetSetSizeRequest(outputScroller, -1, 150)

    DIM editorSplit AS Paned
    editorSplit = NewPaned(GTK_ORIENTATION_VERTICAL)
    CALL PanedSetStartChild(editorSplit, scroller)
    CALL PanedSetEndChild(editorSplit, outputScroller)
    CALL PanedSetPosition(editorSplit, 400)

    ' A status bar for LSP results (hover text, diagnostic counts,
    ' completion candidates - see lsp.bas's own LspSetStatus) - a plain
    ' Label rather than a popup/popover this sandbox has no way to
    ' visually verify (see lsp.bas's own doc comments on that scope cut).
    gStatusLabel = NewLabel("")
    CALL WidgetSetSizeRequest(gStatusLabel, -1, 24)

    ' A Source Control toolbar (see gitui.bas) - a second row rather than
    ' more HeaderBar buttons (already at 7 with Open/Save/Undo/Redo/
    ' Build/Run/Test), since gtk4 has no menu/popover bindings yet to
    ' consolidate them.
    DIM gitBar AS Box
    gitBar = NewBox(GTK_ORIENTATION_HORIZONTAL, 4)

    DIM gitStatusBtn AS Button
    gitStatusBtn = NewButton("Git Status")
    CALL ObjConnect(gitStatusBtn, "clicked", @OnGitStatusClicked, 0)
    CALL BoxAppend(gitBar, gitStatusBtn)

    DIM gitDiffBtn AS Button
    gitDiffBtn = NewButton("Diff")
    CALL ObjConnect(gitDiffBtn, "clicked", @OnGitDiffClicked, 0)
    CALL BoxAppend(gitBar, gitDiffBtn)

    DIM gitStageBtn AS Button
    gitStageBtn = NewButton("Stage")
    CALL ObjConnect(gitStageBtn, "clicked", @OnGitStageClicked, 0)
    CALL BoxAppend(gitBar, gitStageBtn)

    DIM gitUnstageBtn AS Button
    gitUnstageBtn = NewButton("Unstage")
    CALL ObjConnect(gitUnstageBtn, "clicked", @OnGitUnstageClicked, 0)
    CALL BoxAppend(gitBar, gitUnstageBtn)

    DIM gitCommitBtn AS Button
    gitCommitBtn = NewButton("Commit...")
    CALL ObjConnect(gitCommitBtn, "clicked", @OnGitCommitClicked, 0)
    CALL BoxAppend(gitBar, gitCommitBtn)

    DIM gitPushBtn AS Button
    gitPushBtn = NewButton("Push")
    CALL ObjConnect(gitPushBtn, "clicked", @OnGitPushClicked, 0)
    CALL BoxAppend(gitBar, gitPushBtn)

    DIM gitPullBtn AS Button
    gitPullBtn = NewButton("Pull")
    CALL ObjConnect(gitPullBtn, "clicked", @OnGitPullClicked, 0)
    CALL BoxAppend(gitBar, gitPullBtn)

    DIM rootBox AS Box
    rootBox = NewBox(GTK_ORIENTATION_VERTICAL, 0)
    CALL BoxAppend(rootBox, gitBar)
    CALL BoxAppend(rootBox, editorSplit)
    CALL BoxAppend(rootBox, gStatusLabel)

    ' The file/project browser sidebar (see filebrowser.bas) - a flat
    ' list of the currently browsed folder's immediate contents, git-
    ' status-decorated. Row-activated (a click) loads a file, descends
    ' into a directory, or goes up via "..".
    DIM sidebarBox AS ListBox
    sidebarBox = NewListBox()
    CALL ListBoxSetActivateOnSingleClick(sidebarBox, 1)
    CALL ObjConnect(sidebarBox, "row-activated", @OnSidebarRowActivated, 0)
    DIM sidebarScroller AS ScrolledWindow
    sidebarScroller = NewScrolledWindow()
    CALL ScrolledWindowSetChild(sidebarScroller, sidebarBox)
    CALL WidgetSetSizeRequest(sidebarScroller, 200, -1)

    DIM mainSplit AS Paned
    mainSplit = NewPaned(GTK_ORIENTATION_HORIZONTAL)
    CALL PanedSetStartChild(mainSplit, sidebarScroller)
    CALL PanedSetEndChild(mainSplit, rootBox)
    CALL PanedSetPosition(mainSplit, 200)

    CALL BuildRunInit(outputBuf)
    CALL GitUiInit(outputBuf)
    CALL FileBrowserInit(sidebarBox)
    CALL RefreshSidebar(sidebarBox, ".")

    DIM bar AS HeaderBar
    bar = NewHeaderBar()
    CALL HeaderBarSetShowTitleButtons(bar, 1)

    DIM openFolderBtn AS Button
    openFolderBtn = NewButton("Open Folder")
    CALL ObjConnect(openFolderBtn, "clicked", @OnOpenFolderClicked, 0)
    CALL HeaderBarPackStart(bar, openFolderBtn)

    DIM openBtn AS Button
    openBtn = NewButton("Open")
    CALL ObjConnect(openBtn, "clicked", @OnOpenClicked, 0)
    CALL HeaderBarPackStart(bar, openBtn)

    DIM saveBtn AS Button
    saveBtn = NewButton("Save")
    CALL ObjConnect(saveBtn, "clicked", @OnSaveClicked, 0)
    CALL HeaderBarPackStart(bar, saveBtn)

    DIM undoBtn AS Button
    undoBtn = NewButton("Undo")
    CALL ObjConnect(undoBtn, "clicked", @OnUndoClicked, 0)
    CALL HeaderBarPackStart(bar, undoBtn)

    DIM redoBtn AS Button
    redoBtn = NewButton("Redo")
    CALL ObjConnect(redoBtn, "clicked", @OnRedoClicked, 0)
    CALL HeaderBarPackStart(bar, redoBtn)

    DIM buildBtn AS Button
    buildBtn = NewButton("Build")
    CALL ObjConnect(buildBtn, "clicked", @OnBuildClicked, 0)
    CALL HeaderBarPackEnd(bar, buildBtn)

    DIM runBtn AS Button
    runBtn = NewButton("Run")
    CALL ObjConnect(runBtn, "clicked", @OnRunClicked, 0)
    CALL HeaderBarPackEnd(bar, runBtn)

    DIM testBtn AS Button
    testBtn = NewButton("Test")
    CALL ObjConnect(testBtn, "clicked", @OnTestClicked, 0)
    CALL HeaderBarPackEnd(bar, testBtn)

    CALL WindowSetTitlebar(gWin, bar)
    CALL WindowSetChild(gWin, mainSplit)

    gHasPath = 0
    CALL UpdateTitle()

    CALL LspInit(gBuf, gStatusLabel)
    IF LspStart("ebasic_lsp") = 0 THEN
        CALL LspSetStatus("ebasic_lsp not found on PATH - diagnostics/hover/go-to-definition/completion disabled")
    ELSEIF LspInitialize() = 0 THEN
        CALL LspSetStatus("ebasic_lsp failed to initialize")
    ELSE
        CALL LspSetStatus("ebasic_lsp ready")
    END IF

    CALL WindowPresent(gWin)
END SUB

DIM app AS Application
app = NewApplication("io.github.yann64.ebasiceditor")
CALL ObjConnect(app, "activate", @OnActivate, 0)
CALL ApplicationRun(app)
CALL LspStop()
CALL ObjDestroy(app)
