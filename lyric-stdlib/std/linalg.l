//! std/linalg.l - Vector, matrix and quaternion types for graphics and games.
//!
//! `Vec2`, `Vec3`, `Vec4`, `Quat`, `Mat3`, `Mat4` and `Rgba8` are by-value
//! records of `Float` (and `Byte`): on `--target native` they are inline
//! values with no allocation and no reference counting (docs/67 §4.6).
//! `Vec2`/`Vec3`/`Vec4` derive component-wise `+` and `-`; everything else is
//! a method (`a.dot(b)`, `m.mul(n)`, `m.transformPoint(p)`), so there is no
//! operator overloading beyond that derive.
//!
//! Conventions, chosen to match WebGPU and WGSL so a `Mat4` uploads to a
//! uniform buffer as it is:
//!
//!   - Matrices are stored column-major: element (row, col) is `m[col * N + row]`.
//!   - Coordinates are right-handed and a view looks down -Z.
//!   - Clip-space depth runs 0 to 1 (`perspective`, `orthographic`).
//!   - Angles are radians.
@runtime_checked
@pure
package Std.Linalg

import Std.Core
import Std.Math

// =====================================================================
// Scalar helpers.
// =====================================================================

func sqrtF(x: in Float): Float {
  sqrt(x).toFloat()
}

func sinF(x: in Float): Float {
  sin(x).toFloat()
}

func cosF(x: in Float): Float {
  cos(x).toFloat()
}

func tanF(x: in Float): Float {
  tan(x).toFloat()
}

func acosF(x: in Float): Float {
  acos(x).toFloat()
}

/// Linear interpolation: `a` at `t == 0`, `b` at `t == 1`.
pub func lerpFloat(a: in Float, b: in Float, t: in Float): Float {
  a + (b - a) * t
}

/// `x` limited to `[lo, hi]`.
pub func clampFloat(x: in Float, lo: in Float, hi: in Float): Float {
  if x < lo {
    lo
  } else if x > hi {
    hi
  } else {
    x
  }
}

pub func radians(deg: in Float): Float {
  deg * 0.017453292f32
}

pub func degrees(rad: in Float): Float {
  rad * 57.29578f32
}

// =====================================================================
// Vec2
// =====================================================================

@derive(Add, Sub)
pub record Vec2 {
  x: Float
  y: Float
}

pub func Vec2.zero(): Vec2 {
  Vec2(x = 0.0f32, y = 0.0f32)
}

pub func Vec2.splat(v: in Float): Vec2 {
  Vec2(x = v, y = v)
}

pub func Vec2.neg(a: in Vec2): Vec2 {
  Vec2(x = -a.x, y = -a.y)
}

pub func Vec2.scale(a: in Vec2, k: in Float): Vec2 {
  Vec2(x = a.x * k, y = a.y * k)
}

pub func Vec2.mulComponents(a: in Vec2, b: in Vec2): Vec2 {
  Vec2(x = a.x * b.x, y = a.y * b.y)
}

pub func Vec2.dot(a: in Vec2, b: in Vec2): Float {
  a.x * b.x + a.y * b.y
}

pub func Vec2.lengthSquared(a: in Vec2): Float {
  a.dot(a)
}

pub func Vec2.length(a: in Vec2): Float {
  sqrtF(a.lengthSquared())
}

/// The unit vector in `a`'s direction; the zero vector for a zero `a`.
pub func Vec2.normalize(a: in Vec2): Vec2 {
  val len = a.length()
  if len == 0.0f32 {
    a
  } else {
    a.scale(1.0f32 / len)
  }
}

pub func Vec2.lerp(a: in Vec2, b: in Vec2, t: in Float): Vec2 {
  Vec2(x = lerpFloat(a.x, b.x, t), y = lerpFloat(a.y, b.y, t))
}

/// `a` rotated a quarter turn counter-clockwise.
pub func Vec2.perp(a: in Vec2): Vec2 {
  Vec2(x = -a.y, y = a.x)
}

/// The z component of the 3D cross product: positive when `b` is
/// counter-clockwise from `a`.
pub func Vec2.cross(a: in Vec2, b: in Vec2): Float {
  a.x * b.y - a.y * b.x
}

// =====================================================================
// Vec3
// =====================================================================

@derive(Add, Sub)
pub record Vec3 {
  x: Float
  y: Float
  z: Float
}

pub func Vec3.zero(): Vec3 {
  Vec3(x = 0.0f32, y = 0.0f32, z = 0.0f32)
}

