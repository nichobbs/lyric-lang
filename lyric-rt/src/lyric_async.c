/* lyric_async.c — async scheduler (Phase 2).
 *
 * Phase 1 emits diagnostic N0099 for `async func` on --target native, so
 * no runtime support is needed yet.  This translation unit exists so the
 * archive layout is stable when the Phase 2 scheduler lands
 * (native/plan/06-async-design.md); it intentionally defines nothing.
 */
typedef int lyric_async_translation_unit_is_not_empty;
