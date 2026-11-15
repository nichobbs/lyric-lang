# Native backend on TIR: sleep and fd-wait leaves (docs/70 phase 4a, D520 slice 28)

A coroutine that calls `sleepMillis`, `waitFd` or `waitFd2` lowers from TIR with the AST path's
reactor calls and suspend point instead of falling back. Process capture and the socket twins
return `Result` and wait for generic unions (3c). `native-via-tir/async.l` lowers 9 of 9.