pub func Vec3.splat(v: in Float): Vec3 {
  Vec3(x = v, y = v, z = v)
}

pub func Vec3.neg(a: in Vec3): Vec3 {
  Vec3(x = -a.x, y = -a.y, z = -a.z)
}

pub func Vec3.scale(a: in Vec3, k: in Float): Vec3 {
  Vec3(x = a.x * k, y = a.y * k, z = a.z * k)
}

pub func Vec3.mulComponents(a: in Vec3, b: in Vec3): Vec3 {
  Vec3(x = a.x * b.x, y = a.y * b.y, z = a.z * b.z)
}

pub func Vec3.dot(a: in Vec3, b: in Vec3): Float {
  a.x * b.x + a.y * b.y + a.z * b.z
}

pub func Vec3.cross(a: in Vec3, b: in Vec3): Vec3 {
  Vec3(
    x = a.y * b.z - a.z * b.y,
    y = a.z * b.x - a.x * b.z,
    z = a.x * b.y - a.y * b.x
  )
}

pub func Vec3.lengthSquared(a: in Vec3): Float {
  a.dot(a)
}

pub func Vec3.length(a: in Vec3): Float {
  sqrtF(a.lengthSquared())
}

/// The unit vector in `a`'s direction; the zero vector for a zero `a`.
pub func Vec3.normalize(a: in Vec3): Vec3 {
  val len = a.length()
  if len == 0.0f32 {
    a
  } else {
    a.scale(1.0f32 / len)
  }
}

pub func Vec3.lerp(a: in Vec3, b: in Vec3, t: in Float): Vec3 {
  Vec3(x = lerpFloat(a.x, b.x, t), y = lerpFloat(a.y, b.y, t), z = lerpFloat(a.z, b.z, t))
}

/// `a` reflected about the plane with unit normal `n`.
pub func Vec3.reflect(a: in Vec3, n: in Vec3): Vec3 {
  a - n.scale(2.0f32 * a.dot(n))
}

// =====================================================================
// Vec4
// =====================================================================

@derive(Add, Sub)
pub record Vec4 {
  x: Float
  y: Float
  z: Float
  w: Float
}

pub func Vec4.zero(): Vec4 {
  Vec4(x = 0.0f32, y = 0.0f32, z = 0.0f32, w = 0.0f32)
}

pub func Vec4.splat(v: in Float): Vec4 {
  Vec4(x = v, y = v, z = v, w = v)
}

pub func Vec4.fromVec3(a: in Vec3, w: in Float): Vec4 {
  Vec4(x = a.x, y = a.y, z = a.z, w = w)
}

pub func Vec4.xyz(a: in Vec4): Vec3 {
  Vec3(x = a.x, y = a.y, z = a.z)
}

pub func Vec4.neg(a: in Vec4): Vec4 {
  Vec4(x = -a.x, y = -a.y, z = -a.z, w = -a.w)
}

pub func Vec4.scale(a: in Vec4, k: in Float): Vec4 {
  Vec4(x = a.x * k, y = a.y * k, z = a.z * k, w = a.w * k)
}

pub func Vec4.mulComponents(a: in Vec4, b: in Vec4): Vec4 {
  Vec4(x = a.x * b.x, y = a.y * b.y, z = a.z * b.z, w = a.w * b.w)
}

pub func Vec4.dot(a: in Vec4, b: in Vec4): Float {
  a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
}

pub func Vec4.lengthSquared(a: in Vec4): Float {
  a.dot(a)
}

pub func Vec4.length(a: in Vec4): Float {
  sqrtF(a.lengthSquared())
}

pub func Vec4.normalize(a: in Vec4): Vec4 {
  val len = a.length()
  if len == 0.0f32 {
    a
  } else {
    a.scale(1.0f32 / len)
  }
}

pub func Vec4.lerp(a: in Vec4, b: in Vec4, t: in Float): Vec4 {
  Vec4(
    x = lerpFloat(a.x, b.x, t),
    y = lerpFloat(a.y, b.y, t),
    z = lerpFloat(a.z, b.z, t),
    w = lerpFloat(a.w, b.w, t)
  )
}

// =====================================================================
// Mat3 - 3x3, column-major. Rotation and scale in 3D, or an affine 2D
// transform in homogeneous coordinates.
// =====================================================================

pub record Mat3 {
  m: array[9, Float]
}

func mat3Of(a: in array[9, Float]): Mat3 {
  Mat3(m = a)
}

