' A JSON-RPC client for ebasic_lsp - Content-Length-framed JSON-RPC over
' the child process's stdio (see docs/guide/lsp.md in the main eBasic
' repo), built on gtk4's async GSubprocess bindings (a blocking read here
' would freeze the whole GTK main loop while ebasic_lsp, a long-lived
' process, sits waiting for the next request) and eb-cjson for the wire
' format.
'
' The framing itself has no "end of batch" marker - a single didOpen/
' didChange can trigger any number of textDocument/publishDiagnostics
' notifications (one per touched file, including #include'd ones - see
' the LSP's own diagnostics_test.sh), so this client reads *continuously*:
' every message triggers LspDispatch, which either updates the UI right
' away (a notification) or resolves whatever the one outstanding client-
' initiated request was (hover/definition/completion - this editor never
' has more than one in flight at a time, matching its own single-
' document-editing scope) - then always re-arms the next async header
' read, a self-perpetuating chain that runs for the whole process's
' lifetime. initialize/shutdown are the only synchronous-feeling calls
' (a brief `g_main_context_iteration` pump loop) - acceptable since they
' each happen once, at startup/teardown.

#include once "eb-cjson.iface.bas"
#include once "glibextra.bas"

' libc helpers this file needs for its own wire-format plumbing - eBasic's
' STRING has no built-in parsing/formatting functions yet (LEN/MID$/
' INSTR/STR$ equivalents), so "Content-Length: <n>" is built and parsed at
' the raw ZSTRING/byte level instead, the same ANY-PTR/pointer-arithmetic
' toolkit this whole project's FFI bindings already rely on.
Declare Function atoi Lib "c" (ByVal s AS ZSTRING) AS INTEGER
Declare Function strlen Lib "c" (ByVal s AS ZSTRING) AS ULONGINT
Declare Function strcpy Lib "c" (ByVal dst AS ANY PTR, ByVal src AS ZSTRING) AS ZSTRING
Declare Function strcat Lib "c" (ByVal dst AS ANY PTR, ByVal src AS ZSTRING) AS ZSTRING

DIM gLspProc AS Subprocess
DIM gLspStdin AS OutputStream
DIM gLspStdout AS InputStream
DIM gLspLineReader AS DataInputStream
DIM gLspRunning AS INTEGER
DIM gLspContentLength AS INTEGER
DIM gLspNextId AS INTEGER

' Set once via LspInit, before LspStart - the buffer diagnostics/hover/
' completion act on, and the tags used to render diagnostics.
DIM gLspBuf AS SourceBuffer
DIM gLspStatusLabel AS Label
DIM gLspHasStatusLabel AS INTEGER
DIM gLspLastStatus AS STRING
DIM gLspErrorTag AS ANY PTR
DIM gLspWarningTag AS ANY PTR

DIM gLspDocUri AS STRING
DIM gLspDocVersion AS INTEGER
DIM gLspDocOpen AS INTEGER

' At most one outstanding client-initiated request at a time - matches
' this editor's own single-document, single-in-flight-request scope.
' 0 = none, 1 = hover, 2 = definition, 3 = completion, 4 = initialize,
' 5 = shutdown.
DIM gLspPendingKind AS INTEGER

''' Bumped every time a publishDiagnostics notification for the current
''' document is processed - notifications have no id to wait on the way a
''' request's response does, so a headless test (see
''' tests/lsp_client_smoke.bas) watches this counter instead of pumping a
''' fixed, possibly-too-short-or-too-long number of iterations blindly.
DIM gLspDiagUpdateCount AS INTEGER

''' Writes `n`'s decimal digits (n >= 0) as a NUL-terminated string into
''' `buf` (caller-allocated, at least 21 bytes - enough for any 64-bit
''' value plus the NUL) - the one integer-to-string conversion this file
''' needs (a JSON-RPC frame's own byte count), written by hand since
''' eBasic has no STR$/CStr equivalent yet (see the main eBasic repo's own
''' roadmap for the planned FreeBASIC-style string library this'll likely
''' fold into later).
SUB IntToDecimalZstring(n AS INTEGER, buf AS ANY PTR)
    DIM bp AS BYTE PTR
    bp = buf

    IF n = 0 THEN
        *bp = 48
        *(bp + 1) = 0
        EXIT SUB
    END IF

    DIM digits(20) AS INTEGER
    DIM count AS INTEGER
    count = 0
    DIM v AS INTEGER
    v = n
    DO WHILE v > 0
        digits(count) = v MOD 10
        v = v \ 10
        count = count + 1
    LOOP

    DIM i AS INTEGER
    FOR i = 0 TO count - 1
        *(bp + i) = 48 + digits(count - 1 - i)
    NEXT i
    *(bp + count) = 0
