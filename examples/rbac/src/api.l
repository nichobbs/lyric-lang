//! Rbac.Api — HTTP handler functions and route table.
//!
//! Route table:
//!   POST  /users                    — create user
//!   GET   /users/{id}               — get user
//!   GET   /users/{id}/roles         — list role assignments
//!   POST  /users/{id}/roles         — grant role (requires ManageUsers)
//!   DELETE /users/{id}/roles/{role} — revoke role (requires ManageUsers)
//!   POST  /check                    — check a (userId, permission) pair
@runtime_checked
package Rbac.Api

import Std.Core
import Std.Collections
import Rbac.Policy
import Rbac.Store
import Rbac.Enforcement
import Db
import Web
import Web.Aspects
import OTel

// ─── Aspects ──────────────────────────────────────────────────────────────────
aspect Throttle from Web.Aspects.RateLimit {
  matches: name like "handle*"
  config {
    requestsPerMinute: Int = 200
    burstSize: Int = 30
  }
}

aspect Auth from Web.Aspects.RequiresAuth {
  inside: Throttle
  matches: name in { handleCreateUser, handleGrantRole, handleRevokeRole }
  config {
    @sensitive
    jwtSecret: String
    issuer: String = "rbac-service"
    audience: String = "rbac-api"
  }
}

// ─── Request records ──────────────────────────────────────────────────────────
pub record CreateUserRequest {
  username: String
}

pub record GrantRoleRequest {
  role: String    // target role name
  grantorId: Long      // user performing the grant
}

pub record CheckRequest {
  userId: Long
  permission: String    // permission label (e.g. "write")
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
func storeErrToApi(e: in StoreError): ApiError {
  val msg = Rbac.Store.errorMessage(e)
  match e {
    case StoreError.UserNotFound(_) -> Web.notFound(msg)
    case StoreError.RoleNotFound(_) -> Web.notFound(msg)
    case StoreError.ResourceNotFound(_) -> Web.notFound(msg)
    case StoreError.PermissionDenied(_) -> Web.forbidden(msg)
    case StoreError.DatabaseError(_) -> Web.internalError(msg)
  }
}

func jsonArr(items: in List[String]): String {
  var buf: String = "["
  var first: Bool = true
  for item in items {
    if not first {
      buf = buf + ","
    }
    buf = buf + item
    first = false
  }
  return buf + "]"
}

// ─── Handlers ─────────────────────────────────────────────────────────────────
// See Ledger.Api for @body / authToken rationale.
@post("/users")
pub func handleCreateUser(@body req: in CreateUserRequest, authToken: String): Result[String, ApiError] {
  val span = OTel.startSpan("rbac.user.create", 1)
  if req.username.length == 0 {
    OTel.endSpan(span)
    return Err(Web.badRequest("username must not be empty"))
  }
  match Db.connectFromEnv() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(Web.serviceUnavailable("database unavailable"))
    }
    case Ok(conn) -> match Rbac.Store.createUser(conn, req.username) { case Err(e) -> { conn.close(); OTel.setSpanError(span, Rbac.Store.errorMessage(e)); OTel.endSpan(span); Err(storeErrToApi(e)) }; case Ok(user) -> { conn.close(); OTel.setSpanAttribute(span, "user.id", user.id.toString()); OTel.endSpan(span); Ok(Rbac.Store.userToJson(user)) } }
  }
}

@get("/users/{id}")
pub func handleGetUser(id: Long): Result[String, ApiError] {
  val span = OTel.startSpan("rbac.user.get", 1)
  OTel.setSpanAttribute(span, "user.id", id.toString())
  match Db.connectFromEnv() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(Web.serviceUnavailable("database unavailable"))
    }
    case Ok(conn) -> match Rbac.Store.getUserById(conn, id) { case Err(e) -> { conn.close(); OTel.endSpan(span); Err(storeErrToApi(e)) }; case Ok(None) -> { conn.close(); OTel.endSpan(span); Err(Web.notFound("user " + id.toString() + " not found")) }; case Ok(Some(user)) -> { conn.close(); OTel.endSpan(span); Ok(Rbac.Store.userToJson(user)) } }
  }
}

@get("/users/{id}/roles")
pub func handleGetUserRoles(id: Long): Result[String, ApiError] {
  val span = OTel.startSpan("rbac.roles.list", 1)
  OTel.setSpanAttribute(span, "user.id", id.toString())
  match Db.connectFromEnv() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(Web.serviceUnavailable("database unavailable"))
    }
    case Ok(conn) -> match Rbac.Store.getRolesForUser(conn, id) { case Err(e) -> { conn.close(); OTel.endSpan(span); Err(storeErrToApi(e)) }; case Ok(assignments) -> { conn.close(); OTel.setSpanAttribute(span, "role.count", assignments.count.toString()); OTel.endSpan(span); val jsons: List[String] = newList(); for a in assignments { jsons.add(Rbac.Store.assignmentToJson(a)) }; Ok(jsonArr(jsons)) } }
  }
}

