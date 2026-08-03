' Verifies data/language-specs/ebasic.lang is valid, well-formed
' GtkSourceView language-spec XML (not just written by hand and assumed
' correct) - GtkSourceLanguageManager only returns a real language for
' `GetLanguage` if it successfully parsed/registered the file; any XML/
' RNG-schema error in it means this comes back "not found" (.handle = 0).
' Headless-safe: the language manager is a pure lookup, no display
' involved (see eb-gtk4's own sourceview_smoke.bas for the same reasoning).

#include "gtk4.iface.bas"

DIM mgr AS SourceLanguageManager
mgr = SourceLanguageManagerGetDefault()
CALL SourceLanguageManagerAppendSearchPath(mgr, "data/language-specs")

DIM lang AS SourceLanguage
lang = SourceLanguageManagerGetLanguage(mgr, "ebasic")
PRINT lang.handle <> 0

DIM buf AS SourceBuffer
buf = NewSourceBufferWithLanguage(lang)
CALL SourceBufferSetHighlightSyntax(buf, 1)
CALL TextBufferSetText(buf, "DIM x AS INTEGER")

DIM rawText AS ANY PTR
rawText = TextBufferGetText(buf)
DIM viaZstring AS ZSTRING
viaZstring = rawText
DIM text AS STRING
text = viaZstring
CALL FreeGMallocString(rawText)
PRINT text

PRINT "language spec ok"
