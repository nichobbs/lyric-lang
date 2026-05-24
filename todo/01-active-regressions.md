# Tier 1 — Active Regressions on Main

## Issues
- **#1120** — Self-hosted MSIL: restore Band-2 regressions deleted in PR #927
- **#1122** — REQUIRED: cross-package `Result[Option[T]]` isinst bug in `emitProject` needs tracked issue with fix plan
- **#733** — CRITICAL: Storage library silently broken (`storage_kernel.l` stubs unreachable from `StorageHost.fs`)

## Prompt

You are working on the **lyric-lang** repository — a safety-oriented application language targeting .NET and JVM, implemented in a self-hosted Lyric compiler. Read `CLAUDE.md` fully before doing anything else; it governs every decision about F# vs Lyric, production-readiness standards, PR hygiene, and branch discipline.

Your task is to fix all three active regression issues listed above to production-ready completion with no shortcuts, no regressions, and full test coverage. Work on a new branch named `fix/tier1-active-regressions`. Open a **draft** PR as soon as you have your first commit; keep it draft until every acceptance criterion below is green. Rebase onto `main` at the start of each work session and before marking the PR ready for review. Push after every coherent batch of changes.

No new F# code containing domain logic is acceptable. F# changes are only permitted for thin bootstrap shims (`@externTarget` wiring, `bootstrap/tests/`) and only where there is no Lyric equivalent. Every substantive fix goes in `.l` files.

---

### Issue #1120 — Self-hosted MSIL Band-2 regressions

**Context:** PR #927 introduced three regressions in `lyric-compiler/msil/codegen.l` that are still present on `main`. Closing the review-finding issues (#1036–#1038) did NOT necessarily land the fixes — verify current code state before assuming anything is done.

**Fix 1 — Restore `constEnv` scan in `isLiteralI4ExprMsil`:**

`lyric-compiler/msil/codegen.l` — the function `isLiteralI4ExprMsil` (around the pre-scan area) no longer handles `EPath`. The original `isLiteralI4ExprMsilWithEnv` carried a `constEnv: Map[String, Bool]` that tracked which `val` names had literal initialisers in source order, so `val b = a` (where `a = 7`) was also recognised as literal and no phantom `.cctor` MethodDef row was allocated.

Without this, every `val second = first` (where `first` is a literal) causes `hasValCctor = true`, allocates a phantom `.cctor` token in `addPackageTokens`, and shifts every subsequent `IFunc` token by one. All intra-package calls dispatch to the wrong method at runtime — a silent, hard-to-diagnose correctness failure.

Restore the `constEnv`-threaded scan as a separate pre-pass over each function body. The scan runs once in source order before `addPackageTokens`. Restore the `shm_module_const_chain` bridge test in `bootstrap/tests/Lyric.Cli.Tests/SelfHostedMsilBridgeTests.fs` and the corresponding `.l` fixture.

**Fix 2 — Restore `rewriteProceedMsil` AST traversal:**

`lyric-compiler/msil/codegen.l` — `rewriteProceedMsil` is currently a stub that returns the body unchanged. The full AST-traversing implementation (`rewriteProceedBlockMsil`, `rewriteProceedStmtMsil`, `rewriteProceedExprMsil`) must be restored. Without it, `proceed()` calls inside aspect `around` bodies are silently dropped — the wrapped function never executes.

Reference: the F# bootstrap path has the correct implementation in `bootstrap/src/Lyric.Emitter/Weaver.fs` (the `rewriteProceed` family). Port it faithfully into the self-hosted Lyric implementation. Do not touch `Weaver.fs`.

Restore the `shm_aspect_proceed_wrap` bridge test.

**Fix 3 — Restore all 11 deleted bridge tests:**

These tests were deleted from `SelfHostedMsilBridgeTests.fs` during #927 with no justification. Restore every one, with its corresponding `.l` fixture:

- `shm_trailing_int_literal`
- `shm_trailing_only_zero`
- `shm_if_else_chain`
- `shm_match_int_with_wildcard`
- `shm_recursion_factorial`
- `shm_string_concat`
- `shm_int_arithmetic`
- `shm_module_const_chain` (restored by Fix 1)
- `shm_fat_header_alignment`
- `shm_fat_header_three_println`
- `shm_aspect_proceed_wrap` (restored by Fix 2)

