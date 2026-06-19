//! Rbac.Store — user, role, and assignment repository.
@runtime_checked
package Rbac.Store

import Std.Core
import Std.Collections
import Rbac.Policy
import Db

// ─── Column helpers ───────────────────────────────────────────────────────────
func colText(row: in DbRow, name: in String): String {
  match Db.col(row, name) {
    case DbValue.DbText(v) -> v
    case _ -> ""
  }
}

func colLong(row: in DbRow, name: in String): Long {
  match Db.col(row, name) {
    case DbValue.DbLong(v) -> v
    case DbValue.DbInt(v) -> v.toLong()
    case _ -> 0i64
  }
}

// ─── Domain records ───────────────────────────────────────────────────────────
pub record User {
  id: Long
  username: String
  createdAt: String
}

pub record RoleAssignment {
  userId: Long
  roleId: Long
  roleName: String
  grantedBy: Long
  grantedAt: String
}

pub record Resource {
  id: Long
  name: String
  ownerId: Long
  createdAt: String
}

// ─── Error type ───────────────────────────────────────────────────────────────
pub union StoreError {
  case UserNotFound(id: Long)
  case RoleNotFound(name: String)
  case ResourceNotFound(id: Long)
  case PermissionDenied(message: String)
  case DatabaseError(message: String)
}

pub func errorMessage(e: in StoreError): String {
  match e {
    case StoreError.UserNotFound(id) -> "user " + id.toString() + " not found"
    case StoreError.RoleNotFound(name) -> "role '" + name + "' not found"
    case StoreError.ResourceNotFound(id) -> "resource " + id.toString() + " not found"
    case StoreError.PermissionDenied(msg) -> "permission denied: " + msg
    case StoreError.DatabaseError(msg) -> "database error: " + msg
  }
}

// ─── Users ────────────────────────────────────────────────────────────────────
pub func getUserById(conn: in DbConnection, userId: in Long): Result[Option[User], StoreError] {
  val sql = "SELECT id, username, created_at FROM users WHERE id = $1"
  match Db.queryOne(conn, sql, [userId.toString()]) {
    case Err(e) -> Err(StoreError.DatabaseError(message = e.message))
    case Ok(None) -> Ok(None)
    case Ok(Some(row)) -> Ok(Some(value = User(id = colLong(row, "id"), username = colText(row, "username"), createdAt = colText(row, "created_at"))))
  }
}

pub func createUser(conn: in DbConnection, username: in String): Result[User, StoreError]
  requires: username.length > 0
{
  val sql = "INSERT INTO users (username) VALUES ($1) RETURNING id, username, created_at"
  match conn.query(sql, [username]) {
    case Err(e) -> Err(StoreError.DatabaseError(message = e.message))
    case Ok(rows) -> {
      for row in rows {
        return Ok(User(id = colLong(row, "id"), username = colText(row, "username"), createdAt = colText(row, "created_at")))
      }
      Err(StoreError.DatabaseError(message = "INSERT returned no rows"))
    }
  }
}

// ─── Role assignments ─────────────────────────────────────────────────────────
/// Return all roles held by `userId`.
pub func getRolesForUser(conn: in DbConnection, userId: in Long): Result[List[RoleAssignment], StoreError] {
  val sql = "SELECT ur.user_id, ur.role_id, r.name AS role_name, ur.granted_by, ur.granted_at " +
    "FROM user_roles ur JOIN roles r ON r.id = ur.role_id " +
    "WHERE ur.user_id = $1 ORDER BY ur.granted_at"
  match conn.query(sql, [userId.toString()]) {
    case Err(e) -> Err(StoreError.DatabaseError(message = e.message))
    case Ok(rows) -> {
      val assignments: List[RoleAssignment] = newList()
      for row in rows {
        assignments.add(
          RoleAssignment(
            userId = colLong(row, "user_id"),
            roleId = colLong(row, "role_id"),
            roleName = colText(row, "role_name"),
            grantedBy = colLong(row, "granted_by"),
            grantedAt = colText(row, "granted_at")
          )
        )
      }
      Ok(assignments)
    }
  }
}

/// Grant `roleName` to `targetUserId`.  The grantor's role is verified
/// by the caller (Rbac.Enforcement) before this function is invoked.
pub func grantRole(
  conn: in DbConnection, targetUserId: in Long, roleName: in String, grantedBy: in Long
): Result[Unit, StoreError] {
  val roleSql = "SELECT id FROM roles WHERE name = $1"
  match Db.queryOne(conn, roleSql, [roleName]) {
    case Err(e) -> Err(StoreError.DatabaseError(message = e.message))
    case Ok(None) -> Err(StoreError.RoleNotFound(name = roleName))
    case Ok(Some(row)) -> {
      val roleId = colLong(row, "id")
      val insertSql = "INSERT INTO user_roles (user_id, role_id, granted_by) " +
        "VALUES ($1, $2, $3) ON CONFLICT DO NOTHING"
      match conn.execute(insertSql, [targetUserId.toString(), roleId.toString(), grantedBy.toString()]) {
        case Err(e) -> Err(StoreError.DatabaseError(message = e.message))
        case Ok(_) -> Ok(())
      }
    }
  }
}

/// Revoke `roleName` from `targetUserId`.
pub func revokeRole(conn: in DbConnection, targetUserId: in Long, roleName: in String): Result[Unit, StoreError] {
  val sql = "DELETE FROM user_roles WHERE user_id = $1 AND " + "role_id = (SELECT id FROM roles WHERE name = $2)"
  match conn.execute(sql, [targetUserId.toString(), roleName]) {
    case Err(e) -> Err(StoreError.DatabaseError(message = e.message))
    case Ok(_) -> Ok(())
  }
}

// ─── JSON serialisation ───────────────────────────────────────────────────────
pub func userToJson(u: in User): String {
  return "{" + "\"id\":" + u.id.toString() + "," + "\"username\":\"" + u.username + "\"," + "\"created_at\":\"" +
    u.createdAt +
    "\"" +
    "}"
}

pub func assignmentToJson(a: in RoleAssignment): String {
  return "{" + "\"user_id\":" + a.userId.toString() + "," + "\"role_id\":" + a.roleId.toString() + "," +
    "\"role_name\":\"" +
    a.roleName +
    "\"," +
    "\"granted_by\":" +
    a.grantedBy.toString() +
    "," +
    "\"granted_at\":\"" +
    a.grantedAt +
    "\"" +
    "}"
}
