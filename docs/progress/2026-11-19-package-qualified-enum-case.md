# A package-qualified enum case builds as the case in the typed IR (D349)

`Std.Http.GET` (the package path written in full while the package is imported) was typed by the checker but never recorded as the case it names, so the TIR builder counted it unbuilt: eight `Lyric.Docker` and four `Grpc` bodies. The member arm now records the reference as `Enum.Case` already did. Test: the `package_qualified_enum_case` shape in `scripts/ci/tir-builder-shapes-e2e.sh`.
