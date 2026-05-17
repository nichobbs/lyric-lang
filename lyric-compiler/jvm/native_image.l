// jvm/nativeimage.l — Stage B7: native-image config JSON generation.
//
// Pure string functions; no file I/O.  The caller is responsible for writing
// the returned strings to the appropriate output files.
//
// GraalVM native-image reads four JSON config files at build time:
//   reflect-config.json  — reflection registrations
//   resource-config.json — embedded resource patterns
//   proxy-config.json    — dynamic proxy interfaces
//   jni-config.json      — JNI class/method/field accesses
//
// Lyric-emitted JARs use none of reflection, dynamic proxies, or JNI; the
// only resource that needs declaring is the embedded lyric-contract blob.

package Jvm.NativeImage

import Std.Core

// Returns reflect-config.json content: always [] (no reflection used).
pub func reflectConfigJson(): String { "[]" }

// Returns resource-config.json for pkgName (declares the embedded lyric-contract).
pub func resourceConfigJson(pkgName: in String): String {
  "{\n  \"resources\": {\n    \"includes\": [\n      { \"pattern\": \"META-INF/lyric/" + pkgName + ".lyric-contract\" }\n    ]\n  }\n}"
}

// Returns proxy-config.json: always empty.
pub func proxyConfigJson(): String { "{\"proxies\": []}" }

// Returns jni-config.json: always empty.
pub func jniConfigJson(): String { "{\"jni\": []}" }
