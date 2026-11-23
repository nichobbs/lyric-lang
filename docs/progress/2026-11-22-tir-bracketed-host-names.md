# Bracketed extern type names are the structured host type (D764)

An `extern type` whose name carries its type arguments in brackets converts to the structured host type the metadata gives, so a value of it and a member's result of the same class are one type. `auto_ffi_generic_setter_self_test.l` builds.
