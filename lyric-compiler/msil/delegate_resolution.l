//! delegate_resolution.l — Phase 2 metadata-based delegate type detection.
//!
//! Replaces the Phase 1 heuristic pattern matching (docs/42 #1622) with true
//! CLR metadata inspection. Walks the inheritance chain to determine if a type
//! derives from System.Delegate, enabling accurate detection of delegate types
//! without relying on naming conventions.
//!
//! This enables Phase 2 closure class synthesis with typed method signatures,
//! allowing the JIT to inline and optimize strongly-typed lambdas properly.
package Msil.DelegateResolution

import Std.Core
import Std.Collections
import Msil.MetadataReader

// Check if an extern type derives from System.Delegate by walking the
// inheritance chain in the reference-assembly metadata.
//
// Returns true if:
// - The type's extendsToken points to System.Delegate (via TypeRef or TypeDef)
// - The type's base class derives from System.Delegate (recursive walk)
//
// This enables accurate delegate detection without relying on naming heuristics.
pub func isDelegateType(
  img: in PeImage,
  layout: in TableLayout,
  th: in TablesHeader,
  typeRow: in Int
): Bool {
  val typeDef = readTypeDef(img, layout, typeRow)
  if typeDef.extendsToken == 0 {
    return false  // No base class = not a delegate
  }

  // Decode the TypeDefOrRef coded index to determine if it's a TypeDef or TypeRef
  // Coded index format: low 2 bits are table indicator, rest is row number
  // 00 = TypeDef, 01 = TypeRef, 10 = TypeSpec
  val tableId = typeDef.extendsToken and 0x03
  val rowNum = (typeDef.extendsToken - tableId) / 4

  match tableId {
    case 0x00 -> {
      // Extends a TypeDef: recursively check if it's a delegate
      isDelegateType(img, layout, th, rowNum)
    }
    case 0x01 -> {
      // Extends a TypeRef: check if it's System.Delegate
      val typeRef = readTypeRef(img, layout, rowNum)
      isSystemDelegate(typeRef)
    }
    case _ -> false  // TypeSpec or unknown
  }
}

// Check if a TypeRef represents System.Delegate exactly.
func isSystemDelegate(typeRef: in TypeRefRow): Bool {
  typeRef.namespaceName == "System" and typeRef.name == "Delegate"
}

// Determine if a reference-assembly type name (namespace.name) is a delegate
// by loading its metadata and walking the inheritance chain.
pub func isDelegateByName(
  assemblyPath: in String,
  typeFullName: in String
): Result[Bool, String] {
  // Read the assembly metadata
  val peResult = readPeFile(assemblyPath)
  match peResult {
    case Err(e) -> Err(e)
    case Ok(img) -> {
      // Parse metadata structures
      val rootResult = readMetadataRoot(img)
      match rootResult {
        case Err(e) -> Err(e)
        case Ok(root) -> {
          val thResult = readTablesHeader(img, root)
          match thResult {
            case Err(e) -> Err(e)
            case Ok(th) -> {
              val layoutResult = computeLayout(img, root, th)
              match layoutResult {
                case Err(e) -> Err(e)
                case Ok(layout) -> {
                  // Find the TypeDef by name
                  val typeRow = findTypeDefByName(img, layout, th, typeFullName)
                  match typeRow {
                    case None -> Ok(false)  // Type not found
                    case Some(row) -> Ok(isDelegateType(img, layout, th, row))
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

// Find a TypeDef row by its full name (namespace.name).
func findTypeDefByName(
  img: in PeImage,
  layout: in TableLayout,
  th: in TablesHeader,
  fullName: in String
): Option[Int] {
  val numTypeDefs = rowCountOf(th, 0x01)  // Table 0x01 = TypeDef
  var i = 1
  while i <= numTypeDefs {
    val typeDef = readTypeDef(img, layout, i)
    val typeFullName = if typeDef.namespaceName.length == 0 {
      typeDef.name
    } else {
      typeDef.namespaceName + "." + typeDef.name
    }
    if typeFullName == fullName {
      return Some(value = i)
    }
    i = i + 1
  }
  None
}

// Helper to read a PE file from disk.
func readPeFile(path: in String): Result[PeImage, String] {
  val fileResult = readFile(path)
  match fileResult {
    case Err(e) -> Err("Failed to read assembly: " + e)
    case Ok(bytes) -> readPe(bytes)
  }
}

// FFI binding to read file bytes.  Errors are propagated as empty results.
@externTarget("System.IO.File.ReadAllBytes")
func readFileBytes(path: in String): slice[Byte] = ()

func readFile(path: in String): Result[slice[Byte], String] {
  val bytes = readFileBytes(path)
  if bytes.length > 0 {
    Ok(value = bytes)
  } else {
    Err("Failed to read file")
  }
}
