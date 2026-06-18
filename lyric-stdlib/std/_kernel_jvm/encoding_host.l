// std/_kernel_jvm/encoding_host.l — formerly JVM host boundary for Base64,
// hex, and UTF-8 encoding.
//
// All encoding operations have been rewritten in pure Lyric in
// stdlib/std/encoding.l and no longer require host externs.
// This file is retained as a placeholder so any future JVM-specific
// encoding optimisation has a home.
//
// Internal: only Std.Encoding should import this (currently unused).

@axiom("placeholder — no host calls remain in this boundary file")
package Std.EncodingHost
