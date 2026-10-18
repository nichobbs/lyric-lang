# Component shape: concurrent calls into one instance (D184 slice A3)

Async exports of a `--shape component` build may now overlap in one component
instance. In A1 and A2 a second call trapped while one was in flight; it now
runs, and each call completes with its own result.

- **Per-call records.** A call is a heap record in a growable table, and its
  callbacks find it through `context.get` slot 0. The async shim still
  snapshots its lowered result into its own record
  (`lyric_cabi_async_done`), because any scheduler turn can complete any
  call's task.
- **Wake-up futures.** Each call creates a private unit future
  (`[future-new-unit]`), parks a `future.read` on it, and joins the read end
  to its own waitable set. When a task completes outside its own call's turn
  (in another call's turn, or inside a synchronous export's blocking wait),
  `lyric_cabi_async_done` writes that call's future, so the call wakes,
  calls `task.return` and exits.
  - On exit a call retires the future: it writes it if nothing did, then
    takes the completed read through `future.cancel-read`.
  - The order matters. Dropping a future's writable end traps unless it was
    written, and its read end stays mid-copy until its event is delivered
    (checked against `definitions.py`).
- **Home call.** Outstanding subtasks (the WASI 0.3 timer and promise imports)
  live in the set of one live call, the home call. When the home call exits,
  they move to another live call's set, which that call is already waiting
  on, or out of any set until the next call starts.

D184 item 6 now describes this mechanism, and its status is "implemented".

The component suite gains two tests:

- **jco.** Three overlapping `later` calls finish in about the longest one's
  time and each returns its own value. Two `fetchTwice` calls run at once,
  their host imports finishing out of order. A sync export answers while async
  calls are in flight. A sleeper and an importer run together, and the
  instance keeps working afterwards.
- **wasmtime.** A WAT consumer component async-lowers `later` three times at
  once and returns `r1 * 100 + r2 * 10 + r3`. It is composed with the Lyric
  component by `wac plug` and run with `wasmtime run --invoke 'run()'`, which
  prints `234`. The wasm CI lane pins wac 0.12.0 (SHA-256 checked) for this.
