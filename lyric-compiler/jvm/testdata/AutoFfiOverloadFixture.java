// AutoFfiOverloadFixture.java — fixture class for auto_ffi_jvm_self_test.l's
// instance-method / constructor overload-scoring regression (#6662).
//
// The JDK itself has no INSTANCE method or CONSTRUCTOR that pairs a
// primitive-array overload (`int[]`) with a generic/Object-array overload
// (`Object[]`) on the same name — every such pair the JDK ships
// (`Arrays.copyOf`, `Arrays.hashCode`, …) is a STATIC utility method, already
// covered by the `Arrays.copyOf` regression above. This fixture supplies the
// missing shape directly so the instance-call and constructor-call auto-FFI
// resolution paths (`lowerAutoFfiInstanceCall` / `lowerAutoFfiConstructorCall`
// in lyric-compiler/jvm/codegen/04_calls.l) get real overload-scoring
// coverage, mirroring `Arrays.copyOf`'s static-call shape.
//
// Built by scripts/ci/build-auto-ffi-fixture.sh into a jar consumed via
// LYRIC_FFI_JARS -- see that script and the test file's header for the
// build + run instructions.
package lyric.autoffi.fixture;

public final class AutoFfiOverloadFixture {
  private final String kind;
  private final int sum;

  // Constructor overload set: a `slice[Int]` argument's erased descriptor
  // ([Ljava/lang/Object;) must score higher against `int[]` than against
  // `Object[]` once ffiScoreDescFor's true-element-type hint is consulted --
  // before #6662 this always picked the Object[] overload.
  public AutoFfiOverloadFixture(int[] values) {
    int s = 0;
    for (int v : values) {
      s += v;
    }
    this.sum = s;
    this.kind = "primitive";
  }

  public AutoFfiOverloadFixture(Object[] values) {
    this.sum = -1;
    this.kind = "generic";
  }

  public String kind() {
    return kind;
  }

  public int sum() {
    return sum;
  }

  // Instance-method overload set mirroring the constructor pair above, for
  // lowerAutoFfiInstanceCall's independent argDescs/scoring path.
  public int sumInts(int[] values) {
    int s = 0;
    for (int v : values) {
      s += v;
    }
    return s;
  }

  public int sumInts(Object[] values) {
    return -1;
  }
}
