;; wasmhost_fixture.wat — the component lyric_wasmhost_test.c hosts.
;;
;; Built with `wasm-tools parse` by `make -C lyric-rt test-wasmhost`.  It
;; exercises every path of the shim without a Lyric toolchain:
;;   echo, add          scalar and string arguments and results
;;   identity           every value kind the plugin boundary uses, round-tripped
;;                      through linear memory (more than 16 flat parameters, so
;;                      the record travels by pointer and the core function
;;                      returns the pointer it was given)
;;   ask-host           a host import returning result<string, call-error>
;;   spin, boom, grow   a CPU loop (timeouts), a trap, memory.grow (the limiter)
;;   plugin-type-hints  the union field names and the Map marker (contract §3)
(component
  ;; ── The host import ───────────────────────────────────────────────────
  (import "lyric:test/host-api" (instance $host
    (type $ce0 (variant (case "denied" string) (case "not-granted" string) (case "app" string) (case "stale")))
    (export "call-error" (type $ce (eq $ce0)))
    (type $askty (func (param "question" string) (result (result string (error $ce)))))
    (export "ask" (func (type $askty)))))
  (alias export $host "ask" (func $ask))

  ;; ── Named types for the exports ───────────────────────────────────────
  (type $ce1 (variant (case "denied" string) (case "not-granted" string) (case "app" string) (case "stale")))
  (export $ce "call-error" (type $ce1))
  (type $shape0 (variant (case "circle" f64) (case "named" string) (case "empty")))
  (export $shape "shape" (type $shape0))
  (type $color0 (enum "red" "dark-green"))
  (export $color "color" (type $color0))
  (type $inner0 (record (field "x" s16) (field "y" u16)))
  (export $inner "inner" (type $inner0))
  (type $big0 (record
    (field "name" string)
    (field "count" s64)
    (field "ratio" f64)
    (field "small" f32)
    (field "flag" bool)
    (field "tag" u8)
    (field "id" u64)
    (field "letter" char)
    (field "tags" (list string))
    (field "bytes" (list u8))
    (field "maybe" (option string))
    (field "shape" $shape)
    (field "color" $color)
    (field "pair" (tuple s32 string))
    (field "outcome" (result s32 (error string)))
    (field "attrs" (list (tuple string s32)))
    (field "inner" $inner)
    (field "tiny" s8)
    (field "wide" u32)))
  (export $big "big-record" (type $big0))

  ;; ── Core modules ──────────────────────────────────────────────────────
  (core module $libc
    (memory (export "mem") 1)
    (global $bump (mut i32) (i32.const 4096))
    (func (export "realloc") (param $old i32) (param $oldsz i32) (param $align i32) (param $new i32) (result i32)
      (local $p i32) (local $end i32) (local $have i32)
      ;; p = align_up(bump, align)
      (local.set $p
        (i32.and
          (i32.add (global.get $bump) (i32.sub (local.get $align) (i32.const 1)))
          (i32.xor (i32.sub (local.get $align) (i32.const 1)) (i32.const -1))))
      (local.set $end (i32.add (local.get $p) (local.get $new)))
      (local.set $have (i32.mul (memory.size) (i32.const 65536)))
      (if (i32.gt_u (local.get $end) (local.get $have))
        (then
          (if (i32.eq
                (memory.grow (i32.add (i32.div_u (i32.sub (local.get $end) (local.get $have)) (i32.const 65536)) (i32.const 1)))
                (i32.const -1))
            (then unreachable))))
      (global.set $bump (local.get $end))
      (if (i32.ne (local.get $old) (i32.const 0))
        (then (memory.copy (local.get $p) (local.get $old) (local.get $oldsz))))
      (local.get $p)))
  (core instance $libc (instantiate $libc))
  (alias core export $libc "mem" (core memory $mem))
  (alias core export $libc "realloc" (core func $realloc))
  (core func $ask_lowered (canon lower (func $ask) (memory $mem) (realloc $realloc) string-encoding=utf8))

  (core module $main
    (import "env" "mem" (memory 1))
    (import "env" "ask" (func $ask (param i32 i32 i32)))
    ;; Return areas: 32 (echo/hints, 8 bytes), 48 (ask-host, 16 bytes).
    (data (i32.const 1024) "{\"exports\":{\"identity\":{\"params\":[{\"record\":{\"attrs\":{\"map\":null}}}],\"result\":{\"record\":{\"shape\":{\"variant\":{\"circle\":{\"field\":\"radius\",\"of\":null},\"named\":{\"field\":\"label\",\"of\":null}}},\"attrs\":{\"map\":null}}}},\"ask-host\":{\"params\":[null],\"result\":{\"result\":{\"ok\":null,\"err\":{\"variant\":{\"denied\":{\"field\":\"reason\"},\"not-granted\":{\"field\":\"capability\"},\"app\":{\"field\":\"error\"}}}}}}},\"imports\":{\"lyric:test/host-api#ask\":{\"params\":[null],\"result\":null}}}")
    (func (export "hints") (result i32)
      (i32.store (i32.const 32) (i32.const 1024))
      (i32.store (i32.const 36) (i32.const 450))
      (i32.const 32))
    (func (export "echo") (param i32 i32) (result i32)
      (i32.store (i32.const 32) (local.get 0))
      (i32.store (i32.const 36) (local.get 1))
      (i32.const 32))
    (func (export "add") (param i32 i32) (result i32)
      (i32.add (local.get 0) (local.get 1)))
    (func (export "identity") (param i32) (result i32)
      (local.get 0))
    (func (export "ask-host") (param i32 i32) (result i32)
      (call $ask (local.get 0) (local.get 1) (i32.const 48))
      (i32.const 48))
    (func (export "spin")
      (loop $l (br $l)))
    (func (export "boom")
      unreachable)
    (func (export "grow") (param i32) (result i32)
      (memory.grow (local.get 0))))
  (core instance $main (instantiate $main
    (with "env" (instance (export "mem" (memory $mem)) (export "ask" (func $ask_lowered))))))

  ;; ── Exports ───────────────────────────────────────────────────────────
  (func $hints (result string)
    (canon lift (core func $main "hints") (memory $mem) (realloc $realloc) string-encoding=utf8))
  (export "plugin-type-hints" (func $hints))
  (func $echo (param "text" string) (result string)
    (canon lift (core func $main "echo") (memory $mem) (realloc $realloc) string-encoding=utf8))
  (export "echo" (func $echo))
  (func $add (param "left-side" s32) (param "right-side" s32) (result s32)
    (canon lift (core func $main "add")))
  (export "add" (func $add))
  (func $identity (param "value" $big) (result $big)
    (canon lift (core func $main "identity") (memory $mem) (realloc $realloc) string-encoding=utf8))
  (export "identity" (func $identity))
  (func $askhost (param "question" string) (result (result string (error $ce)))
    (canon lift (core func $main "ask-host") (memory $mem) (realloc $realloc) string-encoding=utf8))
  (export "ask-host" (func $askhost))
  (func $spin (canon lift (core func $main "spin")))
  (export "spin" (func $spin))
  (func $boom (canon lift (core func $main "boom")))
  (export "boom" (func $boom))
  (func $grow (param "pages" u32) (result s32)
    (canon lift (core func $main "grow")))
  (export "grow" (func $grow)))
