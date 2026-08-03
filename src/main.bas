' ebasic-editor - a code editor for eBasic, written in eBasic, using
' gtk4/eb-cjson as its GUI toolkit and JSON library.
'
' C0/C1: proves the dependency wiring and basic widget assembly, and
' loads this repo's own real eBasic syntax-highlighting definition
' (data/language-specs/ebasic.lang) - no file I/O/LSP/ebpm/git
' integration yet (all follow in later slices).

#include "gtk4.iface.bas"

SUB OnActivate(rawApp AS GObj PTR, data AS ANY PTR)
    DIM app AS Application
    app = WrapApplication(rawApp)

    DIM win AS Window
    win = NewApplicationWindow(app)
    CALL WindowSetTitle(win, "ebasic-editor")
    CALL WindowSetDefaultSize(win, 800, 600)

    DIM langMgr AS SourceLanguageManager
    langMgr = SourceLanguageManagerGetDefault()
    CALL SourceLanguageManagerAppendSearchPath(langMgr, "data/language-specs")
    DIM lang AS SourceLanguage
    lang = SourceLanguageManagerGetLanguage(langMgr, "ebasic")

    DIM buf AS SourceBuffer
    buf = NewSourceBufferWithLanguage(lang)
    CALL SourceBufferSetHighlightSyntax(buf, 1)
    CALL TextBufferSetText(buf, "PRINT ""Hello from ebasic-editor!""")

    DIM view AS SourceView
    view = NewSourceViewWithBuffer(buf)
    CALL TextViewSetMonospace(view, 1)
    CALL TextViewSetWrapMode(view, GTK_WRAP_NONE)
    CALL SourceViewSetShowLineNumbers(view, 1)
    CALL SourceViewSetHighlightCurrentLine(view, 1)

    DIM scroller AS ScrolledWindow
    scroller = NewScrolledWindow()
    CALL ScrolledWindowSetChild(scroller, view)

    CALL WindowSetChild(win, scroller)
    CALL WindowPresent(win)
END SUB

DIM app AS Application
app = NewApplication("io.github.yann64.ebasiceditor")
CALL ObjConnect(app, "activate", @OnActivate, 0)
CALL ApplicationRun(app)
CALL ObjDestroy(app)
