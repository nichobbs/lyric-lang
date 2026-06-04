# 03 — Type Mapping

Authoritative mapping from every Lyric surface type to its LLVM IR representation.
All codegen agents must use this document as the source of truth. If a mapping is
missing or ambiguous, file an issue before inventing a representation.

---

## Scalar types (no heap allocation, no ARC)

| Lyric type | LLVM IR type | Notes |
|---|---|---|
| `Int` | `i32` | 32-bit signed integer (Lyric's default integer) |
| `Long` | `i64` | 64-bit signed integer |
| `Float` | `double` | 64-bit IEEE 754 double |
| `Bool` | `i1` | 1-bit; `true` = 1, `false` = 0 |
| `Unit` | `void` (return) / absent (field) | Functions returning Unit emit `ret void` |
| `Byte` | `i8` | Unsigned 8-bit (for `slice[Byte]`, I/O buffers) |
| `Char` | `i32` | Unicode scalar value; NOT a character in a string buffer |

**Note on `Char`:** Lyric's `Char` represents a Unicode scalar value (U+0000 to
U+10FFFF). It is stored as `i32`. It is NOT a UTF-8 code unit — `String` stores
UTF-8 internally, and converting between `Char` and a position in a string
requires UTF-8 iteration, not byte indexing.

---

## Heap-allocated types (all carry an ARC header)

All heap-allocated values have the same two-word header at offset 0:

```llvm
; Object header embedded at the start of every heap-allocated Lyric value:
; [0]: i32  — reference count (atomic)
; [1]: i8*  — destructor function pointer (void (*)(void*))
```

---

## String

```llvm
%LyricString = type { i32, i8*, i64, i64 }
; [0] i32  rc
; [1] i8*  dtor (always @lyric_string_dtor)
; [2] i64  len  (byte count, not character count)
; [3] i64  cap  (allocated bytes for data, excludes header)
; [4..] UTF-8 data follows inline (allocated as one contiguous block)
```

Lyric values of type `String` are `%LyricString*` — a pointer to this struct.

**String literal lowering:**

```llvm
; For "hello":
@.strobj.0 = private unnamed_addr constant { i32, i8*, i64, i64, [6 x i8] } {
  i32 2147483647,   ; INT32_MAX — saturated rc, never freed
  i8* null,         ; no destructor (static allocation)
  i64 5,            ; len (byte count, excluding null)
  i64 6,            ; cap (allocated bytes, including null terminator)
  [6 x i8] c"hello\00"
}, align 8

; At use site, bitcast to %LyricString*:
%str = bitcast { i32, i8*, i64, i64, [6 x i8] }* @.strobj.0 to %LyricString*
```

Because static strings and heap strings are the same layout, call sites that
accept `%LyricString*` work transparently with both.

---

## Record types

A record `record Point { x: Int; y: Int }` lowers to:

```llvm
%Lyric.Point = type { i32, i8*, i32, i32 }
; [0] i32  rc
; [1] i8*  dtor  (@Lyric.Point.__dtor)
; [2] i32  x
; [3] i32  y
```

Fields appear in declaration order, preceded by the two header words.

**Reference-typed fields** (fields whose type is heap-allocated) are stored as
pointers. When the record is constructed, the ARC of each reference-typed field
argument is incremented. When the record is destroyed (dtor), each reference-typed
field is released.

**Constructor call** `Point(x = 3, y = 4)`:

```llvm
; 1. Allocate
%raw = call i8* @lyric_alloc(i64 16)   ; sizeof(%Lyric.Point)
%obj = bitcast i8* %raw to %Lyric.Point*
; 2. Write header
%rc_ptr  = getelementptr inbounds %Lyric.Point, %Lyric.Point* %obj, i32 0, i32 0
store i32 1, i32* %rc_ptr
%dtor_ptr = getelementptr inbounds %Lyric.Point, %Lyric.Point* %obj, i32 0, i32 1
store i8* bitcast (void (%Lyric.Point*)* @Lyric.Point.__dtor to i8*), i8** %dtor_ptr
; 3. Write fields
%x_ptr = getelementptr inbounds %Lyric.Point, %Lyric.Point* %obj, i32 0, i32 2
store i32 3, i32* %x_ptr
%y_ptr = getelementptr inbounds %Lyric.Point, %Lyric.Point* %obj, i32 0, i32 3
store i32 4, i32* %y_ptr
; 4. result = %obj (rc=1, caller owns it)
```

---

## Union types (tagged in-place struct)

A union `union Shape { case Circle(radius: Float) | case Rect(w: Float, h: Float) }`:

