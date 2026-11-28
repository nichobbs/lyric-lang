# D891: native lays out an impl of a generic interface for a generic union

Status: accepted (#9470, #7791; follows D864 and D868).

## Decision

`impl[T] Holder[T] for Wrap[T]` over a generic union is laid out per instance of the union, as `impl[T] Holder[T] for Box[T]` is per instance of a generic record (D864). A union that is the target of an impl is a heap object, so `fillHeapOnlyRecs` marks it for a generic target too (`genericImplTargetRecord`, beside the plain `implTargetRecordName` of D868); `registerGenericImpl` registers the impl's members as generic functions over the union under the same keys a generic record's use; `genericImplVtable` builds the vtable of an instance on first upcast from the impl's methods specialised at the instance's type arguments, over the union pointer (`unionPtrType`) where it used the record's. `checkGenericIfaceImpl` accepts a generic union target applied to the impl's own parameters in order.

`N0105` stays for an impl whose target is not a generic record or union applied to the impl's own type parameters, or whose interface argument has no native layout. The negative fixture `genericifaces_unsupported_impl.l` and its e2e check are replaced by `genericifaces_union_impl.l`, which calls the union through the interface at two instantiations, on the union value and as an inherited default, with the same output from both paths and a clean AddressSanitizer run.

## Not done

TIR lowers neither the upcast of a generic union instance to an interface instance nor the generic impl's member instances: those functions keep the AST lowering with a census reason, as for generic records (D864).
