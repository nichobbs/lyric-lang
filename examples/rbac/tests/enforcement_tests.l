//! tests/enforcement_tests.l — unit tests for Rbac.Store JSON serialization
//! and Rbac.Policy permission label round-trips.
//!
//! All tests are pure; no I/O or DB calls.
//!
//! Run:  lyric test examples/rbac/tests/enforcement_tests.l
@test_module
package Rbac.EnforcementTests

import Std.Core
import Std.Testing
import Rbac.Policy
import Rbac.Store

// ─── permissionLabel ─────────────────────────────────────────────────────────
test "permissionLabel for Read" {
  assertEqual(Rbac.Policy.permissionLabel(Permission.Read), "read", "label")
}

test "permissionLabel for Write" {
  assertEqual(Rbac.Policy.permissionLabel(Permission.Write), "write", "label")
}

test "permissionLabel for Delete" {
  assertEqual(Rbac.Policy.permissionLabel(Permission.Delete), "delete", "label")
}

test "permissionLabel for ManageUsers" {
  assertEqual(Rbac.Policy.permissionLabel(Permission.ManageUsers), "manage_users", "label")
}

test "permissionLabel for AdministerAll" {
  assertEqual(Rbac.Policy.permissionLabel(Permission.AdministerAll), "administer_all", "label")
}

// ─── Store.errorMessage ───────────────────────────────────────────────────────
test "errorMessage UserNotFound contains id" {
  val msg = Rbac.Store.errorMessage(StoreError.UserNotFound(id = 7))
  assertTrue(msg.indexOf("7") >= 0, "id present")
}

test "errorMessage RoleNotFound contains role name" {
  val msg = Rbac.Store.errorMessage(StoreError.RoleNotFound(name = "superuser"))
  assertTrue(msg.indexOf("superuser") >= 0, "role name present")
}

test "errorMessage PermissionDenied contains reason" {
  val msg = Rbac.Store.errorMessage(StoreError.PermissionDenied(message = "not an admin"))
  assertTrue(msg.indexOf("not an admin") >= 0, "reason present")
}

test "errorMessage DatabaseError contains driver message" {
  val msg = Rbac.Store.errorMessage(StoreError.DatabaseError(message = "timeout"))
  assertTrue(msg.indexOf("timeout") >= 0, "driver message present")
}

// ─── Store.userToJson ─────────────────────────────────────────────────────────
//
// Substring checks assume compact JSON (no space after ":").
test "userToJson includes id" {
  val u = User(id = 42, username = "alice", createdAt = "2024-01-01T00:00:00Z")
  val json = Rbac.Store.userToJson(u)
  assertTrue(json.indexOf("\"id\":42") >= 0, "id present")
}

test "userToJson includes username" {
  val u = User(id = 1, username = "bob", createdAt = "2024-01-01T00:00:00Z")
  val json = Rbac.Store.userToJson(u)
  assertTrue(json.indexOf("bob") >= 0, "username present")
}

test "userToJson is wrapped in braces" {
  val u = User(id = 1, username = "carol", createdAt = "2024-01-01T00:00:00Z")
  val json = Rbac.Store.userToJson(u)
  assertTrue(json.length > 0, "json non-empty")
  assertEqual(json.substring(0, 1), "{", "starts with {")
  assertEqual(json.substring(json.length - 1, 1), "}", "ends with }")
}

// ─── Store.assignmentToJson ───────────────────────────────────────────────────
test "assignmentToJson includes role_name" {
  val a = RoleAssignment(
    userId = 1,
    roleId = 2,
    roleName = "manager",
    grantedBy = 99,
    grantedAt = "2024-06-01T00:00:00Z"
  )
  val json = Rbac.Store.assignmentToJson(a)
  assertTrue(json.indexOf("manager") >= 0, "role name present")
}

test "assignmentToJson includes user_id" {
  val a = RoleAssignment(userId = 5, roleId = 1, roleName = "user", grantedBy = 10, grantedAt = "2024-06-01T00:00:00Z")
  val json = Rbac.Store.assignmentToJson(a)
  assertTrue(json.indexOf("\"user_id\":5") >= 0, "user_id present")
}

test "assignmentToJson includes granted_by" {
  val a = RoleAssignment(userId = 1, roleId = 2, roleName = "user", grantedBy = 42, grantedAt = "2024-06-01T00:00:00Z")
  val json = Rbac.Store.assignmentToJson(a)
  assertTrue(json.indexOf("\"granted_by\":42") >= 0, "granted_by present")
}
