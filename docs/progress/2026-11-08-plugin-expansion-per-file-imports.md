# Plugin expansion resolves a name through the imports of the file that writes it (#8690)

`Lyric.PluginExpand` resolved the names of a package through the union of its files'
imports; it now picks the writing file's own imports by the span's file id (D346).
The test is a two-file package binding one alias to two packages. `B0012` stays until
the other passes #8690 lists read each file's imports.
