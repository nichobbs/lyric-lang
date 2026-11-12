# Native backend on TIR: heap records (docs/70 phase 4a, D520)

`Lyric.LlvmTir` lowers construction, field reads and `.copy` of heap records from TIR with
the explicit ownership model: fields are evaluated before the allocation, the object owns
its reference fields, a read is borrowed, a copy retains the shared references, and record
locals are released with their scope. The code generator hands over each record's
pointer type and destructor symbol; protected, foreign and `@nativeDtor` types stay on
the AST path.

`native-via-tir-e2e.sh` builds `native-via-tir/heaprecords.l` both ways, checks the
specified output, and recompiles the TIR build's IR under AddressSanitizer. The per-unit
layout maps (`tirUnitMaps`) replace the per-function rebuild.
