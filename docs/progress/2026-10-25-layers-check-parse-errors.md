# The `[layers]` check reports parse errors instead of the layer errors they cause

`checkProjectLayers` (`lyric-compiler/lyric/cli/cli_layers.l`) parses every
project file before the layer check runs. A file with a parse error used to be
left out of the check on the assumption that the build that follows would
report it. Leaving it out made its package match no project package (Y0009)
and every package importing it break a rule (Y0002), and those errors stopped
the build, so the parse error itself was never shown. Seen while building
D272's `examples/plugins/ui-widgets/review`, where `src/logic.l` had an
assignment as a match-arm body (P0201) and the build printed only Y0009 and
Y0002.

The parsing step is now `Lyric.Cli.parseLayerFiles`, which returns either the
parsed and `@cfg`-erased files or the diagnostics of every file with a
parse error, each under the file's path. On a parse error the build, test and
prove commands print those diagnostics and stop before `checkLayers`. A file
with parse warnings only is still checked; the build reports its warnings.

Verified by `lyric-compiler/lyric/cli_layers_self_test.l` (in `make
test-emitter` and the compiler self-test CI batch): a project whose files all
parse returns every file; a project with the D272 P0201 file returns its
P0201 under `src/logic.l` and no layer diagnostic; a file without a path is
reported under its package name.
