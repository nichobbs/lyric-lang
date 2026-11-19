# D417 - A host property read takes the host's subclass result at the superclass the context declares (docs/70 phase 3a, #8613)

**Status:** shipped; extends D445. The checker is unchanged.

## Context

`Std.HttpHost::requestHeaders` and `byteContentHeaders` return `req.Headers` and `content.Headers` as the `HttpHeaders` they declare. The host's `HttpRequestMessage.Headers` is an `HttpRequestHeaders` and `HttpContent.Headers` an `HttpContentHeaders`, both subclasses of `HttpHeaders`. `buildHostPropertyRead` and `buildHostStaticRead` refused a property whose declared result was not the checker's type, the nullable string or a result the checker maps to a Lyric type, so the read stayed counted (`a member access that is not a record field`, 2 dotnet bodies of the standard library). `hostResultNode`, which builds the node, already converts a host result to a superclass (D445), but the property readers never reached it.

## Decision

- `hostResultFlowsTo` is the one pre-check of the host member readers: the declared result is the checker's type, a possibly null string, a result the checker types as a Lyric type, a host subclass of the declared class (`hostUpcastKind`, read from the host metadata) or a base class of a more specific one (`hostResultNarrowsTo`). `buildHostPropertyRead` and `buildHostStaticRead` use it, and `hostResultNode` gives the node the checker's type.
- The dotnet kernels declare the host results they bind where the checker types none (docs/01 section 2.11, D436, D416): `Path.GetFileName` in `Std.PluginTrustedHost`, the `Path.GetDirectoryName` result that feeds `Directory.GetFiles`, and `Assembly.GetManifestResourceNames` in `Std.AnnotationMetaHost`.

## Results

`Std.HttpHost::requestHeaders` and `byteContentHeaders`, `Std.PluginTrustedHost::isSharedAssemblyFile` and `trustedHostOpen`, and `Std.AnnotationMetaHost::collectFromAssembly` build on `--target dotnet`. `tir-builder-shapes-e2e.sh` gains `host_property_upcast` (built and run).
