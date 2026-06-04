# 04 — ARC Design

Automatic Reference Counting (ARC) is the memory management strategy for the
native backend. This document specifies the object header layout, retain/release
insertion rules, the `lyric-rt` runtime library, weak references, and the cycle
policy.

---

## Object header

Every heap-allocated Lyric value begins with a two-word header:

```c
// lyric-rt/include/lyric_rt.h
typedef struct {
    _Atomic int rc;        // reference count; 1 = one owner; 0 = dead
    void (*dtor)(void*);   // destructor; called when rc reaches 0; may be null
} LyricObjectHeader;
```

```llvm
; LLVM IR:
; The header is embedded as the first two fields of every heap-struct type.
; No separate allocation — one contiguous block per object.
; Header offset = 0, so (void*)obj == (LyricObjectHeader*)obj.
```

The destructor is called with the object pointer as its sole argument. It must:
1. Release (decrement RC) any reference-typed fields it owns.
2. NOT free the object itself — `lyric_release` calls `free` after the destructor.

---

## `lyric-rt` implementation

### `lyric_alloc`

```c
void* lyric_alloc(uint64_t size) {
    void* p = malloc((size_t)size);
    if (!p) {
        fputs("lyric: out of memory\n", stderr);
        abort();
    }
    return p;
}
```

The compiler never calls `malloc` directly. All heap allocation goes through
`lyric_alloc` so that Phase 2 can swap in a custom allocator.

### `lyric_retain`

```c
void lyric_retain(void* obj) {
    if (!obj) return;
    LyricObjectHeader* h = (LyricObjectHeader*)obj;
    atomic_fetch_add_explicit(&h->rc, 1, memory_order_relaxed);
}
```

Memory order: `relaxed` is sufficient for retain because a retain can only happen
when the caller already holds a strong reference, which implies the object is alive.

### `lyric_release`

```c
void lyric_release(void* obj) {
    if (!obj) return;
    LyricObjectHeader* h = (LyricObjectHeader*)obj;
    if (atomic_fetch_sub_explicit(&h->rc, 1, memory_order_release) == 1) {
        atomic_thread_fence(memory_order_acquire);
        if (h->dtor) h->dtor(obj);
        free(obj);
    }
}
```

Memory orders: the `release` decrement publishes all prior writes; the `acquire`
fence on reaching zero ensures all prior writes (from other threads) are visible
before the destructor runs. This is the standard lock-free RC pattern.

### `lyric_panic_msg`

```c
_Noreturn void lyric_panic_msg(const char* msg, const char* file, int32_t line) {
    fprintf(stderr, "lyric panic at %s:%d: %s\n", file, line, msg);
    fflush(stderr);
    abort();
}
```

### Static object sentinel

Objects with `rc = INT32_MAX` (0x7FFFFFFF) are static (never freed). `lyric_retain`
and `lyric_release` must check for this sentinel and skip the atomic op:

```c
void lyric_retain(void* obj) {
    if (!obj) return;
    LyricObjectHeader* h = (LyricObjectHeader*)obj;
    int current = atomic_load_explicit(&h->rc, memory_order_relaxed);
    if (current == INT32_MAX) return;   // static object
    atomic_fetch_add_explicit(&h->rc, 1, memory_order_relaxed);
}

void lyric_release(void* obj) {
    if (!obj) return;
    LyricObjectHeader* h = (LyricObjectHeader*)obj;
    int current = atomic_load_explicit(&h->rc, memory_order_relaxed);
    if (current == INT32_MAX) return;   // static object
    if (atomic_fetch_sub_explicit(&h->rc, 1, memory_order_release) == 1) {
        atomic_thread_fence(memory_order_acquire);
        if (h->dtor) h->dtor(obj);
        free(obj);
    }
}
```

---

## ARC insertion rules for the codegen

The codegen (`Llvm.Arc`) is responsible for inserting retain and release calls at
the correct points. These are the invariants:

### Rule 1: Ownership at construction

