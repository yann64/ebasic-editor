' ebasic-editor - a code editor for eBasic, written in eBasic, using
' gtk4/eb-cjson as its GUI toolkit and JSON library.
'
' C0: proves the dependency wiring and basic widget assembly - a window
' with a SourceView showing plain placeholder text, no highlighting/
' file-I/O/LSP/ebpm/git integration yet (all follow in later slices).

#include "gtk4.iface.bas"

SUB OnActivate(rawApp AS GObj PTR, data AS ANY PTR)
    DIM app AS Application
    app = WrapApplication(rawApp)

    DIM win AS Window
    win = NewApplicationWindow(app)
    CALL WindowSetTitle(win, "ebasic-editor")
    CALL WindowSetDefaultSize(win, 800, 600)

    DIM view AS SourceView
    view = NewSourceView()
    CALL TextViewSetMonospace(view, 1)
    CALL TextViewSetWrapMode(view, GTK_WRAP_NONE)

    DIM buf AS TextBuffer
    buf = TextViewGetBuffer(view)
    CALL TextBufferSetText(buf, "PRINT ""Hello from ebasic-editor!""")

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
