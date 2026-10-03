# Default thunk names are an injective encoding; no default rendered for a parameter without one (#8097)

Review follow-up to #7827/#8085 (D168). `Lyric.Parser.defaultThunkName`
joined the owner to the callable with `__`, the same separator that replaced
`.` in a dot-named function's name, so a record's method `scaled` and a
dot-named `func Acc.scaled` with the same parameters and defaulted parameter
got one name: two defaults panicked as an internal error on legal source, and
with only the method's default, `Lyric.ContractMeta` rendered it on the
function's parameter too, giving a restored consumer a default the source
never declared.

The name is now an injective, prefix-free encoding (docs/45 §5): a letter for
the callable's kind (`f` function, `m` record method, `i` interface member,
`p` impl method), the owner's names and the callable's dotted name as
count-prefixed lists of length-prefixed names, the parameter count and each
parameter's type as a letter for its form followed by its parts
(`thunkTypeKey`), then the parameter's name. The renderer emits a thunk call
only for a parameter that declares a default; a thunk named for one that
does not is an internal-compiler-error panic, never a fabricated default.

T0162's message, docs/01 and appendix B now say the same-count restriction
is this compiler's dispatch-key scheme (type, name and parameter count on
the MSIL, JVM and native backends), not a CLR or JVM limit.

Tests: `restored_default_args_self_test.l` builds a library with a record
method and a dot-named function of the same name and parameters (both with
defaults, and a pair where only the method has one) on both targets, checks
each call takes its own default, and checks that leaving out the dot-named
function's required argument does not compile. `contract_meta_self_test.l`
checks the encoding of every type form, distinct names across every kind and
owner split, and that no default is rendered for a parameter without one.
