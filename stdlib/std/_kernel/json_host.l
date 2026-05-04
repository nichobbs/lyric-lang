// std/_kernel/json_host.l - host boundary for System.Text.Json.
//
// Holds every `@externTarget` and `extern type` declaration that
// `Std.Json` formerly declared inline.  Kernel function names carry
// a `host` prefix so they don't collide with the user-facing names
// in `Std.Json` when the test inliner merges every stdlib file into
// one user package.
//
// Internal: only `Std.Json` should import this; per
// `compiler/lyric/std/_kernel/README.md` the kernel is the audited
// extern boundary, not a general-purpose API.

@axiom("System.Text.Json operations conform to their documented .NET contracts")
package Std.JsonHost

extern type JsonDoc     = "System.Text.Json.JsonDocument"
extern type JsonElement = "System.Text.Json.JsonElement"

// =====================================================================
// Parsing.
//
// Routed through `Lyric.Stdlib.JsonHost.Parse` instead of the BCL
// `JsonDocument.Parse(string, JsonDocumentOptions = default)`
// directly: the FFI default-arg emit for `JsonDocumentOptions` still
// produces invalid IL.  The host wrapper is a one-liner and the
// indirection collapses if/when default-arg emit is fixed for
// arbitrary structs.
// =====================================================================

@externTarget("Lyric.Stdlib.JsonHost.Parse")
pub func hostParseJson(s: in String): JsonDoc = ()

@externTarget("System.Text.Json.JsonDocument.RootElement")
pub func hostRootElement(d: in JsonDoc): JsonElement = ()

// =====================================================================
// Walking the tree.
// =====================================================================

@externTarget("System.Text.Json.JsonElement.GetProperty")
pub func hostGetProperty(elem: in JsonElement, name: in String): JsonElement = ()

@externTarget("System.Text.Json.JsonElement.TryGetProperty")
pub func hostTryGetProperty(elem: in JsonElement, name: in String, out_: out JsonElement): Bool = ()

// =====================================================================
// Leaf accessors.  All `GetXyz` methods on `JsonElement` throw if the
// kind is wrong; the `tryGet*` family is the safe wrapper.
// =====================================================================

@externTarget("System.Text.Json.JsonElement.GetString")
pub func hostGetString(elem: in JsonElement): String = ()

@externTarget("System.Text.Json.JsonElement.GetInt32")
pub func hostGetInt32(elem: in JsonElement): Int = ()

@externTarget("System.Text.Json.JsonElement.GetInt64")
pub func hostGetInt64(elem: in JsonElement): Long = ()

@externTarget("System.Text.Json.JsonElement.GetBoolean")
pub func hostGetBoolean(elem: in JsonElement): Bool = ()

@externTarget("System.Text.Json.JsonElement.GetDouble")
pub func hostGetDouble(elem: in JsonElement): Double = ()

@externTarget("System.Text.Json.JsonElement.TryGetInt32")
pub func hostTryGetInt32(elem: in JsonElement, value: out Int): Bool = ()

@externTarget("System.Text.Json.JsonElement.TryGetInt64")
pub func hostTryGetInt64(elem: in JsonElement, value: out Long): Bool = ()

// =====================================================================
// Manual serialization helpers.  Routes through
// `Lyric.Stdlib.JsonHost.EncodeString` (the BCL's
// `JsonEncodedText.Encode` returns a struct that's awkward to bridge
// directly).
// =====================================================================

@externTarget("Lyric.Stdlib.JsonHost.EncodeString")
pub func hostEncodeString(s: in String): String = ()