Payload sizes:
- `Circle`: 1 × `double` = 8 bytes
- `Rect`: 2 × `double` = 16 bytes
- max payload = 16 bytes

```llvm
%Lyric.Shape = type { i32, i8*, i32, [16 x i8] }
; [0] i32        rc
; [1] i8*        dtor  (@Lyric.Shape.__dtor)
; [2] i32        discriminant: 0=Circle, 1=Rect
; [3] [16 x i8]  payload (max_payload bytes, untyped at this level)
```

Discriminant values are assigned in declaration order starting from 0.

**Accessing case payload:** The payload is accessed by bitcasting the payload
address to the concrete case struct pointer:

```llvm
; Getting Circle's radius from a Shape* %s:
%disc_ptr = getelementptr inbounds %Lyric.Shape, %Lyric.Shape* %s, i32 0, i32 2
%disc = load i32, i32* %disc_ptr
; switch on disc:
;   0 → Circle case:
%pay_ptr = getelementptr inbounds %Lyric.Shape, %Lyric.Shape* %s, i32 0, i32 3
%circ_ptr = bitcast [16 x i8]* %pay_ptr to { double }*
%radius_ptr = getelementptr inbounds { double }, { double }* %circ_ptr, i32 0, i32 0
%radius = load double, double* %radius_ptr
```

**Destructor dispatch:** The dtor checks the discriminant and releases any
reference-typed fields in the active case:

```llvm
define private void @Lyric.Shape.__dtor(%Lyric.Shape* %self) {
  %disc_ptr = getelementptr inbounds %Lyric.Shape, %Lyric.Shape* %self, i32 0, i32 2
  %disc = load i32, i32* %disc_ptr
  switch i32 %disc, label %done [
    i32 0, label %case_circle
    i32 1, label %case_rect
  ]
case_circle:
  ; Circle(radius: Float) — Float is scalar, nothing to release
  br label %done
case_rect:
  ; Rect(w: Float, h: Float) — both scalar, nothing to release
  br label %done
done:
  ret void
}
```

**Enum types** (no payload) lower to bare `i32` values — no heap allocation,
no ARC header.

---

## Distinct types

A distinct type `type UserId = Int` lowers to a thin struct wrapper:

```llvm
%Lyric.UserId = type { i32 }
; [0] i32  value
; No ARC header — distinct types wrapping scalar types are value types (stack-allocated)
```

Distinct types wrapping **reference types** (e.g., `type MyString = String`)
carry an ARC header:

```llvm
%Lyric.MyString = type { i32, i8*, i8* }
; [0] i32  rc
; [1] i8*  dtor
; [2] i8*  value (the wrapped %LyricString*)
```

---

## Range subtypes

`type Age = Int range 0..=150` lowers identically to a distinct type wrapping
the base primitive:

```llvm
%Lyric.Age = type { i32 }  ; same as distinct Int
```

The range check occurs at construction time (a `From`/`TryFrom` static function),
not in the type itself. See the emitter for bounds-check codegen.

---

## Opaque types

Lowers identically to a record type. The opacity is enforced by the type checker
and module system, not by the runtime layout.

---

## Closures

A closure is a heap-allocated struct containing:
1. The ARC header
2. A function pointer (the closure body)
3. One slot per captured variable (with ARC retain for reference-typed captures)

```
closure type `func(Int): String` that captures `prefix: String`:

%Lyric.Closure_0 = type { i32, i8*, i8*, %LyricString* }
; [0] i32           rc
; [1] i8*           dtor
; [2] i8*           fn_ptr  (points to @closure_body_0(i8* env, i32 arg): i8*)
; [3] %LyricString* prefix (retained on creation, released in dtor)
```

All closures share the same calling convention: **the first argument is always
`i8* env`** — a pointer to the closure struct (cast to `i8*` for generality).
Named functions that need to be passed as first-class values get a zero-capture
wrapper closure allocated on the heap.

**Function type fat pointer** (`func(Int): String` as a value):

```llvm
%LyricFn_Int_String = type { i32, i8*, i8*, i8* }
; [0] i32  rc
; [1] i8*  dtor
; [2] i8*  fn_ptr (void (*)(i8* env, <args>))
; [3] i8*  env_ptr (the captured environment struct, or null for plain fn refs)
```

At a call site `f(42)`:

```llvm
%fn_ptr_loc = getelementptr inbounds %LyricFn_Int_String, ..., 0, 2
%fn_ptr     = load i8*, i8** %fn_ptr_loc
%env_ptr_loc = getelementptr ..., 0, 3
%env_ptr    = load i8*, i8** %env_ptr_loc
%typed_fn   = bitcast i8* %fn_ptr to i8* (i8*, i32)*
%result     = call i8* %typed_fn(i8* %env_ptr, i32 42)
```

---

## Interface dispatch (vtable)

An interface `IAnimal { func speak(): String }` implemented by `record Dog` lowers
to a vtable-based dispatch:

```llvm
; Vtable type for IAnimal:
%Lyric.IAnimal.vtable = type { i8* }    ; one slot per interface method

; Concrete vtable for Dog implementing IAnimal:
@Lyric.Dog.IAnimal.vtable = constant %Lyric.IAnimal.vtable {
  i8* bitcast (i8* (%Lyric.Dog*)* @Lyric.Dog.speak to i8*)
}

; Interface fat pointer (the value when you have an IAnimal):
%Lyric.IAnimal = type { i8*, %Lyric.IAnimal.vtable* }
; [0] i8*                   obj_ptr (the concrete object, cast to i8*)
; [1] %Lyric.IAnimal.vtable* vtable_ptr
```

Interface dispatch:

```llvm
%speak_fn_slot = getelementptr %Lyric.IAnimal.vtable, ..., 0, 0
%speak_fn_raw  = load i8*, i8** %speak_fn_slot
%speak_fn      = bitcast i8* %speak_fn_raw to i8* (i8*)*
%result        = call i8* %speak_fn(i8* %obj_ptr)
```

---

## Generics (after monomorphization)

`Lyric.Mono` produces concrete types with mangled names:

- `List[Int]` → `Lyric.List__Int`
- `Map[String, Int]` → `Lyric.Map__String__Int`
- `Option[Point]` → `Lyric.Option__Point`

These map to their concrete LLVM struct types. No erasure, no boxing.

---

## NativePtr[T]

```llvm
; NativePtr[Int] → i32*
; NativePtr[Byte] → i8*
; NativePtr[NativePtr[Byte]] → i8**
```

`NativePtr[T]` is a raw, unmanaged pointer. It does NOT have an ARC header.
It is only valid in `_kernel_native/` files and `@unsafe_ffi`-annotated functions.
It is never retained or released.

---

## NativeWeak[T]

```llvm
%LyricWeak_T = type { i8* }
; [0] i8* raw pointer (NOT retained; may point to freed memory)
```

`NativeWeak[T]` stores the raw pointer without incrementing RC. `upgrade()` uses a
`cmpxchg` loop to atomically increment the RC only if it is still non-zero, so no
TOCTOU window exists between the liveness check and the retain. The full correct
implementation is specified in `04-arc-design.md` §NativeWeak upgrade algorithm.

---

## Tuples

Anonymous tuple `(Int, String)` lowers to a named struct (the name is mangled
from field types):

```llvm
%Lyric.Tuple2_Int_String = type { i32, i8*, i32, %LyricString* }
; [0] i32           rc
; [1] i8*           dtor
; [2] i32           _0 (first element)
; [3] %LyricString* _1 (second element, retained in constructor)
```

---

## `slice[T]` and `List[T]`

```llvm
; slice[Byte] (borrowed fat pointer, no ARC):
%Lyric.Slice_Byte = type { i8*, i64 }
; [0] i8*  ptr
; [1] i64  len (element count)

; List[Int] (RC heap, mutable):
%Lyric.List__Int = type { i32, i8*, i32*, i64, i64 }
; [0] i32   rc
; [1] i8*   dtor
; [2] i32*  data (heap-allocated array of Int)
; [3] i64   len
; [4] i64   cap
```

`List[T]` where T is a reference type (e.g., `List[String]`):
the `data` array stores `%LyricString*` pointers. Push retains, pop releases.
The dtor iterates all `len` elements and releases each.

---

## Protected types

`protected type Counter { val: Int; ... }` lowers to:

```llvm
%Lyric.Counter = type { i32, i8*, [40 x i8], i32 }
; [0] i32        rc
; [1] i8*        dtor
; [2] [40 x i8]  mutex (pthread_mutex_t, 40 bytes on Linux x86-64)
; [3] i32        val
```

The mutex is embedded inline. `lyric-rt` provides `lyric_mutex_init`,
`lyric_mutex_lock`, `lyric_mutex_unlock` wrappers around `pthread_mutex_*`.

`pthread_mutex_t` size is platform-specific (40 bytes on Linux x86-64, 56 on
macOS). The codegen uses a compile-time constant from the target triple.
