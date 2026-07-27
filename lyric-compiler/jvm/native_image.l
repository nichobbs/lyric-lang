//! jvm/nativeimage.l — Stage B7: native-image config JSON generation.
//!
//! Pure string functions; no file I/O.  The caller is responsible for writing
//! the returned strings to the appropriate output files.
//!
//! GraalVM native-image reads four JSON config files at build time:
//!   reflect-config.json  — reflection registrations
//!   resource-config.json — embedded resource patterns
//!   proxy-config.json    — dynamic proxy interfaces
//!   jni-config.json      — JNI class/method/field accesses
//!
//! Lyric-emitted JARs use none of reflection, dynamic proxies, or JNI; the
//! only resource that needs declaring is the embedded lyric-contract blob.
package Jvm.NativeImage

import Std.Core
import Std.String as Str

// Returns reflect-config.json content: always [] (no reflection used).
pub func reflectConfigJson(): String {
  "[]"
}

// Escape a literal string for embedding in a native-image resource `pattern`,
// which native-image interprets as a java.util.regex pattern.  Only the
// metacharacters that can occur in a Lyric package name (`.`) or a JAR entry
// path need quoting; everything else in `[A-Za-z0-9_/-]` is regex-inert.
//
// Two escaping layers stack here and are easy to conflate.  The value must be
// a *regex* `\.`, and it is being written into a *JSON string*, where a lone
// backslash is an invalid escape (RFC 8259 admits only `" \ / b f n r t u`).
// So the emitted bytes must be `\\.` — hence four backslash characters in this
// Lyric literal, which decode to the two the JSON file needs.
func quoteResourceRegex(literal: in String): String {
  Str.replace(literal, ".", "\\\\.")
}

// Returns resource-config.json for pkgName (declares the embedded lyric-contract).
pub func resourceConfigJson(pkgName: in String): String {
  "{\n  \"resources\": {\n    \"includes\": [\n      { \"pattern\": \"META-INF/lyric/" + quoteResourceRegex(pkgName) +
    "\\\\.lyric-contract\" }\n    ]\n  }\n}"
}

// Returns resource-config.json covering EVERY package's lyric-contract blob.
//
// The release path (`lyric build --release --target jvm`) runs native-image
// over a *bundled* JAR: the user's package plus its transitive `Std.*` import
// closure and any sibling project packages, each of which carries its own
// `META-INF/lyric/<P>.lyric-contract` entry.  Naming one package would leave
// the rest unregistered, so the release config uses a pattern matching all of
// them rather than `resourceConfigJson`'s single-package form.
pub func resourceConfigJsonAll(): String {
  "{\n  \"resources\": {\n    \"includes\": [\n      { \"pattern\": \"META-INF/lyric/[^/]+\\\\.lyric-contract\" }\n    ]\n  }\n}"
}

// Returns proxy-config.json: always empty.
//
// The proxy-config schema is a top-level ARRAY of interface-list descriptors,
// not an object — native-image rejects `{"proxies": []}` at config-parse time
// with "first level of document must be an array".
pub func proxyConfigJson(): String {
  "[]"
}

// Returns jni-config.json: always empty.
//
// Like reflect-config and proxy-config, the jni-config schema is a top-level
// ARRAY of class descriptors; the object form `{"jni": []}` is a config-parse
// error, not an empty registration.
pub func jniConfigJson(): String {
  "[]"
}