END SUB

''' Frames `msg` as `Content-Length: <n>\r\n\r\n<json>` and writes it to
''' the child's stdin in one call - `msg` is freed by the caller, not
''' here (matches every other JsonValue-consuming function in this file).
SUB LspWriteFramed(BYVAL msg AS JsonValue)
    DIM rawText AS ANY PTR
    rawText = JsonStringify(msg)
    DIM bodyZ AS ZSTRING
    bodyZ = rawText
    DIM bodyLen AS INTEGER
    bodyLen = strlen(bodyZ)

    DIM lenBuf AS ANY PTR
    lenBuf = g_malloc(24)
    CALL IntToDecimalZstring(bodyLen, lenBuf)

    ' "Content-Length: " (16) + up to 20 digits + "\r\n\r\n" (4) + body +
    ' NUL - 64 extra bytes is a deliberately generous margin over the
    ' header's own worst case, matching this project's own GTK4_TEXT_ITER_SIZE-
    ' style convention for "comfortably oversized, not tightly fitted".
    DIM frameBuf AS ANY PTR
    frameBuf = g_malloc(bodyLen + 64)
    CALL strcpy(frameBuf, "Content-Length: ")
    CALL strcat(frameBuf, lenBuf)
    CALL g_free(lenBuf)

    DIM headerLen AS INTEGER
    headerLen = strlen(frameBuf)
    DIM tailPos AS BYTE PTR
    tailPos = frameBuf
    tailPos = tailPos + headerLen
    *tailPos = 13
    *(tailPos + 1) = 10
    *(tailPos + 2) = 13
    *(tailPos + 3) = 10
    *(tailPos + 4) = 0

    CALL strcat(frameBuf, bodyZ)

    DIM frameZ AS ZSTRING
    frameZ = frameBuf
    CALL OutputStreamWriteAll(gLspStdin, frameZ)
    CALL g_free(frameBuf)
    CALL JsonFreeString(rawText)
END SUB

SUB LspSendNotification(BYVAL method AS STRING, BYVAL params AS JsonValue)
    DIM msg AS JsonValue
    msg = JsonNewObject()
    CALL JsonSetField(msg, "jsonrpc", JsonNewString("2.0"))
    CALL JsonSetField(msg, "method", JsonNewString(method))
    CALL JsonSetField(msg, "params", params)
    CALL LspWriteFramed(msg)
    CALL JsonFree(msg)
END SUB

''' Sends a request and marks `kind` as the one outstanding client-
''' initiated request (see this file's own top doc comment) - returns the
''' id used (not currently read back by any caller, but kept for
''' completeness/future use).
FUNCTION LspSendRequest(BYVAL method AS STRING, BYVAL params AS JsonValue, kind AS INTEGER) AS INTEGER
    DIM id AS INTEGER
    id = gLspNextId
    gLspNextId = gLspNextId + 1
    gLspPendingKind = kind

    DIM msg AS JsonValue
    msg = JsonNewObject()
    CALL JsonSetField(msg, "jsonrpc", JsonNewString("2.0"))
    CALL JsonSetField(msg, "id", JsonNewNumber(id))
    CALL JsonSetField(msg, "method", JsonNewString(method))
    CALL JsonSetField(msg, "params", params)
    CALL LspWriteFramed(msg)
    CALL JsonFree(msg)

    LspSendRequest = id
END FUNCTION

''' Shows `text` in the status bar - hover/completion results, and simple
''' progress/error notices (e.g. "no definition found"). Always recorded
''' in gLspLastStatus; also pushed to the real status Label if LspInit
''' (not LspInitHeadless) provided one.
SUB LspSetStatus(BYVAL text AS STRING)
    gLspLastStatus = text
    IF gLspHasStatusLabel <> 0 THEN
        CALL LabelSetText(gLspStatusLabel, text)
    END IF
END SUB

SUB LspHandlePublishDiagnostics(BYVAL params AS JsonValue)
    DIM uri AS STRING
    uri = JsonGetString(JsonObjectGet(params, "uri"))

    ' Single-document editing scope (see the main eBasic repo's roadmap) -
    ' only the currently open document's own diagnostics are rendered; a
    ' diagnostic surfaced against a different uri (an #include'd file) is
    ' not shown inline in v1.
    IF uri <> gLspDocUri THEN
        EXIT SUB
    END IF

    gLspDiagUpdateCount = gLspDiagUpdateCount + 1

    CALL TextBufferClearTag(gLspBuf, gLspErrorTag)
    CALL TextBufferClearTag(gLspBuf, gLspWarningTag)

    DIM diagsField AS JsonValue
    diagsField = JsonObjectGet(params, "diagnostics")
    DIM n AS INTEGER
    n = JsonArrayLen(diagsField)

    DIM i AS INTEGER
    FOR i = 0 TO n - 1
        DIM d AS JsonValue
        d = JsonArrayGet(diagsField, i)
        DIM rangeField AS JsonValue
        rangeField = JsonObjectGet(d, "range")
        DIM startField AS JsonValue
        startField = JsonObjectGet(rangeField, "start")
        DIM endField AS JsonValue
        endField = JsonObjectGet(rangeField, "end")

        DIM startLine AS INTEGER
        DIM startCol AS INTEGER
        DIM endLine AS INTEGER
        DIM endCol AS INTEGER
        startLine = JsonGetNumber(JsonObjectGet(startField, "line"))
        startCol = JsonGetNumber(JsonObjectGet(startField, "character"))
        endLine = JsonGetNumber(JsonObjectGet(endField, "line"))
        endCol = JsonGetNumber(JsonObjectGet(endField, "character"))
        IF endLine = startLine AND endCol = startCol THEN
            ' Diagnostic ranges are one point, not a span (see lsp.md) -
            ' widen by one character so the tag is actually visible.
            endCol = startCol + 1
        END IF

        DIM severity AS INTEGER
        severity = JsonGetNumber(JsonObjectGet(d, "severity"))
        IF severity = 2 THEN
            CALL TextBufferApplyTagRange(gLspBuf, gLspWarningTag, startLine, startCol, endLine, endCol)
        ELSE
            CALL TextBufferApplyTagRange(gLspBuf, gLspErrorTag, startLine, startCol, endLine, endCol)
        END IF
    NEXT i

    IF n = 0 THEN
        CALL LspSetStatus("no problems")
    ELSEIF n = 1 THEN
        CALL LspSetStatus("1 problem")
    ELSE
        DIM countBuf AS ANY PTR
        countBuf = g_malloc(24)
        CALL IntToDecimalZstring(n, countBuf)
        DIM countZ AS ZSTRING
        countZ = countBuf
        DIM countStr AS STRING
        countStr = countZ
        CALL g_free(countBuf)
        CALL LspSetStatus(countStr & " problems")
    END IF
END SUB

SUB LspHandleHoverResponse(BYVAL msg AS JsonValue)
    DIM result AS JsonValue
    result = JsonObjectGet(msg, "result")
    IF JsonIsValid(result) = 0 OR JsonIsObject(result) = 0 THEN
        CALL LspSetStatus("no hover info")
        EXIT SUB
    END IF
    DIM contents AS JsonValue
    contents = JsonObjectGet(result, "contents")
    DIM value AS STRING
    value = JsonGetString(JsonObjectGet(contents, "value"))
    CALL LspSetStatus(value)
END SUB

SUB LspHandleDefinitionResponse(BYVAL msg AS JsonValue)
    DIM result AS JsonValue
    result = JsonObjectGet(msg, "result")

    ' The real server returns either a single Location object or an empty
    ' array (see server.cpp's own handleDefinition) - normalize both.
    DIM loc AS JsonValue
    IF JsonIsValid(result) <> 0 AND JsonIsObject(result) <> 0 THEN
        loc = result
    ELSEIF JsonIsValid(result) <> 0 AND JsonIsArray(result) <> 0 AND JsonArrayLen(result) > 0 THEN
        loc = JsonArrayGet(result, 0)
    ELSE
        CALL LspSetStatus("no definition found")
        EXIT SUB
    END IF

    DIM uri AS STRING
    uri = JsonGetString(JsonObjectGet(loc, "uri"))
    IF uri <> gLspDocUri THEN
        ' Single-document editing scope - a definition in another file
        ' (e.g. a dependency's own generated interface) can't be jumped to
        ' yet; report where it is instead of silently doing nothing.
        CALL LspSetStatus("definition is in " & uri)
        EXIT SUB
    END IF

    DIM rangeField AS JsonValue
    rangeField = JsonObjectGet(loc, "range")
    DIM startField AS JsonValue
    startField = JsonObjectGet(rangeField, "start")
    DIM line AS INTEGER
    DIM col AS INTEGER
    line = JsonGetNumber(JsonObjectGet(startField, "line"))
    col = JsonGetNumber(JsonObjectGet(startField, "character"))
    CALL TextBufferPlaceCursorAt(gLspBuf, line, col)
    CALL LspSetStatus("jumped to definition")
END SUB

SUB LspHandleCompletionResponse(BYVAL msg AS JsonValue)
    DIM result AS JsonValue
    result = JsonObjectGet(msg, "result")
    IF JsonIsValid(result) = 0 OR JsonIsArray(result) = 0 THEN
        CALL LspSetStatus("no completions")
        EXIT SUB
    END IF

    DIM n AS INTEGER
    n = JsonArrayLen(result)
    IF n = 0 THEN
        CALL LspSetStatus("no completions")
        EXIT SUB
    END IF

    ' Completion candidates are shown as text in the status bar, not an
    ' interactive insertable popup - a deliberate v1 scope cut (see
    ' README.md) rather than a half-built popover/list-window UI this
    ' sandbox has no way to visually verify at all.
    DIM shown AS INTEGER
    shown = n
    IF shown > 8 THEN
        shown = 8
    END IF

    DIM text AS STRING
    text = ""
    DIM i AS INTEGER
    FOR i = 0 TO shown - 1
        DIM candidateLabel AS STRING
        candidateLabel = JsonGetString(JsonObjectGet(JsonArrayGet(result, i), "label"))
        IF i > 0 THEN
            text = text & ", "
        END IF
        text = text & candidateLabel
    NEXT i
    IF shown < n THEN
        text = text & ", ..."
    END IF
    CALL LspSetStatus(text)
END SUB

SUB LspDispatch(BYVAL msg AS JsonValue)
    DIM methodField AS JsonValue
    methodField = JsonObjectGet(msg, "method")
    IF JsonIsValid(methodField) <> 0 THEN
        DIM methodName AS STRING
        methodName = JsonGetString(methodField)
        IF methodName = "textDocument/publishDiagnostics" THEN
            CALL LspHandlePublishDiagnostics(JsonObjectGet(msg, "params"))
        END IF
        EXIT SUB
    END IF

    SELECT CASE gLspPendingKind
    CASE 1
        CALL LspHandleHoverResponse(msg)
    CASE 2
        CALL LspHandleDefinitionResponse(msg)
    CASE 3
        CALL LspHandleCompletionResponse(msg)
    END SELECT
    gLspPendingKind = 0
END SUB

SUB LspReadNextHeader()
    CALL DataInputStreamReadLineAsync(gLspLineReader, @OnLspHeaderLine, 0)
END SUB

SUB OnLspHeaderLine(source AS GObj PTR, res AS ANY PTR, data AS ANY PTR)
    DIM gotLine AS INTEGER
    DIM rawLine AS ANY PTR
    rawLine = DataInputStreamReadLineFinish(gLspLineReader, res, gotLine)
    IF gotLine = 0 THEN
        gLspRunning = 0
        EXIT SUB
    END IF

    ' Skip the fixed 16-character "Content-Length: " prefix (verified
    ' directly against the real server's own framing, lsp/src/rpc.cpp) -
    ' atoi stops at the first non-digit, so a trailing "\r" left in the
    ' line (GDataInputStream's default newline handling only strips a
    ' bare "\n") is harmless.
    DIM bytePtr AS BYTE PTR
    bytePtr = rawLine
    DIM numStart AS ANY PTR
    numStart = bytePtr + 16
    gLspContentLength = atoi(numStart)
    CALL FreeGMallocString(rawLine)

    CALL DataInputStreamReadLineAsync(gLspLineReader, @OnLspBlankLine, 0)
END SUB

SUB OnLspBlankLine(source AS GObj PTR, res AS ANY PTR, data AS ANY PTR)
    DIM gotLine AS INTEGER
    DIM rawLine AS ANY PTR
    rawLine = DataInputStreamReadLineFinish(gLspLineReader, res, gotLine)
    IF gotLine <> 0 THEN
        CALL FreeGMallocString(rawLine)
    END IF

    DIM bodyBuf AS ANY PTR
    bodyBuf = g_malloc(gLspContentLength + 1)
    ' Read through gLspLineReader (the DataInputStream), not the raw
    ' gLspStdout - GDataInputStream is a GBufferedInputStream, so bytes
    ' already pulled into its own internal buffer (e.g. the start of this
    ' very body, delivered by the OS in the same read as the header/blank
    ' lines) would never reach a read issued straight against the
    ' underlying raw stream. Every read on this pipe has to go through the
    ' one buffered object for its lifetime.
    CALL InputStreamReadAllAsync(gLspLineReader, bodyBuf, gLspContentLength, @OnLspBody, bodyBuf)
END SUB

SUB OnLspBody(source AS GObj PTR, res AS ANY PTR, data AS ANY PTR)
    DIM bodyBuf AS ANY PTR
    bodyBuf = data
    DIM bytesRead AS INTEGER
    CALL InputStreamReadAllFinish(gLspLineReader, res, bytesRead)

    DIM bytePtr AS BYTE PTR
    bytePtr = bodyBuf
    *(bytePtr + bytesRead) = 0

    DIM z AS ZSTRING
    z = bodyBuf
    DIM msg AS JsonValue
    msg = JsonParse(z)
    CALL g_free(bodyBuf)

    IF JsonIsValid(msg) <> 0 THEN
        CALL LspDispatch(msg)
        CALL JsonFree(msg)
    END IF

    IF gLspRunning <> 0 THEN
        CALL LspReadNextHeader()
    END IF
END SUB

''' Shared setup for LspInit/LspInitHeadless.
SUB LspInitCommon(buf AS SourceBuffer)
    gLspBuf = buf
    gLspErrorTag = TextBufferCreateUnderlineTag(buf, "lsp-error", PANGO_UNDERLINE_ERROR)
    gLspWarningTag = TextBufferCreateUnderlineTag(buf, "lsp-warning", PANGO_UNDERLINE_SINGLE)
    gLspDocOpen = 0
    gLspPendingKind = 0
    gLspRunning = 0
END SUB

''' Stashes the widgets LSP results are rendered into - call once, before
''' LspStart.
SUB LspInit(buf AS SourceBuffer, statusLabel AS Label)
    CALL LspInitCommon(buf)
    gLspStatusLabel = statusLabel
    gLspHasStatusLabel = 1
END SUB

''' The same as LspInit, but with no status-bar widget - GtkLabel (like
''' every real GtkWidget) needs an actual GTK4 display backend to
''' construct at all, which this sandbox's automated tests don't have
''' (see eb-gtk4's own idiomatic_smoke.bas doc comment); LspSetStatus
''' still records the latest status text (see gLspLastStatus), just
''' without a widget to also push it into - what tests/lsp_client_smoke.bas
''' uses to verify the whole client end to end, headlessly, against a
''' real spawned ebasic_lsp.
SUB LspInitHeadless(buf AS SourceBuffer)
    CALL LspInitCommon(buf)
    gLspHasStatusLabel = 0
END SUB

''' Blocking-pumps the GLib main loop `iterations` times - a real GTK
''' application never needs this (its own main loop already runs
''' continuously via ApplicationRun, so an async notification like
''' publishDiagnostics gets processed the moment it arrives); a headless
''' test with no running loop at all does, to let a fire-and-forget
''' notification's own asynchronous round trip (didOpen/didChange ->
''' publishDiagnostics) actually complete before checking its effect - see
''' tests/lsp_client_smoke.bas.
SUB LspPump(iterations AS INTEGER)
    DIM i AS INTEGER
    FOR i = 1 TO iterations
        CALL g_main_context_iteration(0, -1)
    NEXT i
END SUB

''' Blocks (bounded, up to 20 iterations) until a publishDiagnostics
''' notification for the current document has been processed at least
''' once since `before` (a value of gLspDiagUpdateCount captured right
''' before triggering a didOpen/didChange) - see LspPump's own doc
''' comment on why a headless test needs this at all.
SUB LspWaitForDiagUpdate(before AS INTEGER)
    DIM tries AS INTEGER
    tries = 0
    DO WHILE gLspDiagUpdateCount = before AND tries < 20
        CALL g_main_context_iteration(0, -1)
        tries = tries + 1
    LOOP
END SUB

''' Spawns ebasic_lsp (found at `lspPath`) and starts the async read
''' chain. Returns whether spawning succeeded.
FUNCTION LspStart(BYVAL lspPath AS STRING) AS INTEGER
    DIM launcher AS SubprocessLauncher
    launcher = NewSubprocessLauncher(G_SUBPROCESS_FLAGS_STDIN_PIPE OR G_SUBPROCESS_FLAGS_STDOUT_PIPE)

    DIM argv(1) AS ZSTRING
    argv(0) = lspPath
    ' argv(1) stays unassigned - the argv NUL terminator.

    gLspProc = SubprocessLauncherSpawnv(launcher, @argv(0))
    gLspRunning = (gLspProc.handle <> 0)
    IF gLspRunning = 0 THEN
        LspStart = 0
        EXIT FUNCTION
    END IF

    gLspStdin = SubprocessGetStdinPipe(gLspProc)
    gLspStdout = SubprocessGetStdoutPipe(gLspProc)
    gLspLineReader = NewDataInputStream(gLspStdout)
    gLspNextId = 1

    CALL LspReadNextHeader()
    LspStart = 1
END FUNCTION

''' Runs the initialize/initialized handshake - blocks (via a manual GLib
''' main-loop pump) until the response arrives, acceptable since this
''' happens once, at startup. Returns whether it succeeded.
FUNCTION LspInitialize() AS INTEGER
    IF gLspRunning = 0 THEN
        LspInitialize = 0
        EXIT FUNCTION
    END IF

    DIM params AS JsonValue
    params = JsonNewObject()
    CALL JsonSetField(params, "processId", JsonNewNull())
    CALL JsonSetField(params, "rootUri", JsonNewNull())
    CALL JsonSetField(params, "capabilities", JsonNewObject())
    CALL LspSendRequest("initialize", params, 4)

    DO WHILE gLspPendingKind = 4 AND gLspRunning <> 0
        CALL g_main_context_iteration(0, -1)
    LOOP

    IF gLspRunning = 0 THEN
        LspInitialize = 0
        EXIT FUNCTION
    END IF

    DIM notif AS JsonValue
    notif = JsonNewObject()
    CALL JsonSetField(notif, "jsonrpc", JsonNewString("2.0"))
    CALL JsonSetField(notif, "method", JsonNewString("initialized"))
    CALL JsonSetField(notif, "params", JsonNewObject())
    CALL LspWriteFramed(notif)
    CALL JsonFree(notif)

    LspInitialize = 1
END FUNCTION

''' Tells the server about a newly opened document - closes whatever
''' document was previously open first (this editor only ever has one
''' open at a time).
SUB LspDidOpen(BYVAL uri AS STRING, BYVAL text AS STRING)
    CALL LspDidClose()

    gLspDocUri = uri
    gLspDocVersion = 1
    gLspDocOpen = 1

    DIM textDoc AS JsonValue
    textDoc = JsonNewObject()
    CALL JsonSetField(textDoc, "uri", JsonNewString(uri))
    CALL JsonSetField(textDoc, "languageId", JsonNewString("ebasic"))
    CALL JsonSetField(textDoc, "version", JsonNewNumber(gLspDocVersion))
    CALL JsonSetField(textDoc, "text", JsonNewString(text))

    DIM params AS JsonValue
    params = JsonNewObject()
    CALL JsonSetField(params, "textDocument", textDoc)
    CALL LspSendNotification("textDocument/didOpen", params)
END SUB

''' Reports the document's full new content - a notification only (no
''' response to wait for), sent on every buffer change; the server's own
''' textDocumentSync is Full (whole-text replace), matching this call's
''' own shape.
SUB LspDidChange(BYVAL text AS STRING)
    IF gLspDocOpen = 0 THEN
        EXIT SUB
    END IF
    gLspDocVersion = gLspDocVersion + 1

    DIM textDoc AS JsonValue
    textDoc = JsonNewObject()
    CALL JsonSetField(textDoc, "uri", JsonNewString(gLspDocUri))
    CALL JsonSetField(textDoc, "version", JsonNewNumber(gLspDocVersion))

    DIM change AS JsonValue
    change = JsonNewObject()
    CALL JsonSetField(change, "text", JsonNewString(text))
    DIM changes AS JsonValue
    changes = JsonNewArray()
    CALL JsonArrayAppend(changes, change)

    DIM params AS JsonValue
    params = JsonNewObject()
    CALL JsonSetField(params, "textDocument", textDoc)
    CALL JsonSetField(params, "contentChanges", changes)
    CALL LspSendNotification("textDocument/didChange", params)
END SUB

SUB LspDidClose()
    IF gLspDocOpen = 0 THEN
        EXIT SUB
    END IF

    DIM textDoc AS JsonValue
    textDoc = JsonNewObject()
    CALL JsonSetField(textDoc, "uri", JsonNewString(gLspDocUri))
    DIM params AS JsonValue
    params = JsonNewObject()
    CALL JsonSetField(params, "textDocument", textDoc)
    CALL LspSendNotification("textDocument/didClose", params)

    gLspDocOpen = 0
END SUB

''' Requests hover info for the given 0-based line/character - result is
''' shown via LspSetStatus once the response arrives (a brief blocking
''' pump, same reasoning as LspInitialize - a single quick round trip
''' triggered by an explicit user action, not a per-keystroke cost).
SUB LspRequestHover(line AS INTEGER, col AS INTEGER)
    IF gLspDocOpen = 0 THEN
        EXIT SUB
    END IF

    DIM textDoc AS JsonValue
    textDoc = JsonNewObject()
    CALL JsonSetField(textDoc, "uri", JsonNewString(gLspDocUri))
    DIM position AS JsonValue
    position = JsonNewObject()
    CALL JsonSetField(position, "line", JsonNewNumber(line))
    CALL JsonSetField(position, "character", JsonNewNumber(col))

    DIM params AS JsonValue
    params = JsonNewObject()
    CALL JsonSetField(params, "textDocument", textDoc)
    CALL JsonSetField(params, "position", position)
    CALL LspSendRequest("textDocument/hover", params, 1)

    DO WHILE gLspPendingKind = 1 AND gLspRunning <> 0
        CALL g_main_context_iteration(0, -1)
    LOOP
END SUB

SUB LspRequestDefinition(line AS INTEGER, col AS INTEGER)
    IF gLspDocOpen = 0 THEN
        EXIT SUB
    END IF

    DIM textDoc AS JsonValue
    textDoc = JsonNewObject()
    CALL JsonSetField(textDoc, "uri", JsonNewString(gLspDocUri))
    DIM position AS JsonValue
    position = JsonNewObject()
    CALL JsonSetField(position, "line", JsonNewNumber(line))
    CALL JsonSetField(position, "character", JsonNewNumber(col))

    DIM params AS JsonValue
    params = JsonNewObject()
    CALL JsonSetField(params, "textDocument", textDoc)
    CALL JsonSetField(params, "position", position)
    CALL LspSendRequest("textDocument/definition", params, 2)

    DO WHILE gLspPendingKind = 2 AND gLspRunning <> 0
        CALL g_main_context_iteration(0, -1)
    LOOP
END SUB

SUB LspRequestCompletion(line AS INTEGER, col AS INTEGER)
    IF gLspDocOpen = 0 THEN
        EXIT SUB
    END IF

    DIM textDoc AS JsonValue
    textDoc = JsonNewObject()
    CALL JsonSetField(textDoc, "uri", JsonNewString(gLspDocUri))
    DIM position AS JsonValue
    position = JsonNewObject()
    CALL JsonSetField(position, "line", JsonNewNumber(line))
    CALL JsonSetField(position, "character", JsonNewNumber(col))

    DIM params AS JsonValue
    params = JsonNewObject()
    CALL JsonSetField(params, "textDocument", textDoc)
    CALL JsonSetField(params, "position", position)
    CALL LspSendRequest("textDocument/completion", params, 3)

    DO WHILE gLspPendingKind = 3 AND gLspRunning <> 0
        CALL g_main_context_iteration(0, -1)
    LOOP
END SUB

''' Shuts the server down cleanly (shutdown request, then exit
''' notification) and waits for it to exit - call once, at application
''' quit.
SUB LspStop()
    IF gLspRunning = 0 THEN
        EXIT SUB
    END IF

    CALL LspDidClose()

    DIM req AS JsonValue
    req = JsonNewObject()
    CALL JsonSetField(req, "jsonrpc", JsonNewString("2.0"))
    CALL JsonSetField(req, "id", JsonNewNumber(gLspNextId))
    CALL JsonSetField(req, "method", JsonNewString("shutdown"))
    gLspNextId = gLspNextId + 1
    gLspPendingKind = 5
    CALL LspWriteFramed(req)
    CALL JsonFree(req)

    DO WHILE gLspPendingKind = 5 AND gLspRunning <> 0
        CALL g_main_context_iteration(0, -1)
    LOOP

    DIM notif AS JsonValue
    notif = JsonNewObject()
    CALL JsonSetField(notif, "jsonrpc", JsonNewString("2.0"))
    CALL JsonSetField(notif, "method", JsonNewString("exit"))
    CALL LspWriteFramed(notif)
    CALL JsonFree(notif)

    CALL SubprocessWait(gLspProc)
    gLspRunning = 0
END SUB