Order: fix the underlying code issues first, then restore the tests that were failing because of them, then restore the smoke tests that should have always passed.

---

### Issue #1122 — Cross-package `Result[Option[T]]` isinst emitter bug

**Context:** The `emitProject` path in the self-hosted compiler cannot resolve the generic type argument for a nullary-case `isinst` check when a `Result[Option[T]]` or `Option[T]` value crosses a package boundary. Specifically, when an early-return `Ok(None)` site is matched in a downstream `case None ->` arm, the arm silently falls through. Three session test files (`lyric-session/tests/`) work around this with `isOk`/`isNone`/`unwrapOr` helpers from `Std.Core` instead of direct patterns.

**What to do:**

1. **File a new GitHub issue** (via the GitHub MCP) for the root emitter bug: "Self-hosted emitter: cross-package `Result[Option[T]]` nullary-case isinst cannot resolve generic type arg in `emitProject`". Include the reproduction pattern, the affected files, and a concrete remediation plan (what `isinst` token generation needs to change).

2. **Fix the root bug** in the self-hosted emitter (`lyric-compiler/msil/` or wherever `emitProject` cross-package `isinst` is generated). The fix must allow `case None ->`, `case Ok(Some(v)) ->`, etc. to work correctly across package boundaries without helper workarounds.

3. **Update the three session test files** to use direct pattern matching instead of the helper workarounds once the fix lands:
   - `lyric-session/tests/session_fixation_tests.l`
   - `lyric-session/tests/session_store_tests.l`
   - `lyric-session/tests/sensitive_url_tests.l`

4. **Remove the workaround NOTE comments** from those files and the `isOk`/`isErr`/`isSome` import lines that were only there for the workaround.

---

### Issue #733 (storage) — Storage kernel stubs unreachable; replace F# host with native Lyric externs

**Context:** `lyric-storage/src/_kernel/net/storage_kernel.l` declares all storage functions with `@axiom("...")` annotations and `= Err("")` bodies — no `@externTarget` annotations. `bootstrap/src/Lyric.Storage.Host/StorageHost.fs` was added in PR #1010 and implements the actual BCL operations, but the kernel never calls it. Every storage operation silently returns `Err("")`.

**Do not wire to `StorageHost.fs`.** The F# host shim approach is deprecated. Instead, bind directly to the NuGet SDKs and BCL from Lyric using `extern package` and `extern type` declarations, then delete `StorageHost.fs` entirely.

**Implementation — rewrite `storage_kernel.l` using native Lyric externs:**

Replace the current stub bodies with real bindings in `lyric-storage/src/_kernel/net/storage_kernel.l`:

*S3 backend (`@cfg(feature = "s3")`)* — bind via `extern package AWSSDK.S3`:
```lyric
extern package AWSSDK.S3 {
  extern type Amazon.S3.AmazonS3Client {
    func putObject(request: Amazon.S3.Model.PutObjectRequest): Result[Amazon.S3.Model.PutObjectResponse, String]
    func getObject(request: Amazon.S3.Model.GetObjectRequest): Result[Amazon.S3.Model.GetObjectResponse, String]
    func deleteObject(bucket: String, key: String): Result[Unit, String]
    func listObjectsV2(request: Amazon.S3.Model.ListObjectsV2Request): Result[Amazon.S3.Model.ListObjectsV2Response, String]
  }
  extern type Amazon.S3.Model.PutObjectRequest { ... }
  extern type Amazon.S3.Model.GetObjectRequest { ... }
  // ... remaining request/response types
}
```

*Azure Blob backend (`@cfg(feature = "azure_blob")`)* — bind via `extern package Azure.Storage.Blobs`:
```lyric
extern package Azure.Storage.Blobs {
  extern type Azure.Storage.Blobs.BlobServiceClient {
    func GetBlobContainerClient(container: String): Azure.Storage.Blobs.BlobContainerClient
  }
  extern type Azure.Storage.Blobs.BlobContainerClient {
    func GetBlobClient(name: String): Azure.Storage.Blobs.BlobClient
    func GetBlobsAsync(prefix: String): AsyncEnumerable[Azure.Storage.Blobs.Models.BlobItem]
  }
  // ... remaining types
}
```