pub func Mat3.identity(): Mat3 {
  var a: array[9, Float] = [1.0f32, 0.0f32, 0.0f32, 0.0f32, 1.0f32, 0.0f32, 0.0f32, 0.0f32, 1.0f32]
  mat3Of(a)
}

/// Element at `row`, `col` (each 0 to 2).
pub func Mat3.get(a: in Mat3, row: in Int, col: in Int): Float
  requires: row >= 0 and row < 3 and col >= 0 and col < 3
{
  a.m[col * 3 + row]
}

pub func Mat3.mul(a: in Mat3, b: in Mat3): Mat3 {
  var res: array[9, Float] = [0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32]
  var col = 0
  while col < 3 {
    var row = 0
    while row < 3 {
      var sum = 0.0f32
      var k = 0
      while k < 3 {
        sum = sum + a.m[k * 3 + row] * b.m[col * 3 + k]
        k = k + 1
      }
      res[col * 3 + row] = sum
      row = row + 1
    }
    col = col + 1
  }
  mat3Of(res)
}

pub func Mat3.transform(a: in Mat3, v: in Vec3): Vec3 {
  Vec3(
    x = a.m[0] * v.x + a.m[3] * v.y + a.m[6] * v.z,
    y = a.m[1] * v.x + a.m[4] * v.y + a.m[7] * v.z,
    z = a.m[2] * v.x + a.m[5] * v.y + a.m[8] * v.z
  )
}

pub func Mat3.transpose(a: in Mat3): Mat3 {
  var res: array[9, Float] = [0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32]
  var col = 0
  while col < 3 {
    var row = 0
    while row < 3 {
      res[row * 3 + col] = a.m[col * 3 + row]
      row = row + 1
    }
    col = col + 1
  }
  mat3Of(res)
}

pub func Mat3.determinant(a: in Mat3): Float {
  a.m[0] * (a.m[4] * a.m[8] - a.m[7] * a.m[5]) - a.m[3] * (a.m[1] * a.m[8] - a.m[7] * a.m[2]) + a.m[6] * (a.m[1] * a.m[5] - a.m[4] * a.m[2])
}

/// The inverse, or `None` when the matrix is singular.
pub func Mat3.inverse(a: in Mat3): Option[Mat3] {
  val det = a.determinant()
  if det == 0.0f32 {
    None
  } else {
    val inv = 1.0f32 / det
    var res: array[9, Float] = [0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32]
    res[0] = (a.m[4] * a.m[8] - a.m[7] * a.m[5]) * inv
    res[1] = (a.m[7] * a.m[2] - a.m[1] * a.m[8]) * inv
    res[2] = (a.m[1] * a.m[5] - a.m[4] * a.m[2]) * inv
    res[3] = (a.m[6] * a.m[5] - a.m[3] * a.m[8]) * inv
    res[4] = (a.m[0] * a.m[8] - a.m[6] * a.m[2]) * inv
    res[5] = (a.m[3] * a.m[2] - a.m[0] * a.m[5]) * inv
    res[6] = (a.m[3] * a.m[7] - a.m[6] * a.m[4]) * inv
    res[7] = (a.m[6] * a.m[1] - a.m[0] * a.m[7]) * inv
    res[8] = (a.m[0] * a.m[4] - a.m[3] * a.m[1]) * inv
    Some(mat3Of(res))
  }
}

/// A 2D translation as a homogeneous transform: apply it to `Vec3(x, y, 1)`.
pub func Mat3.translation2d(tx: in Float, ty: in Float): Mat3 {
  var a: array[9, Float] = [1.0f32, 0.0f32, 0.0f32, 0.0f32, 1.0f32, 0.0f32, tx, ty, 1.0f32]
  mat3Of(a)
}

pub func Mat3.scaling2d(sx: in Float, sy: in Float): Mat3 {
  var a: array[9, Float] = [sx, 0.0f32, 0.0f32, 0.0f32, sy, 0.0f32, 0.0f32, 0.0f32, 1.0f32]
  mat3Of(a)
}

/// A counter-clockwise 2D rotation by `angle` radians.
pub func Mat3.rotation2d(angle: in Float): Mat3 {
  val c = cosF(angle)
  val s = sinF(angle)
  var a: array[9, Float] = [c, s, 0.0f32, -s, c, 0.0f32, 0.0f32, 0.0f32, 1.0f32]
  mat3Of(a)
}

// =====================================================================
// Quat - unit quaternions for rotation. Stored as (x, y, z) vector part
// and w scalar part.
// =====================================================================