// authToken injected and validated by Auth aspect before handler body.
@post("/users/{id}/roles")
pub func handleGrantRole(id: Long, @body req: in GrantRoleRequest, authToken: String): Result[String, ApiError] {
  val span = OTel.startSpan("rbac.role.grant", 1)
  OTel.setSpanAttribute(span, "user.id", id.toString())
  OTel.setSpanAttribute(span, "role", req.role)
  OTel.setSpanAttribute(span, "grantor.id", req.grantorId.toString())
  match Db.connectFromEnv() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(Web.serviceUnavailable("database unavailable"))
    }
    case Ok(conn) -> match Rbac.Enforcement.grantRole(conn, req.grantorId, id, req.role) { case Err(e) -> { conn.close(); OTel.setSpanError(span, Rbac.Store.errorMessage(e)); OTel.endSpan(span); Err(storeErrToApi(e)) }; case Ok(_) -> { conn.close(); OTel.endSpan(span); Ok("{\"granted\":true}") } }
  }
}

@delete("/users/{id}/roles/{role}")
pub func handleRevokeRole(id: Long, role: String, authToken: String): Result[String, ApiError] {
  val span = OTel.startSpan("rbac.role.revoke", 1)
  OTel.setSpanAttribute(span, "user.id", id.toString())
  OTel.setSpanAttribute(span, "role", role)
  match Db.connectFromEnv() {
    case Err(e) -> {
      OTel.setSpanError(span, e.message)
      OTel.endSpan(span)
      Err(Web.serviceUnavailable("database unavailable"))
    }
    case Ok(conn) -> match Rbac.Store.revokeRole(conn, id, role) { case Err(e) -> { conn.close(); OTel.setSpanError(span, Rbac.Store.errorMessage(e)); OTel.endSpan(span); Err(storeErrToApi(e)) }; case Ok(_) -> { conn.close(); OTel.endSpan(span); Ok("{\"revoked\":true}") } }
  }
}

@post("/check")
pub func handleCheck(@body req: in CheckRequest): Result[String, ApiError] {
  val span = OTel.startSpan("rbac.check", 1)
  OTel.setSpanAttribute(span, "user.id", req.userId.toString())
  OTel.setSpanAttribute(span, "permission", req.permission)

  match Rbac.Policy.roleFromString(req.permission) {
    case _ -> ()    // permission is not a role; just proceed
  }
  match Rbac.Policy.permissionLabel(Permission.Read) {
    case _ -> ()    // ensure policy package is linked
  }

  // Resolve permission label to enum variant.
  val permOpt = match req.permission {
    case "read" -> Some(value = Permission.Read)
    case "write" -> Some(value = Permission.Write)
    case "delete" -> Some(value = Permission.Delete)
    case "manage_users" -> Some(value = Permission.ManageUsers)
    case "administer_all" -> Some(value = Permission.AdministerAll)
    case _ -> None
  }

  match permOpt {
    case None -> {
      OTel.endSpan(span)
      Err(Web.badRequest("unknown permission: " + req.permission))
    }
    case Some(perm) -> match Db.connectFromEnv() { case Err(e) -> { OTel.setSpanError(span, e.message); OTel.endSpan(span); Err(Web.serviceUnavailable("database unavailable")) }; case Ok(conn) -> match Rbac.Enforcement.check(conn, req.userId, perm) { case Err(e) -> { conn.close(); OTel.endSpan(span); Err(storeErrToApi(e)) }; case Ok(CheckResult.Allowed(roleName)) -> { conn.close(); OTel.setSpanAttribute(span, "check.result", "allowed"); OTel.endSpan(span); Ok("{\"allowed\":true,\"via_role\":\"" + roleName + "\"}") }; case Ok(CheckResult.Denied(reason)) -> { conn.close(); OTel.setSpanAttribute(span, "check.result", "denied"); OTel.endSpan(span); Ok("{\"allowed\":false,\"reason\":\"" + reason + "\"}") } } }
  }
}

// ─── Route table ──────────────────────────────────────────────────────────────
pub func routes(): Web.Router {
  val r = Web.create()
  val r = Web.addPost(r, "/users", "Rbac.Api.handleCreateUser")
  val r = Web.addGet(r, "/users/{id}", "Rbac.Api.handleGetUser")
  val r = Web.addGet(r, "/users/{id}/roles", "Rbac.Api.handleGetUserRoles")
  val r = Web.addPost(r, "/users/{id}/roles", "Rbac.Api.handleGrantRole")
  val r = Web.addDelete(r, "/users/{id}/roles/{role}", "Rbac.Api.handleRevokeRole")
  val r = Web.addPost(r, "/check", "Rbac.Api.handleCheck")
  return r
}
