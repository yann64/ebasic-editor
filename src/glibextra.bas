' Raw GLib declarations this project needs directly, shared by src/lsp.bas
' and src/buildrun.bas - a package's `--lib` interface only ever re-
' exports its own idiomatic-layer SUB/FUNCTION bodies, never a raw Extern
' declaration (see gtk4's own README), so these (used internally by
' gtk4's own bindings) aren't visible through gtk4.iface.bas even though
' gtk4 itself declares them - this project redeclares them itself, the
' same way gtk4 redeclares libc's strlen for its own internal use.
' `#include once`d from more than one file, so this lives in its own
' file rather than being declared twice (a real redeclaration error,
' found the moment buildrun.bas needed g_free too).

Declare Function g_malloc Lib "glib-2.0" (ByVal n_bytes AS ULONGINT) AS ANY PTR
Declare Sub g_free Lib "glib-2.0" (ByVal mem AS ANY PTR)
Declare Function g_main_context_iteration Lib "glib-2.0" (ByVal context AS ANY PTR, ByVal may_block AS INTEGER) AS INTEGER
