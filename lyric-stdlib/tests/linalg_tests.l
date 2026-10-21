//! stdlib/tests/linalg_tests.l - Tests for Std.Linalg (docs/67 §4.6).
//!
//! Float results are compared within a small tolerance. The same file runs on
//! every target: `lyric test [--target dotnet|jvm|native] lyric-stdlib/tests/linalg_tests.l`.
@test_module
package Std.Linalg.Tests

import Std.Core
import Std.Linalg
import Std.Testing

func near(a: in Float, b: in Float): Bool {
  val d = a - b
  d < 0.0001f32 and d > -0.0001f32
}

func nearVec3(a: in Vec3, b: in Vec3): Bool {
  near(a.x, b.x) and near(a.y, b.y) and near(a.z, b.z)
}

func nearMat4(a: in Mat4, b: in Mat4): Bool {
  var i = 0
  var ok = true
  while i < 16 {
    if not near(a.m[i], b.m[i]) {
      ok = false
    }
    i = i + 1
  }
  ok
}

func unwrapMat4(o: in Option[Mat4]): Mat4 {
  match o {
    case Some(m) -> m
    case None -> Mat4.identity()
  }
}

test "vector derive arithmetic is component-wise" {
  val a = Vec3(x = 1.0f32, y = 2.0f32, z = 3.0f32)
  val b = Vec3(x = 0.5f32, y = 0.5f32, z = 0.5f32)
  assertTrue(nearVec3(a + b, Vec3(x = 1.5f32, y = 2.5f32, z = 3.5f32)), "add")
  assertTrue(nearVec3(a - b, Vec3(x = 0.5f32, y = 1.5f32, z = 2.5f32)), "sub")
  assertTrue(nearVec3(a.scale(2.0f32), Vec3(x = 2.0f32, y = 4.0f32, z = 6.0f32)), "scale")
  assertTrue(nearVec3(a.neg(), Vec3(x = -1.0f32, y = -2.0f32, z = -3.0f32)), "neg")
}

test "dot, cross, length and normalize" {
  val x = Vec3(x = 1.0f32, y = 0.0f32, z = 0.0f32)
  val y = Vec3(x = 0.0f32, y = 1.0f32, z = 0.0f32)
  assertTrue(near(x.dot(y), 0.0f32), "orthogonal dot")
  assertTrue(nearVec3(x.cross(y), Vec3(x = 0.0f32, y = 0.0f32, z = 1.0f32)), "x cross y is z")
  val v = Vec3(x = 3.0f32, y = 4.0f32, z = 0.0f32)
  assertTrue(near(v.length(), 5.0f32), "length")
  assertTrue(near(v.normalize().length(), 1.0f32), "normalize is unit")
  assertTrue(nearVec3(Vec3.zero().normalize(), Vec3.zero()), "zero stays zero")
  assertTrue(near(Vec2(x = 3.0f32, y = 4.0f32).length(), 5.0f32), "Vec2 length")
  assertTrue(near(Vec2(x = 1.0f32, y = 0.0f32).cross(Vec2(x = 0.0f32, y = 1.0f32)), 1.0f32), "Vec2 cross")
  assertTrue(near(Vec4(x = 1.0f32, y = 2.0f32, z = 2.0f32, w = 4.0f32).length(), 5.0f32), "Vec4 length")
}

test "lerp and reflect" {
  val a = Vec3(x = 0.0f32, y = 0.0f32, z = 0.0f32)
  val b = Vec3(x = 2.0f32, y = 4.0f32, z = 6.0f32)
  assertTrue(nearVec3(a.lerp(b, 0.5f32), Vec3(x = 1.0f32, y = 2.0f32, z = 3.0f32)), "midpoint")
  val incoming = Vec3(x = 1.0f32, y = -1.0f32, z = 0.0f32)
  val up = Vec3(x = 0.0f32, y = 1.0f32, z = 0.0f32)
  assertTrue(nearVec3(incoming.reflect(up), Vec3(x = 1.0f32, y = 1.0f32, z = 0.0f32)), "reflect off a floor")
}