pub record Quat {
  x: Float
  y: Float
  z: Float
  w: Float
}

pub func Quat.identity(): Quat {
  Quat(x = 0.0f32, y = 0.0f32, z = 0.0f32, w = 1.0f32)
}

/// A rotation of `angle` radians about `axis` (which need not be unit length).
pub func Quat.fromAxisAngle(axis: in Vec3, angle: in Float): Quat {
  val n = axis.normalize()
  val half = angle * 0.5f32
  val s = sinF(half)
  Quat(x = n.x * s, y = n.y * s, z = n.z * s, w = cosF(half))
}

pub func Quat.dot(a: in Quat, b: in Quat): Float {
  a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
}

pub func Quat.length(a: in Quat): Float {
  sqrtF(a.dot(a))
}

pub func Quat.normalize(a: in Quat): Quat {
  val len = a.length()
  if len == 0.0f32 {
    Quat.identity()
  } else {
    val inv = 1.0f32 / len
    Quat(x = a.x * inv, y = a.y * inv, z = a.z * inv, w = a.w * inv)
  }
}

pub func Quat.conjugate(a: in Quat): Quat {
  Quat(x = -a.x, y = -a.y, z = -a.z, w = a.w)
}

/// The Hamilton product: `a.mul(b)` applies `b` first, then `a`.
pub func Quat.mul(a: in Quat, b: in Quat): Quat {
  Quat(
    x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
    y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
    z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
  )
}

/// `v` rotated by the unit quaternion `a`.
pub func Quat.rotate(a: in Quat, v: in Vec3): Vec3 {
  val u = Vec3(x = a.x, y = a.y, z = a.z)
  val t = u.cross(v).scale(2.0f32)
  v + t.scale(a.w) + u.cross(t)
}

/// Spherical interpolation along the shorter arc; `a` at `t == 0`, `b` at 1.
pub func Quat.slerp(a: in Quat, b: in Quat, t: in Float): Quat {
  var cosTheta = a.dot(b)
  var bx = b.x
  var by = b.y
  var bz = b.z
  var bw = b.w
  if cosTheta < 0.0f32 {
    cosTheta = -cosTheta
    bx = -bx
    by = -by
    bz = -bz
    bw = -bw
  }
  if cosTheta > 0.9995f32 {
    Quat(
      x = lerpFloat(a.x, bx, t),
      y = lerpFloat(a.y, by, t),
      z = lerpFloat(a.z, bz, t),
      w = lerpFloat(a.w, bw, t)
    ).normalize()
  } else {
    val theta = acosF(cosTheta)
    val sinTheta = sinF(theta)
    val wa = sinF((1.0f32 - t) * theta) / sinTheta
    val wb = sinF(t * theta) / sinTheta
    Quat(x = a.x * wa + bx * wb, y = a.y * wa + by * wb, z = a.z * wa + bz * wb, w = a.w * wa + bw * wb)
  }
}

// =====================================================================
// Mat4 - 4x4, column-major.
// =====================================================================

pub record Mat4 {
  m: array[16, Float]
}

func mat4Of(a: in array[16, Float]): Mat4 {
  Mat4(m = a)
}

func zeros16(): array[16, Float] {
  [0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32, 0.0f32]
}

pub func Mat4.identity(): Mat4 {
  var a = zeros16()
  a[0] = 1.0f32
  a[5] = 1.0f32
  a[10] = 1.0f32
  a[15] = 1.0f32
  mat4Of(a)
}

/// Element at `row`, `col` (each 0 to 3).
pub func Mat4.get(a: in Mat4, row: in Int, col: in Int): Float
  requires: row >= 0 and row < 4 and col >= 0 and col < 4
{
  a.m[col * 4 + row]
}

/// The product `a * b`: applying it to a vector applies `b` first, then `a`.
pub func Mat4.mul(a: in Mat4, b: in Mat4): Mat4 {
  var res = zeros16()
  var col = 0
  while col < 4 {
    var row = 0
    while row < 4 {
      var sum = 0.0f32
      var k = 0
      while k < 4 {
        sum = sum + a.m[k * 4 + row] * b.m[col * 4 + k]
        k = k + 1
      }
      res[col * 4 + row] = sum
      row = row + 1
    }
    col = col + 1
  }
  mat4Of(res)
}

