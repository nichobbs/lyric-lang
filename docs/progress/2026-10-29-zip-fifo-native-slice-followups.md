# Follow-ups from plugin signing and catalogues (#8578, #8579, #8582, #7806)

Four gaps that D248's implementation (plugin signing, `Std.Zip`,
`Std.PluginCatalogue`) worked around are fixed, and the workarounds removed.

**The compiler reads archives with `Std.Zip` (#8582).** `Jvm.Deflate` and
`Jvm.ZipReader` are deleted. `Std.Zip` gains `readPrefixedZipDirectory`, which
reads an archive behind a prefix (a JDK `.jmod`'s 4-byte header): the prefix
length is where the central directory ends up less where the end record says
it starts, and each entry's `localHeaderOffset` is an offset into the data
given. Its duplicate-name check is now a map rather than a scan of the
entries so far, which was quadratic in the 7,600 entries of `java.base.jmod`.
The users moved:
- JVM auto-FFI (`Jvm.AutoFfi`) reads JMODs and JARs with
  `readPrefixedZipDirectory` and `readZipEntry`, with up to 65,535 entries;
  `Jvm.ClassReader` parses a `slice[Byte]` instead of a `List[Int]`.
- `Lyric.ContractMeta.readAllContractsFromJarFile` reads with
  `readZipDirectory`.
- Prebuilt native libraries (`cli_targz.l`, `cli_native_libs.l`) inflate gzip
  with `inflateRange`, bounded by the trailer's recorded length, and now check
  the trailer's CRC-32 as well as the length; zip prebuilts go through
  `readZipDirectory`, so a member's CRC-32 is checked too. The tar reader works
  on `slice[Byte]`. The 64 MiB bound on a member or an uncompressed tar stays.

`deflate_zip_self_test.l` becomes `class_reader_self_test.l` (the
`Jvm.ClassReader` cases). Its DEFLATE cases move to
`lyric-stdlib/tests/zip_tests.l` (empty input, a fixed block cut off after its
header, a back-reference before the start of the data), whose existing
hostile-archive tests cover its zip cases; it also gains a prefixed-archive
test. The auto-FFI JMOD tests (55), the gzip and tar tests in
`native_libs_self_test.l`, and the JAR-reading bridge tests pass unchanged.

**`Std.File.entryKind` on .NET (#8578).** On Unix the dotnet kernel calls the
runtime's own `SystemNative_LStat` (in `libSystem.Native`, linked statically
into a NativeAOT executable), whose `FileStatus` layout and `S_IF*` bits are
the runtime's and so the same on every Unix. A FIFO, socket or device node is
now `Other`, as on the JVM and native, so D248's listing rule holds on dotnet
hosts and `lyric plugin sign` refuses a FIFO instead of blocking on it.
Windows keeps the `FileSystemInfo` classification. `file_tests.l` checks a FIFO
and `/dev/null` on all three targets.

**Native codegen (#8579).**
- A package-qualified enum case (`File.RegularFile` under
  `import Std.File as File`) is registered under `<package>.<Case>`, so it
  resolves as a value and as a pattern (the enum twin of #7933).
- A `.toChar()` call is `Char`-typed for the backend's char tracking, so
  `.toString()` on it, `String + it`, and a binding initialised from it format
  the character instead of its code point.

`Std.PluginSign.asciiLower` now uses `(c + 32).toChar().toString()`. Tests:
`llvm_enum_case_resolve_self_test.l` item K and a `llvm_codegen_self_test.l`
case.

**JVM `slice[Byte]` representations (#7806, the two shapes added in October).**
A `slice[Byte]` is a `byte[]` or a boxed `Object[]` on the JVM, depending on
its producer (a match-bound payload is unboxed). The join of a value `if` or
`match` coerced its later arms with `coerceArgToCtx`, which never boxes a
primitive array, and `concat` converted its argument to an array but not to
the receiver's representation. Both now use `coerceValueTo`. `Std.Zip`'s
`readZipEntry` is back to the `if`/`match` shape the issue reported, and
`plugin_catalogue_tests.l` uses `good.concat([0u8])` again. Test:
`lyric-compiler/jvm/slice_byte_representation_jvm_self_test.l` on both
targets. The rest of #7806 (canonical arrays, erased generic instances) is
unchanged.
