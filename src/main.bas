' ebasic-editor - a code editor for eBasic, written in eBasic, using
' gtk4/eb-cjson as its GUI toolkit and JSON library.
'
' C0/C1/C2: dependency wiring, real eBasic syntax highlighting, and now
' file I/O (Open/Save via GtkFileChooserNative, Ctrl+S), undo/redo, and a
' modified-indicator in the window title. No LSP/ebpm/git integration
' yet (all follow in later slices).

#include "gtk4.iface.bas"

' Module-level globals - eBasic has no closures, so state shared across
' several independent signal handlers (a button click, a key press, a
' dialog's own "response") lives here instead, matching this project's
' own hello_window example precedent (its clickCount global).
DIM gWin AS Window
DIM gBuf AS SourceBuffer
DIM gCurrentPath AS STRING
DIM gHasPath AS INTEGER

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

    CALL WriteFileContents(path, text)
    CALL TextBufferSetModified(gBuf, 0)
    gCurrentPath = path
    gHasPath = 1
    CALL UpdateTitle()
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

            DIM ok AS INTEGER
            DIM rawContents AS ANY PTR
            rawContents = ReadFileContents(path, ok)
            IF ok <> 0 THEN
                DIM viaZstring2 AS ZSTRING
                viaZstring2 = rawContents
                DIM contents AS STRING
                contents = viaZstring2
                CALL FreeGMallocString(rawContents)

                CALL TextBufferSetText(gBuf, contents)
                CALL TextBufferSetModified(gBuf, 0)
                gCurrentPath = path
                gHasPath = 1
                CALL UpdateTitle()
            END IF
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

SUB OnUndoClicked(btn AS GObj PTR, data AS ANY PTR)
    CALL TextBufferUndo(gBuf)
END SUB

SUB OnRedoClicked(btn AS GObj PTR, data AS ANY PTR)
    CALL TextBufferRedo(gBuf)
END SUB

''' Ctrl+S saves - every other key is left to GtkSourceView's own default
''' handling (including its built-in Ctrl+Z/Ctrl+Shift+Z undo/redo, which
''' needs no wiring here at all).
FUNCTION OnKeyPressed(controller AS GObj PTR, keyval AS INTEGER, keycode AS INTEGER, state AS INTEGER, data AS ANY PTR) AS INTEGER
    IF keyval = GDK_KEY_s AND (state AND GDK_CONTROL_MASK) <> 0 THEN
        CALL DoSave()
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

    DIM bar AS HeaderBar
    bar = NewHeaderBar()
    CALL HeaderBarSetShowTitleButtons(bar, 1)

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

    CALL WindowSetTitlebar(gWin, bar)
    CALL WindowSetChild(gWin, scroller)

    gHasPath = 0
    CALL UpdateTitle()

    CALL WindowPresent(gWin)
END SUB

DIM app AS Application
app = NewApplication("io.github.yann64.ebasiceditor")
CALL ObjConnect(app, "activate", @OnActivate, 0)
CALL ApplicationRun(app)
CALL ObjDestroy(app)