*Local filesystem backend (`@cfg(feature = "local")`)* — bind BCL `System.IO` directly via `extern type`:
```lyric
extern type System.IO.File {
  static func ReadAllBytes(path: String): slice[Byte]
  static func WriteAllBytes(path: String, data: slice[Byte]): Unit
  static func Delete(path: String): Unit
  static func Exists(path: String): Bool
}
extern type System.IO.Directory {
  static func GetFiles(path: String, pattern: String): slice[String]
  static func CreateDirectory(path: String): Unit
}
```

**Wrap fallible BCL calls in Lyric `try/catch`** inside thin private wrapper functions in `lyric-storage/src/storage.l` (or a `_kernel/net/storage_kernel_try.l` helper) — do NOT use F# for the try/catch. Lyric's `try { } catch (e: Exception) { Err(e.Message) }` pattern is sufficient.

**Fix the two known quality issues in the same pass:**

- **Pagination cursor** (#1012): The local-fs backend must return a meaningful continuation cursor (e.g. the last key seen) when `isTruncated = true`, not `""`. The cursor is passed back on the next call to resume iteration. No infinite-loop pagination.

- **ETag in list results** (#1011): Compute ETags by reading from the `.meta.json` sidecar that `storagePut` writes, not by re-reading file contents. This avoids O(file-size × count) memory on list calls.

**Delete `bootstrap/src/Lyric.Storage.Host/StorageHost.fs`** and remove the project from `Bootstrap.sln` once all `extern package`/`extern type` bindings are in place and tests pass.

After wiring and fixing, add tests in `lyric-storage/tests/storage_tests.l` runnable via `lyric test --manifest lyric-storage/lyric.toml` covering:
- put → get round-trip (local-fs backend)
- delete
- exists (true/false)
- list with prefix filter
- list pagination: second call with the returned cursor returns the next page (no infinite loop)
- ETag consistency between put and list

---

## Acceptance Criteria

- [ ] `shm_module_const_chain` bridge test passes — verifies no phantom `.cctor` from `val b = a` literal chains
- [ ] `shm_aspect_proceed_wrap` bridge test passes — verifies aspect `proceed()` is not silently dropped
- [ ] All 11 deleted bridge tests restored and passing
- [ ] Full `SelfHostedMsilBridgeTests` suite passes with no skipped tests
- [ ] `dotnet run --project bootstrap/tests/Lyric.Emitter.Tests` passes
- [ ] `dotnet run --project bootstrap/tests/Lyric.Cli.Tests` passes
- [ ] Cross-package `Result[Option[T]]` `case None ->` pattern match works correctly (verified by direct-pattern session tests)
- [ ] Session test files use direct `Ok`/`Err`/`Some`/`None` patterns — no `isOk`/`isNone` workaround helpers
- [ ] GitHub issue filed for the cross-package isinst bug with fix plan linked from the session test files
- [ ] `storage_kernel.l` uses `extern package`/`extern type` bindings — no `@externTarget` pointing to F# shims
- [ ] `bootstrap/src/Lyric.Storage.Host/StorageHost.fs` deleted; project removed from `Bootstrap.sln`
- [ ] Storage put/get/delete/exists operations return real results (not `Err("")`)
- [ ] Storage list returns a usable continuation cursor (no infinite-loop pagination)
- [ ] Storage list ETags read from `.meta.json` sidecar, not from re-reading file contents
- [ ] No F# try/catch logic anywhere in storage path; exception wrapping happens in Lyric
- [ ] `lyric test --manifest lyric-storage/lyric.toml` runs and passes
- [ ] No new F# domain logic added anywhere
- [ ] No disabled, skipped, or `Ignore`-attributed tests
- [ ] PR is draft until all criteria above are green; then marked ready for review
- [ ] Branch rebased onto `main` immediately before marking ready
