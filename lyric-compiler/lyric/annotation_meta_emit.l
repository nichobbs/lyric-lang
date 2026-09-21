//! lyric/annotation_meta_emit.l — Lyric.AnnotationMetaEmit package.
//!
//! Compile-time half of the custom-annotation runtime-metadata capability
//! (#6866, D-progress-941). Walks a parsed `SourceFile`'s `config { }`
//! blocks and serializes every field annotation (name + args) to a small
//! JSON array, embedded as a `Lyric.AnnotationMeta`[.`<Pkg>`] resource
//! alongside the existing `Lyric.Contract` resource (`Msil.Bridge`'s
//! `embedLyricContract` / `Jvm.Bridge`'s `contractZipEntry`).
//!
//! Unlike `Lyric.ContractMetaEmit`'s v3 contract metadata, this schema is
//! NOT hash-wrapped: contract metadata's two-pass SHA-256 protocol exists
//! to let a DOWNSTREAM CONSUMER verify a dependency's contract wasn't
//! tampered with across a package boundary. Annotation metadata has no such
//! boundary — per D-progress-941's design, it is read back only by the
//! runtime reader (docs/6866 PR 2) locating and parsing ITS OWN assembly's
//! resource, never a dependency's. A future second consumer that needs
//! tamper detection can add a format-version + hash field then; starting
//! unversioned avoids emitting protocol machinery no one reads yet.
//!
//! Public entry points:
//!   collectAnnotatedFields(file): List[AnnotatedField]
//!   emitAnnotationMetaJson(fields): String
package Lyric.AnnotationMetaEmit

import Std.Core
import Std.Collections
import Std.Json
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Data model
// ─────────────────────────────────────────────────────────────────────────────
/// One annotation found on one `config { }` field.  `argName` is `""` for a
/// positional (`ALiteral`) or bare (`ABare`) arg — `argKind` distinguishes
/// the two: `"bare"` for `ABare` (where `argValue` carries the bare
/// identifier itself), one of `"string"`/`"int"`/`"bool"`/`"ident"` for a
/// `AAName`/`ALiteral` value, matching `AnnotationValue`'s four cases.
pub record AnnotatedArg {
  argName: String
  argKind: String
  argValue: String
}

pub record AnnotatedField {
  configName: String
  fieldName: String
  annotationName: String
  args: List[AnnotatedArg]
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Collection — walk `config { }` blocks for field annotations
// ─────────────────────────────────────────────────────────────────────────────
func dottedAnnotationName(a: in Annotation): String {
  var s = ""
  var i = 0
  while i < a.name.segments.count {
    if i > 0 {
      s = s + "."
    }
    s = s + a.name.segments[i]
    i = i + 1
  }
  s
}

func annotationValueKind(v: in AnnotationValue): String {
  match v {
    case AVInt(_, _) -> "int"
    case AVString(_, _) -> "string"
    case AVBool(_, _) -> "bool"
    case AVIdent(_, _) -> "ident"
  }
}

func annotationValueString(v: in AnnotationValue): String {
  match v {
    case AVInt(n, _) -> n.toString()
    case AVString(s, _) -> s
    case AVBool(b, _) -> if b then "true" else "false"
    case AVIdent(s, _) -> s
  }
}

func collectArgs(anns: in Annotation): List[AnnotatedArg] {
  val acc: List[AnnotatedArg] = newList()
  var i = 0
  while i < anns.args.count {
    match anns.args[i] {
      case AAName(name, value, _) -> acc.add(
        AnnotatedArg(
          argName = name,
          argKind = annotationValueKind(value),
          argValue = annotationValueString(value)
        )
      )
      case ABare(name, _) -> acc.add(AnnotatedArg(argName = "", argKind = "bare", argValue = name))
      case ALiteral(value, _) -> acc.add(
        AnnotatedArg(
          argName = "",
          argKind = annotationValueKind(value),
          argValue = annotationValueString(value)
        )
      )
    }
    i = i + 1
  }
  acc
}

func collectFieldAnnotations(configName: in String, field: in ConfigField): List[AnnotatedField] {
  val acc: List[AnnotatedField] = newList()
  var i = 0
  while i < field.annotations.count {
    val a = field.annotations[i]
    acc.add(
      AnnotatedField(
        configName = configName,
        fieldName = field.name,
        annotationName = dottedAnnotationName(a),
        args = collectArgs(a)
      )
    )
    i = i + 1
  }
  acc
}

/// Every `(config, field, annotation, args)` tuple in `file`'s `config { }`
/// blocks, in source order. Empty list when the file declares no
/// annotated config fields (the common case) — callers still embed the
/// resource with an empty JSON array rather than omitting it, so a reader
/// never has to distinguish "no resource" from "no annotated fields".
pub func collectAnnotatedFields(file: in SourceFile): List[AnnotatedField] {
  val acc: List[AnnotatedField] = newList()
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IConfig(decl) -> {
        var fi = 0
        while fi < decl.fields.count {
          val found = collectFieldAnnotations(decl.name, decl.fields[fi])
          var fj = 0
          while fj < found.count {
            acc.add(found[fj])
            fj = fj + 1
          }
          fi = fi + 1
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  acc
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. JSON serialization — hand-rolled, mirroring
// `Lyric.ContractMetaEmit`'s minimal serializer (`Std.Json` is a parser,
// not a serializer).
// ─────────────────────────────────────────────────────────────────────────────
func jsonString(s: in String): String {
  Std.Json.encodeString(s)
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

func emitArg(a: in AnnotatedArg): String {
  val fields: List[(String, String)] = newList()
  fields.add(("name", jsonString(a.argName)))
  fields.add(("kind", jsonString(a.argKind)))
  fields.add(("value", jsonString(a.argValue)))
  jsonObject(fields)
}

func emitArgs(args: in List[AnnotatedArg]): String {
  val items: List[String] = newList()
  for a in args.toArray() {
    items.add(emitArg(a))
  }
  jsonArray(items)
}

func emitField(f: in AnnotatedField): String {
  val fields: List[(String, String)] = newList()
  fields.add(("config", jsonString(f.configName)))
  fields.add(("field", jsonString(f.fieldName)))
  fields.add(("annotation", jsonString(f.annotationName)))
  fields.add(("args", emitArgs(f.args)))
  jsonObject(fields)
}

/// Serialize `fields` to the `Lyric.AnnotationMeta` JSON payload: a bare
/// JSON array of `{config, field, annotation, args: [{name, kind, value}]}`
/// objects, in the order `collectAnnotatedFields` returned them.
pub func emitAnnotationMetaJson(fields: in List[AnnotatedField]): String {
  val items: List[String] = newList()
  for f in fields.toArray() {
    items.add(emitField(f))
  }
  jsonArray(items)
}
