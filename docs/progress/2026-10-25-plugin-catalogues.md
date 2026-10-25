# Plugin catalogues and zip transfer (D248, D265, plugins P8)

The second half of plugin distribution, after signing and load-time verification (P7):

- `lyric-stdlib/std/zip.l` adds `Std.Zip`, in pure Lyric on every target: a bounded inflate (stored, fixed and dynamic
  blocks), an LZ77 deflate with fixed Huffman codes and a stored fallback, CRC-32, a zip reader that treats its input
  as hostile (bounds, local and central headers agreeing, unique UTF-8 names, `ZipLimits` on entries, sizes and
  compression ratio, CRC-32 and size checks; ZIP64 and encryption refused) and a deterministic writer. `zip_tests.l`
  runs zlib- and zipfile-generated fixtures and round trips on dotnet, the JVM and native; Python reads the writer's
  output from all three identically. 1.2 MB deflates in about 0.2 s.
- `Std.File` gains `rename` and `setExecutable` (mode 0755), with `lyric_file_set_executable` in `lyric-rt`.
- `lyric-stdlib/std/plugin_catalogue.l` adds `Std.PluginCatalogue`: the catalogue format and its signatures,
  `updateCatalogue` (K0120 signature or half-signed rotation, K0121 expiry, K0122 rollback), `loadFollowedCatalogue`
  (offline, with `stale`), `catalogueTrust`, `installPlugin` (K0123 for the zip, `plugin.sig` or identity, K0105-K0110
  for the artifact's signature; safe extraction; other installed versions replaced) and the authoring functions.
  `plugin_catalogue_tests.l` covers each refusal and a rotation on dotnet, the JVM and native.
- The CLI adds `lyric plugin catalogue init|publisher|remove-key|revoke-key|add|yank|sign`, `lyric plugin install`,
  `lyric plugin pack --zip`, and zip and `--catalogue` forms of `lyric plugin verify`. `scripts/ci/plugin-catalogue-e2e.sh`
  drives them, installing from a directory and over HTTP.

D265 records the details. The compiler's private `Jvm.Deflate`/`Jvm.ZipReader` move to `Std.Zip` in #8582. Two more
JVM slice-representation verifier failures found on the way were added to #7806.