test "Mat4 identity, translation and scaling" {
  val p = Vec3(x = 1.0f32, y = 2.0f32, z = 3.0f32)
  assertTrue(nearVec3(Mat4.identity().transformPoint(p), p), "identity")
  val t = Mat4.translation(Vec3(x = 10.0f32, y = 20.0f32, z = 30.0f32))
  assertTrue(nearVec3(t.transformPoint(p), Vec3(x = 11.0f32, y = 22.0f32, z = 33.0f32)), "translate point")
  assertTrue(nearVec3(t.transformDirection(p), p), "translation ignores directions")
  val s = Mat4.scaling(Vec3(x = 2.0f32, y = 3.0f32, z = 4.0f32))
  assertTrue(nearVec3(s.transformPoint(p), Vec3(x = 2.0f32, y = 6.0f32, z = 12.0f32)), "scale point")
  assertTrue(near(t.get(0, 3), 10.0f32), "column-major layout: translation is column 3")
}

test "Mat4 multiplication applies the right operand first" {
  val t = Mat4.translation(Vec3(x = 1.0f32, y = 0.0f32, z = 0.0f32))
  val s = Mat4.scaling(Vec3(x = 2.0f32, y = 2.0f32, z = 2.0f32))
  val p = Vec3(x = 1.0f32, y = 1.0f32, z = 1.0f32)
  assertTrue(nearVec3(t.mul(s).transformPoint(p), Vec3(x = 3.0f32, y = 2.0f32, z = 2.0f32)), "scale then translate")
  assertTrue(nearVec3(s.mul(t).transformPoint(p), Vec3(x = 4.0f32, y = 2.0f32, z = 2.0f32)), "translate then scale")
  assertTrue(nearMat4(Mat4.identity().mul(t), t), "identity is neutral")
}

test "rotations turn the right way" {
  val quarter = 1.5707964f32
  val x = Vec3(x = 1.0f32, y = 0.0f32, z = 0.0f32)
  val y = Vec3(x = 0.0f32, y = 1.0f32, z = 0.0f32)
  val z = Vec3(x = 0.0f32, y = 0.0f32, z = 1.0f32)
  assertTrue(nearVec3(Mat4.rotationZ(quarter).transformPoint(x), y), "Z rotation takes x to y")
  assertTrue(nearVec3(Mat4.rotationX(quarter).transformPoint(y), z), "X rotation takes y to z")
  assertTrue(nearVec3(Mat4.rotationY(quarter).transformPoint(z), x), "Y rotation takes z to x")
}

test "Quat matches the equivalent matrix" {
  val quarter = 1.5707964f32
  val q = Quat.fromAxisAngle(Vec3(x = 0.0f32, y = 0.0f32, z = 1.0f32), quarter)
  val x = Vec3(x = 1.0f32, y = 0.0f32, z = 0.0f32)
  assertTrue(nearVec3(q.rotate(x), Vec3(x = 0.0f32, y = 1.0f32, z = 0.0f32)), "rotate")
  assertTrue(nearMat4(Mat4.fromQuat(q), Mat4.rotationZ(quarter)), "fromQuat equals rotationZ")
  assertTrue(near(q.length(), 1.0f32), "unit length")
  val back = q.conjugate().mul(q)
  assertTrue(near(back.w, 1.0f32) and near(back.x, 0.0f32), "conjugate undoes the rotation")
  val half = Quat.identity().slerp(q, 0.5f32)
  val eighth = Quat.fromAxisAngle(Vec3(x = 0.0f32, y = 0.0f32, z = 1.0f32), quarter * 0.5f32)
  assertTrue(near(half.z, eighth.z) and near(half.w, eighth.w), "slerp halfway")
}

test "Mat4 inverse and singular matrices" {
  val m = Mat4.translation(Vec3(x = 1.0f32, y = 2.0f32, z = 3.0f32)).mul(Mat4.rotationY(0.7f32)).mul(
    Mat4.scaling(Vec3(x = 2.0f32, y = 3.0f32, z = 4.0f32))
  )
  assertTrue(nearMat4(m.mul(unwrapMat4(m.inverse())), Mat4.identity()), "m * inverse is identity")
  val singular = Mat4.scaling(Vec3(x = 1.0f32, y = 0.0f32, z = 1.0f32))
  val none = match singular.inverse() { case Some(_) -> false; case None -> true }
  assertTrue(none, "singular matrix has no inverse")
  assertTrue(nearMat4(m.transpose().transpose(), m), "double transpose")
}