pub func Mat4.transform(a: in Mat4, v: in Vec4): Vec4 {
  Vec4(
    x = a.m[0] * v.x + a.m[4] * v.y + a.m[8] * v.z + a.m[12] * v.w,
    y = a.m[1] * v.x + a.m[5] * v.y + a.m[9] * v.z + a.m[13] * v.w,
    z = a.m[2] * v.x + a.m[6] * v.y + a.m[10] * v.z + a.m[14] * v.w,
    w = a.m[3] * v.x + a.m[7] * v.y + a.m[11] * v.z + a.m[15] * v.w
  )
}

/// Transform a point (w = 1), dropping the resulting w.
pub func Mat4.transformPoint(a: in Mat4, p: in Vec3): Vec3 {
  a.transform(Vec4.fromVec3(p, 1.0f32)).xyz()
}

/// Transform a direction (w = 0): translation does not apply.
pub func Mat4.transformDirection(a: in Mat4, d: in Vec3): Vec3 {
  a.transform(Vec4.fromVec3(d, 0.0f32)).xyz()
}

pub func Mat4.transpose(a: in Mat4): Mat4 {
  var res = zeros16()
  var col = 0
  while col < 4 {
    var row = 0
    while row < 4 {
      res[row * 4 + col] = a.m[col * 4 + row]
      row = row + 1
    }
    col = col + 1
  }
  mat4Of(res)
}

pub func Mat4.translation(t: in Vec3): Mat4 {
  var a = Mat4.identity().m
  a[12] = t.x
  a[13] = t.y
  a[14] = t.z
  mat4Of(a)
}

pub func Mat4.scaling(s: in Vec3): Mat4 {
  var a = zeros16()
  a[0] = s.x
  a[5] = s.y
  a[10] = s.z
  a[15] = 1.0f32
  mat4Of(a)
}

pub func Mat4.rotationX(angle: in Float): Mat4 {
  val c = cosF(angle)
  val s = sinF(angle)
  var a = Mat4.identity().m
  a[5] = c
  a[6] = s
  a[9] = -s
  a[10] = c
  mat4Of(a)
}

pub func Mat4.rotationY(angle: in Float): Mat4 {
  val c = cosF(angle)
  val s = sinF(angle)
  var a = Mat4.identity().m
  a[0] = c
  a[2] = -s
  a[8] = s
  a[10] = c
  mat4Of(a)
}

pub func Mat4.rotationZ(angle: in Float): Mat4 {
  val c = cosF(angle)
  val s = sinF(angle)
  var a = Mat4.identity().m
  a[0] = c
  a[1] = s
  a[4] = -s
  a[5] = c
  mat4Of(a)
}

/// The rotation matrix of a unit quaternion.
pub func Mat4.fromQuat(q: in Quat): Mat4 {
  val xx = q.x * q.x
  val yy = q.y * q.y
  val zz = q.z * q.z
  val xy = q.x * q.y
  val xz = q.x * q.z
  val yz = q.y * q.z
  val wx = q.w * q.x
  val wy = q.w * q.y
  val wz = q.w * q.z
  var a = Mat4.identity().m
  a[0] = 1.0f32 - 2.0f32 * (yy + zz)
  a[1] = 2.0f32 * (xy + wz)
  a[2] = 2.0f32 * (xz - wy)
  a[4] = 2.0f32 * (xy - wz)
  a[5] = 1.0f32 - 2.0f32 * (xx + zz)
  a[6] = 2.0f32 * (yz + wx)
  a[8] = 2.0f32 * (xz + wy)
  a[9] = 2.0f32 * (yz - wx)
  a[10] = 1.0f32 - 2.0f32 * (xx + yy)
  mat4Of(a)
}

/// A right-handed view matrix looking from `eye` toward `target`.
pub func Mat4.lookAt(eye: in Vec3, target: in Vec3, up: in Vec3): Mat4 {
  val f = (target - eye).normalize()
  val s = f.cross(up).normalize()
  val u = s.cross(f)
  var a = Mat4.identity().m
  a[0] = s.x
  a[4] = s.y
  a[8] = s.z
  a[1] = u.x
  a[5] = u.y
  a[9] = u.z
  a[2] = -f.x
  a[6] = -f.y
  a[10] = -f.z
  a[12] = -s.dot(eye)
  a[13] = -u.dot(eye)
  a[14] = f.dot(eye)
  mat4Of(a)
}

