// std/_kernel_jvm/encoding_host.l — JVM host boundary for Base64, hex, and
// UTF-8 encoding.
//
// Mirrors _kernel/encoding_host.l.  All operations route through
// lyric.stdlib.jvm.EncodingHost shims because:
//
//   toBase64String   — java.util.Base64.getEncoder().encodeToString(byte[]);
//                      instance-chain access requires a shim.
//   tryFromBase64    — java.util.Base64.getDecoder().decode(string) throws
//                      IllegalArgumentException on bad input; shim wraps.
//   toHexString      — no direct equivalent; shim uses
//                      HexFormat.of().formatHex(byte[]) (.java 17+) or
//                      a manual nibble loop for older JVMs.
//   tryFromHex       — shim using HexFormat.of().parseHex() with catch.
//   encodeUtf8       — "string".getBytes(StandardCharsets.UTF_8); shim.
//   tryDecodeUtf8    — new String(bytes, StandardCharsets.UTF_8) can throw
//                      on malformed sequences; shim wraps.
//
// Internal: only Std.Encoding should import this.

@axiom("lyric.stdlib.jvm.EncodingHost encoding operations conform to their documented JVM contracts")
package Std.EncodingHost

@externTarget("lyric.stdlib.jvm.EncodingHost.toBase64String")
pub func hostToBase64String(bytes: in slice[Byte]): String = ()

@externTarget("lyric.stdlib.jvm.EncodingHost.tryFromBase64")
pub func hostTryFromBase64(s: in String, value: out slice[Byte]): Bool = ()

@externTarget("lyric.stdlib.jvm.EncodingHost.toHexString")
pub func hostToHexString(bytes: in slice[Byte]): String = ()

@externTarget("lyric.stdlib.jvm.EncodingHost.tryFromHex")
pub func hostTryFromHex(s: in String, value: out slice[Byte]): Bool = ()

@externTarget("lyric.stdlib.jvm.EncodingHost.encodeUtf8")
pub func hostEncodeUtf8(s: in String): slice[Byte] = ()

@externTarget("lyric.stdlib.jvm.EncodingHost.tryDecodeUtf8")
pub func hostTryDecodeUtf8(bytes: in slice[Byte], value: out String): Bool = ()