When a heap-allocated object is created (`lyric_alloc` + init), its rc is set to
**1** inline (not via `lyric_retain`). The constructing scope is the initial owner.

### Rule 2: Assignment retains

When a reference-typed value is written to a heap location (field store, list
push, etc.), the value is **retained** before the store:

```llvm
; Storing a String into a record field:
call void @lyric_retain(i8* %str_as_i8ptr)
store %LyricString* %str_val, %LyricString** %field_ptr
```

### Rule 3: Overwrite releases old

When a mutable reference-typed location is overwritten, the **old value is
released** before the new value is retained:

```llvm
; Replacing an existing field value:
%old = load %LyricString*, %LyricString** %field_ptr
call void @lyric_retain(i8* bitcast(%LyricString* %new to i8*))
store %LyricString* %new, %LyricString** %field_ptr
call void @lyric_release(i8* bitcast(%LyricString* %old to i8*))
```

### Rule 4: Local variable lifetime

A local variable binding (`val x = expr`) that holds a reference-typed value:
- The value is **NOT additionally retained** at binding time (it carries rc=1
  from its constructor, or was already retained when passed to the current scope).
- The local is **released** at the end of the scope in which it is declared
  (the `}` that closes the binding's block), unless it was moved/returned first.

```llvm
; val x: String = someFunc()   → result carries rc from callee
; ...use x...
; end of scope:
call void @lyric_release(i8* %x_as_i8ptr)
```

### Rule 5: Function argument passing (borrow)

Arguments passed to a function by the default `in` mode are **borrows** — the
caller retains ownership. The callee does NOT retain on entry or release on exit
for `in` parameters.

The caller guarantees the argument is alive for the duration of the call (which
is trivially true for synchronous functions — the callee returns before the
caller's scope ends).

### Rule 6: Return value transfers ownership

A function returning a heap-allocated value transfers ownership to the caller.
The returned value's rc is **not incremented** — the callee relinquishes its rc
to the caller. The callee must NOT release the returned value.

```llvm
; Returning a locally-constructed string:
%s = call i8* @lyric_alloc(i64 ...)
; ... initialize s with rc=1 ...
ret i8* %s    ; caller now owns the rc=1 object
```

### Rule 7: Destructor composition

The synthesised destructor for a record/union/closure:
1. For each **reference-typed field** the object owns: call `lyric_release(field)`.
2. For each **closure capture** the object owns: call `lyric_release(capture)`.
3. For `List[T]` where T is a reference type: iterate all elements, call
   `lyric_release` on each.
4. Do NOT free `self` — `lyric_release` does that.

---

### Rule 8: Interface fat pointer values

An interface fat pointer (`%Lyric.IAnimal = type { i8*, vtable* }`) is a
**value type** — it has no ARC header and is never heap-allocated. However, the
`i8* obj_ptr` field inside it points to an ARC-managed heap object. The
codegen must retain and release that underlying object wherever the fat pointer
is created, copied, or dropped:

1. **Upcast (object → interface):** When a concrete object `Dog*` is upcast to
   `IAnimal`, retain the underlying object and store its pointer in the fat
   pointer's `obj_ptr` slot. The fat pointer now co-owns the object.

   ```llvm
   call void @lyric_retain(i8* %dog_as_i8)   ; fat pointer takes ownership
   %fat.obj  = insertvalue %Lyric.IAnimal undef, i8* %dog_as_i8, 0
   %fat.vtbl = insertvalue %Lyric.IAnimal %fat.obj, %Lyric.IAnimal.vtable* @Lyric.Dog.IAnimal.vtable, 1
   ```

2. **Fat pointer copy (assignment / store / pass by value):** When a fat
   pointer value is assigned to a local, stored into a field, or passed to a
   function, retain the `obj_ptr` of the source:

   ```llvm
   %obj = extractvalue %Lyric.IAnimal %fat, 0
   call void @lyric_retain(i8* %obj)   ; new owner
   ```

3. **Fat pointer drop (local out of scope / field overwritten):** Release the
   `obj_ptr` of the fat pointer being dropped:

   ```llvm
   %obj = extractvalue %Lyric.IAnimal %fat, 0
   call void @lyric_release(i8* %obj)
   ```

4. **Return:** A function returning an interface value retains the `obj_ptr`
   before returning, consistent with Rule 6 (return transfers ownership). The
   caller is responsible for releasing it when done.

The fat pointer struct itself is never passed to `lyric_retain` or
`lyric_release` — only the embedded `obj_ptr` is. Rule 7 (destructor
composition) does not apply to fat pointer values; Rule 8 supplies the
complete ARC protocol for them.

---

## ARC optimisation (Phase 2)

In Phase 1, retain/release calls are emitted according to the rules above without
any elimination. This is correct but not optimal — many retain/release pairs
cancel each other out.

Phase 2 will add:

1. **LLVM function attributes** on `lyric_retain`/`lyric_release`:
   - `nounwind`, `willreturn`
   - `memory(argmem: readwrite)` — only accesses the argument's memory
   These allow the LLVM optimizer to reason about them without needing a
   custom pass.

2. **A Lyric-specific ARC optimization pass** (an LLVM `FunctionPass`) that:
   - Finds retain/release pairs that are balanced on every path and elides them.
   - Moves retains as late as possible, releases as early as possible.
   - Eliminates retains entirely for objects that are proven stack-confined.

---

## Weak references: `NativeWeak[T]`

`NativeWeak[T]` is a non-owning pointer. It stores the raw pointer without
incrementing RC. The object it points to may be freed while the weak reference
is held — this is expected behaviour.

### `upgrade()` implementation

```lyric
// Conceptual implementation (lyric-compiler side synthesises this):
func upgrade(w: NativeWeak[T]): Option[T] {
  // Raw: attempt to atomically increment rc only if > 0
  // If the object was freed, rc = 0, upgrade returns None
  // If alive, rc is incremented (caller now holds a strong ref), returns Some
}
```

The actual LLVM IR:

```llvm
; NativeWeak[T].upgrade():
;   %raw_ptr = load the stored raw pointer
;   %rc_ptr = bitcast %raw_ptr to i32*
;   loop:
;     %old_rc = load atomic i32, i32* %rc_ptr seq_cst
;     %alive = icmp sgt i32 %old_rc, 0
;     br i1 %alive, label %try_retain, label %return_none
;   try_retain:
;     %new_rc = add i32 %old_rc, 1
;     %success = cmpxchg i32* %rc_ptr, i32 %old_rc, i32 %new_rc seq_cst seq_cst
;     br i1 %success.1, label %return_some, label %loop
;   return_some:
;     ; Construct Some(%raw_ptr cast to T*)
;   return_none:
;     ; Return None
```

The `cmpxchg` ensures atomicity: we increment RC only if it hasn't changed since
we read it, preventing the case where another thread decremented it to 0 between
our check and our retain.

### Future: static cycle prevention

When the mode checker gains a cycle-reachability analysis, it will detect when
a type T can form a strong-reference cycle through its fields. The error message
will suggest replacing the back-edge field with `NativeWeak[T]`. This is purely
a compile-time check; no runtime change is needed.

---

## String operations in `lyric-rt`

```c
// lyric-rt/src/lyric_string.c

LyricString* lyric_string_from_literal(const uint8_t* data, int64_t len) {
    // Allocates header + len bytes
    // rc = 1, dtor = lyric_string_dtor
    // copies data bytes inline
}

LyricString* lyric_string_concat(LyricString* a, LyricString* b) {
    // Allocates new string of len a->len + b->len
    // Copies a's data then b's data
    // rc = 1; does NOT release a or b
}

int64_t lyric_string_len(LyricString* s) { return s->len; }

uint8_t lyric_string_byte_at(LyricString* s, int64_t idx) {
    // bounds check, lyric_panic_msg on out-of-bounds
}

void lyric_string_dtor(void* obj) {
    // No reference fields to release. The data is inline.
    // lyric_release will call free(obj) after this.
}
```