test "projection matrices map the view volume to 0..1 depth" {
  val proj = Mat4.perspective(1.0471976f32, 1.0f32, 1.0f32, 10.0f32)
  val nearP = proj.transform(Vec4(x = 0.0f32, y = 0.0f32, z = -1.0f32, w = 1.0f32))
  val farP = proj.transform(Vec4(x = 0.0f32, y = 0.0f32, z = -10.0f32, w = 1.0f32))
  assertTrue(near(nearP.z / nearP.w, 0.0f32), "near plane maps to depth 0")
  assertTrue(near(farP.z / farP.w, 1.0f32), "far plane maps to depth 1")
  val ortho = Mat4.orthographic(-2.0f32, 2.0f32, -1.0f32, 1.0f32, 0.0f32, 10.0f32)
  assertTrue(
    nearVec3(ortho.transformPoint(Vec3(x = 2.0f32, y = 1.0f32, z = -10.0f32)), Vec3(x = 1.0f32, y = 1.0f32, z = 1.0f32)),
    "orthographic corner"
  )
  assertTrue(
    nearVec3(
      ortho.transformPoint(Vec3(x = -2.0f32, y = -1.0f32, z = 0.0f32)),
      Vec3(x = -1.0f32, y = -1.0f32, z = 0.0f32)
    ),
    "orthographic opposite corner"
  )
}

test "lookAt puts the eye at the origin looking down -Z" {
  val eye = Vec3(x = 0.0f32, y = 0.0f32, z = 5.0f32)
  val view = Mat4.lookAt(eye, Vec3.zero(), Vec3(x = 0.0f32, y = 1.0f32, z = 0.0f32))
  assertTrue(nearVec3(view.transformPoint(eye), Vec3.zero()), "eye maps to origin")
  assertTrue(
    nearVec3(view.transformPoint(Vec3.zero()), Vec3(x = 0.0f32, y = 0.0f32, z = -5.0f32)),
    "target is 5 units ahead"
  )
}

test "Mat3 2D transforms, determinant and inverse" {
  val p = Vec3(x = 1.0f32, y = 0.0f32, z = 1.0f32)
  val moved = Mat3.translation2d(2.0f32, 3.0f32).transform(p)
  assertTrue(near(moved.x, 3.0f32) and near(moved.y, 3.0f32), "translate")
  val turned = Mat3.rotation2d(1.5707964f32).transform(p)
  assertTrue(near(turned.x, 0.0f32) and near(turned.y, 1.0f32), "rotate")
  val s = Mat3.scaling2d(2.0f32, 4.0f32)
  assertTrue(near(s.determinant(), 8.0f32), "determinant")
  val inv = match s.inverse() { case Some(i) -> i; case None -> Mat3.identity() }
  val roundTrip = inv.mul(s).transform(p)
  assertTrue(near(roundTrip.x, 1.0f32) and near(roundTrip.y, 0.0f32), "inverse undoes scaling")
  assertTrue(near(s.transpose().get(0, 0), 2.0f32), "transpose diagonal")
}

test "Rgba8 constructors and Vec4 conversion" {
  val w = Rgba8.white()
  assertEqualInt(w.r.toInt(), 255, "white red")
  assertEqualInt(w.a.toInt(), 255, "white alpha")
  assertEqualInt(Rgba8.transparent().a.toInt(), 0, "transparent alpha")
  val c = Rgba8.fromRgb(0x336699)
  assertEqualInt(c.r.toInt(), 0x33, "fromRgb red")
  assertEqualInt(c.g.toInt(), 0x66, "fromRgb green")
  assertEqualInt(c.b.toInt(), 0x99, "fromRgb blue")
  assertEqualInt(c.a.toInt(), 255, "fromRgb alpha")
  val d = Rgba8.fromRgba(0x11223344i64)
  assertEqualInt(d.r.toInt(), 0x11, "fromRgba red")
  assertEqualInt(d.a.toInt(), 0x44, "fromRgba alpha")
  assertEqualInt(Rgba8.fromInts(-5, 300, 7, 255).r.toInt(), 0, "clamped low")
  assertEqualInt(Rgba8.fromInts(-5, 300, 7, 255).g.toInt(), 255, "clamped high")
  val back = Rgba8.fromVec4(c.toVec4())
  assertEqualInt(back.g.toInt(), 0x66, "Vec4 round trip")
  assertTrue(near(radians(180.0f32), 3.1415927f32), "radians")
  assertTrue(near(degrees(3.1415927f32), 180.0f32), "degrees")
}