/// A right-handed perspective projection with 0-to-1 clip-space depth.
/// `fovY` is the vertical field of view in radians.
pub func Mat4.perspective(fovY: in Float, aspect: in Float, near: in Float, far: in Float): Mat4
  requires: fovY > 0.0f32 and aspect > 0.0f32 and near > 0.0f32 and far > near
{
  val f = 1.0f32 / tanF(fovY * 0.5f32)
  var a = zeros16()
  a[0] = f / aspect
  a[5] = f
  a[10] = far / (near - far)
  a[11] = -1.0f32
  a[14] = near * far / (near - far)
  mat4Of(a)
}

/// A right-handed orthographic projection with 0-to-1 clip-space depth.
pub func Mat4.orthographic(left: in Float, right: in Float, bottom: in Float, top: in Float, near: in Float, far: in Float): Mat4
  requires: right != left and top != bottom and far != near
{
  var a = zeros16()
  a[0] = 2.0f32 / (right - left)
  a[5] = 2.0f32 / (top - bottom)
  a[10] = 1.0f32 / (near - far)
  a[12] = (left + right) / (left - right)
  a[13] = (top + bottom) / (bottom - top)
  a[14] = near / (near - far)
  a[15] = 1.0f32
  mat4Of(a)
}

/// The inverse, or `None` when the matrix is singular.
pub func Mat4.inverse(a: in Mat4): Option[Mat4] {
  val m = a.m
  var inv = zeros16()
  inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10]
  inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10]
  inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9]
  inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9]
  inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10]
  inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10]
  inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9]
  inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9]
  inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6]
  inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6]
  inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5]
  inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5]
  inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6]
  inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6]
  inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5]
  inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5]
  val det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12]
  if det == 0.0f32 {
    None
  } else {
    val scaleBy = 1.0f32 / det
    var i = 0
    while i < 16 {
      inv[i] = inv[i] * scaleBy
      i = i + 1
    }
    Some(mat4Of(inv))
  }
}

// =====================================================================
// Rgba8 - an 8-bit-per-channel colour, laid res as the four bytes a
// texture upload expects.
// =====================================================================

pub record Rgba8 {
  r: Byte
  g: Byte
  b: Byte
  a: Byte
}

pub func Rgba8.white(): Rgba8 {
  Rgba8(r = 255.toByte(), g = 255.toByte(), b = 255.toByte(), a = 255.toByte())
}

pub func Rgba8.black(): Rgba8 {
  Rgba8(r = 0.toByte(), g = 0.toByte(), b = 0.toByte(), a = 255.toByte())
}

pub func Rgba8.transparent(): Rgba8 {
  Rgba8(r = 0.toByte(), g = 0.toByte(), b = 0.toByte(), a = 0.toByte())
}

/// From four channels, each clamped to 0 to 255.
pub func Rgba8.fromInts(r: in Int, g: in Int, b: in Int, a: in Int): Rgba8 {
  Rgba8(r = clampChannel(r), g = clampChannel(g), b = clampChannel(b), a = clampChannel(a))
}

/// From `0xRRGGBB`, fully opaque.
pub func Rgba8.fromRgb(rgb: in Int): Rgba8 {
  Rgba8.fromInts(rgb.shr(16).and(255), rgb.shr(8).and(255), rgb.and(255), 255)
}

/// From `0xRRGGBBAA`: the low byte is alpha.
pub func Rgba8.fromRgba(rgba: in Long): Rgba8 {
  Rgba8.fromInts(
    rgba.shr(24).and(255i64).toInt(),
    rgba.shr(16).and(255i64).toInt(),
    rgba.shr(8).and(255i64).toInt(),
    rgba.and(255i64).toInt()
  )
}

func clampChannel(v: in Int): Byte {
  if v < 0 {
    0.toByte()
  } else if v > 255 {
    255.toByte()
  } else {
    v.toByte()
  }
}

/// The colour as four floats in 0 to 1, in r, g, b, a order.
pub func Rgba8.toVec4(c: in Rgba8): Vec4 {
  Vec4(
    x = c.r.toInt().toFloat() / 255.0f32,
    y = c.g.toInt().toFloat() / 255.0f32,
    z = c.b.toInt().toFloat() / 255.0f32,
    w = c.a.toInt().toFloat() / 255.0f32
  )
}

/// From four floats in 0 to 1 (clamped), rounding to the nearest byte.
pub func Rgba8.fromVec4(v: in Vec4): Rgba8 {
  Rgba8.fromInts(
    channelOf(v.x),
    channelOf(v.y),
    channelOf(v.z),
    channelOf(v.w)
  )
}

func channelOf(f: in Float): Int {
  (clampFloat(f, 0.0f32, 1.0f32) * 255.0f32 + 0.5f32).toInt()
}
