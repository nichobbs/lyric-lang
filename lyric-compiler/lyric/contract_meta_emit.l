//! lyric/contract_meta_emit.l — Lyric.ContractMetaEmit package.
//!
//! Emits contract metadata version 3 with SHA-256 integrity hashing.
//! Two-pass protocol:
//!   1. Serialize with blank contractHash
//!   2. Compute SHA-256 of serialized JSON
//!   3. Re-serialize with contractHash field populated
//!
//! **Current status (Phase 1.2b):** Available for self-hosted compiler use only.
//! The bootstrap emitter (F# stage-0) continues using v2 contract metadata
//! (via Meta.contractToJson) for backward compatibility. Integration of v3
//! into the bootstrap path is deferred pending issue #2580 infrastructure
//! (in-process MSIL bridge support for self-hosted compiler packages).
//!
//! Per docs/45, this is the sole source of truth for v3 contract metadata
//! emission in the self-hosted compiler path.
//!
//! Public entry point: emitContractMetadata(contract: in Meta.Contract): String
@runtime_checked
package Lyric.ContractMetaEmit

import Std.Core
import Std.Collections
import Std.Hash
import Std.Json
import Std.Encoding
import Lyric.ContractMeta as Meta

// ─────────────────────────────────────────────────────────────────────────────
// §1. JSON building helpers (minimal serializer for contract metadata)
// ─────────────────────────────────────────────────────────────────────────────
// Build a JSON string by concatenating parts. No actual JSON library yet,
// so we hand-construct the structure. This is intentionally simple and
// focused on the contract metadata shape only.
func jsonString(s: in String): String {
  Std.Json.encodeString(s)
}

func jsonNumber(n: in Int): String {
  n.toString()
}

func jsonBool(b: in Bool): String {
  if b then "true" else "false"
}

func jsonArray(items: in List[String]): String {
  if items.length == 0 {
    "[]"
  } else {
    var buf = "["
    var i = 0
    while i < items.length {
      if i > 0 {
        buf = buf + ","
      }
      buf = buf + items[i]
      i = i + 1
    }
    buf + "]"
  }
}

func jsonObject(fields: in List[(String, String)]): String {
  if fields.length == 0 {
    "{}"
  } else {
    var buf = "{"
    var i = 0
    while i < fields.length {
      if i > 0 {
        buf = buf + ","
      }
      val (k, v) = fields[i]
      buf = buf + jsonString(k) + ":" + v
      i = i + 1
    }
    buf + "}"
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. ContractParam JSON serialization
// ─────────────────────────────────────────────────────────────────────────────
func emitParam(p: in Meta.ContractParam): String {
  val fields: List[(String, String)] = newList()
  fields.add(("name", jsonString(p.name)))
  fields.add(("type", jsonString(p.ty)))
  jsonObject(fields)
}

func emitParams(params: in List[Meta.ContractParam]): String {
  val items: List[String] = newList()
  for p in params.toArray() {
    items.add(emitParam(p))
  }
  jsonArray(items)
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. ContractDecl JSON serialization
// ─────────────────────────────────────────────────────────────────────────────
func emitDecl(d: in Meta.ContractDecl): String {
  val fields: List[(String, String)] = newList()

  fields.add(("kind", jsonString(d.kind)))
  fields.add(("name", jsonString(d.name)))
  fields.add(("repr", jsonString(d.repr)))
  fields.add(("visibility", jsonString(d.visibility)))
  fields.add(("pure", jsonBool(d.isPure)))
  fields.add(("stability", jsonString(d.stability)))

  // Requires clauses
  val requiresItems: List[String] = newList()
  for clause in d.requiresClauses.toArray() {
    requiresItems.add(jsonString(clause))
  }
  fields.add(("requiresClauses", jsonArray(requiresItems)))

  // Ensures clauses
  val ensuresItems: List[String] = newList()
  for clause in d.ensuresClauses.toArray() {
    ensuresItems.add(jsonString(clause))
  }
  fields.add(("ensuresClauses", jsonArray(ensuresItems)))

  // Body (always emit field for consistent schema)
  val bodyJson = match d.body { case Some(b) -> jsonString(b); case None -> "null" }
  fields.add(("body", bodyJson))

  // Parameters
  fields.add(("params", emitParams(d.params)))

  jsonObject(fields)
}

func emitDecls(decls: in List[Meta.ContractDecl]): String {
  val items: List[String] = newList()
  for d in decls.toArray() {
    items.add(emitDecl(d))
  }
  jsonArray(items)
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. ContractDependency JSON serialization
// ─────────────────────────────────────────────────────────────────────────────
func emitDependency(dep: in Meta.ContractDependency): String {
  val fields: List[(String, String)] = newList()
  fields.add(("packageName", jsonString(dep.packageName)))
  fields.add(("version", jsonString(dep.version)))
  fields.add(("contractHash", jsonString(dep.contractHash)))
  jsonObject(fields)
}

func emitDependencies(deps: in List[Meta.ContractDependency]): String {
  val items: List[String] = newList()
  for d in deps.toArray() {
    items.add(emitDependency(d))
  }
  jsonArray(items)
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Contract serialization with SHA-256 integrity hashing
// ─────────────────────────────────────────────────────────────────────────────
func emitContractJson(contract: in Meta.Contract, contractHash: in String): String {
  val fields: List[(String, String)] = newList()
  fields.add(("packageName", jsonString(contract.packageName)))
  fields.add(("version", jsonString(contract.version)))
  fields.add(("level", jsonString(contract.level)))
  fields.add(("formatVersion", jsonNumber(contract.formatVersion)))
  fields.add(("contractHash", jsonString(contractHash)))
  fields.add(("dependencies", emitDependencies(contract.dependencies)))
  fields.add(("decls", emitDecls(contract.decls)))
  jsonObject(fields)
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Public entry point: two-pass hashing protocol
// ─────────────────────────────────────────────────────────────────────────────
/// Emit contract metadata v3 with SHA-256 integrity hashing.
///
/// Two-pass protocol:
///   1. Serialize with blank contractHash
///   2. Compute SHA-256 of serialized JSON (as uppercase hex string)
///   3. Re-serialize with contractHash field populated
///
/// The returned JSON can be embedded as a DLL resource and later parsed
/// by Lyric.ContractMeta.parseFromJson for validation and symbol table
/// construction.
pub func emitContractMetadata(contract: in Meta.Contract): String {
  val blankJson = emitContractJson(contract, "")
  val hashBytes = Std.Encoding.encodeUtf8(blankJson)
  val contractHash = Std.Hash.sha256OfBytes(hashBytes)
  emitContractJson(contract, contractHash)
}
