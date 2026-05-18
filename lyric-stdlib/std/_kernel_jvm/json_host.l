// std/_kernel_jvm/json_host.l - JVM host boundary for JSON parsing.
//
// Mirrors _kernel/json_host.l for the JVM target.  All operations
// route through lyric.stdlib.jvm.JsonHost, which wraps the JSON
// library bundled with Lyric.Jvm.Hosts.Jvm (Jackson ObjectMapper by
// default; the shim presents a stable API regardless of the backing
// library so the kernel strings never need to change if the library
// is swapped).
//
// JsonDoc   wraps the root node of a parsed JSON tree.
// JsonElement wraps a single node (object, array, or leaf value).
//
// The out-parameter operations (hostTryGetProperty, hostTryGetInt32,
// hostTryGetInt64) use @externTarget rather than extern package because
// extern package blocks do not currently support out parameters.
//
// Internal: only Std.Json should import this.

@axiom("lyric.stdlib.jvm.JsonHost operations conform to their documented JVM contracts")
package Std.JsonHost

extern type JsonDoc     = "lyric.stdlib.jvm.JsonDoc"
extern type JsonElement = "lyric.stdlib.jvm.JsonElement"

// =====================================================================
// Parsing.
// =====================================================================

@externTarget("lyric.stdlib.jvm.JsonHost.hostParseJson")
pub func hostParseJson(s: in String): JsonDoc = ()

@externTarget("lyric.stdlib.jvm.JsonHost.hostRootElement")
pub func hostRootElement(d: in JsonDoc): JsonElement = ()

// =====================================================================
// Walking the tree.
// =====================================================================

@externTarget("lyric.stdlib.jvm.JsonHost.hostGetProperty")
pub func hostGetProperty(elem: in JsonElement, name: in String): JsonElement = ()

// Returns false and leaves out_ unchanged when the property is absent.
@externTarget("lyric.stdlib.jvm.JsonHost.hostTryGetProperty")
pub func hostTryGetProperty(elem: in JsonElement, name: in String, out_: out JsonElement): Bool = ()

// =====================================================================
// Leaf accessors.  All GetXyz variants throw if the node kind is wrong;
// the tryGet* variants return false on type mismatch.
// =====================================================================

@externTarget("lyric.stdlib.jvm.JsonHost.hostGetString")
pub func hostGetString(elem: in JsonElement): String = ()

@externTarget("lyric.stdlib.jvm.JsonHost.hostGetInt32")
pub func hostGetInt32(elem: in JsonElement): Int = ()

@externTarget("lyric.stdlib.jvm.JsonHost.hostGetInt64")
pub func hostGetInt64(elem: in JsonElement): Long = ()

@externTarget("lyric.stdlib.jvm.JsonHost.hostGetBoolean")
pub func hostGetBoolean(elem: in JsonElement): Bool = ()

@externTarget("lyric.stdlib.jvm.JsonHost.hostGetDouble")
pub func hostGetDouble(elem: in JsonElement): Double = ()

@externTarget("lyric.stdlib.jvm.JsonHost.hostTryGetInt32")
pub func hostTryGetInt32(elem: in JsonElement, value: out Int): Bool = ()

@externTarget("lyric.stdlib.jvm.JsonHost.hostTryGetInt64")
pub func hostTryGetInt64(elem: in JsonElement, value: out Long): Bool = ()

// =====================================================================
// Serialisation helpers.
// =====================================================================

// Encodes a string value with JSON escaping (surrounding quotes
// included), equivalent to .NET's JsonEncodedText.Encode.
@externTarget("lyric.stdlib.jvm.JsonHost.hostEncodeString")
pub func hostEncodeString(s: in String): String = ()
