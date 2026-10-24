//! std/annotation_meta.l - Std.AnnotationMeta: runtime access to the
//! annotations written on `config { }` fields (#6866, D-progress-941).
//!
//! The compiler embeds, per compiled package, a small JSON document listing
//! every annotation found on a `config { }` field (a `Lyric.AnnotationMeta`
//! managed resource on .NET, a `Lyric.AnnotationMeta.<Pkg>` JAR entry on the
//! JVM).  This module reads those documents back from the running program
//! and decodes them, so a library can discover which fields carry its own
//! annotation without reflection of its own.  `lyric-aws-secrets` uses it to
//! find `@secretsManager` / `@parameterStore` fields.
//!
//! Scope: `config { }` field annotations only, every package of every
//! loaded assembly (.NET) or class-path jar (JVM).  Annotation arguments are
//! reported as the strings the source wrote, tagged with their kind; nothing
//! is evaluated.
//!
//! Targets: .NET and JVM.  The native backend embeds no annotation
//! metadata yet, so every query returns `Unsupported` there instead of an
//! empty list that would be indistinguishable from "no annotated fields".
@runtime_checked
@io
package Std.AnnotationMeta

import Std.Core
import Std.Collections
import Std.JsonValue
import Std.AnnotationMetaHost

/// One argument of an annotation.  `name` is `""` for a positional or bare
/// argument.  `kind` is one of `"string"`, `"int"`, `"bool"`, `"ident"` (a
/// literal or bare-word value, with `value` holding its text without
/// quotes), `"bare"` (a bare identifier argument; `value` is the
/// identifier), or `"call"` (a nested `name(...)` argument; only the head
/// name is recorded in `value`).
@stable(since = "0.1")
pub record AnnotationArg {
  name: String
  kind: String
  value: String
}

/// One annotation on one `config { }` field.  `annotationName` is the
/// dotted annotation name without the leading `@`.
@stable(since = "0.1")
pub record AnnotatedField {
  configName: String
  fieldName: String
  annotationName: String
  args: List[AnnotationArg]
}

/// Why annotation metadata could not be produced.
@stable(since = "0.1")
pub union AnnotationMetaError {
  /// This target does not embed annotation metadata (native).  Retrying
  /// will never succeed.
  case Unsupported(reason: String)
  /// An embedded document is not a well-formed annotation-metadata
  /// document.  `message` names the offending part.
  case Malformed(message: String)
}

/// Human-readable message for logging.
@stable(since = "0.1")
pub func errorMessage(err: in AnnotationMetaError): String {
  match err {
    case Unsupported(reason) -> "annotation metadata unsupported: " + reason
    case Malformed(message) -> "malformed annotation metadata: " + message
  }
}

func malformed(message: in String): AnnotationMetaError {
  Malformed(message = message)
}

func requireString(obj: in JsonValue, key: in String, what: in String): Result[String, AnnotationMetaError] {
  match getString(obj, key) {
    case Some(s) -> Ok(value = s)
    case None -> Err(error = malformed(what + " is missing string member '" + key + "'"))
  }
}

func decodeArg(v: in JsonValue, site: in String): Result[AnnotationArg, AnnotationMetaError] {
  match requireString(v, "name", site) {
    case Err(e) -> Err(error = e)
    case Ok(name) -> match requireString(v, "kind", site) {
      case Err(e) -> Err(error = e)
      case Ok(kind) -> match requireString(v, "value", site) {
        case Err(e) -> Err(error = e)
        case Ok(value) -> Ok(
          value = AnnotationArg(
            name = name,
            kind = kind,
            value = value
          )
        )
      }
    }
  }
}

func decodeArgs(v: in JsonValue, site: in String): Result[List[AnnotationArg], AnnotationMetaError] {
  match getArray(v, "args") {
    case None -> Err(error = malformed(site + " is missing array member 'args'"))
    case Some(items) -> {
      val acc: List[AnnotationArg] = newList()
      var i = 0
      while i < items.count {
        match decodeArg(items[i], site + " args[" + i.toString() + "]") {
          case Err(e) -> return Err(error = e)
          case Ok(a) -> acc.add(a)
        }
        i = i + 1
      }
      Ok(value = acc)
    }
  }
}

func decodeField(v: in JsonValue, site: in String): Result[AnnotatedField, AnnotationMetaError] {
  match requireString(v, "config", site) {
    case Err(e) -> Err(error = e)
    case Ok(configName) -> match requireString(v, "field", site) {
      case Err(e) -> Err(error = e)
      case Ok(fieldName) -> match requireString(v, "annotation", site) {
        case Err(e) -> Err(error = e)
        case Ok(annotationName) -> match decodeArgs(v, site) {
          case Err(e) -> Err(error = e)
          case Ok(args) -> Ok(
            value = AnnotatedField(
              configName = configName,
              fieldName = fieldName,
              annotationName = annotationName,
              args = args
            )
          )
        }
      }
    }
  }
}

/// Decode one `Lyric.AnnotationMeta` JSON document (a JSON array of
/// `{config, field, annotation, args: [{name, kind, value}]}` objects) into
/// its annotated fields, in document order.  Pure; exposed so the decoder is
/// testable without an embedded resource.
@stable(since = "0.1")
pub func parseAnnotationMeta(json: in String): Result[List[AnnotatedField], AnnotationMetaError] {
  match parseValue(json) {
    case Err(e) -> Err(error = malformed(JsonParseError.message(e)))
    case Ok(root) -> match asArray(root) {
      case None -> Err(error = malformed("document is not a JSON array"))
      case Some(items) -> {
        val acc: List[AnnotatedField] = newList()
        var i = 0
        while i < items.count {
          match decodeField(items[i], "entry " + i.toString()) {
            case Err(e) -> return Err(error = e)
            case Ok(f) -> acc.add(f)
          }
          i = i + 1
        }
        Ok(value = acc)
      }
    }
  }
}

/// Every annotated `config { }` field of every package embedded in the
/// running program, in package then source order.
///
/// # Errors
/// - `Unsupported`: the target embeds no annotation metadata (native).
/// - `Malformed`: an embedded document does not decode.
@stable(since = "0.1")
pub func allAnnotatedFields(): Result[List[AnnotatedField], AnnotationMetaError] {
  if not hostAnnotationMetaSupported() {
    return Err(
      error = Unsupported(
        reason = "this target does not embed Lyric.AnnotationMeta (native emission is not implemented)"
      )
    )
  }
  val docs = hostAnnotationMetaDocuments()
  val acc: List[AnnotatedField] = newList()
  var d = 0
  while d < docs.length {
    match parseAnnotationMeta(docs[d]) {
      case Err(e) -> return Err(error = e)
      case Ok(fields) -> {
        var i = 0
        while i < fields.count {
          acc.add(fields[i])
          i = i + 1
        }
      }
    }
    d = d + 1
  }
  Ok(value = acc)
}

func stripAt(name: in String): String {
  if name.startsWith("@") {
    name.substring(1)
  } else {
    name
  }
}

/// The annotated `config { }` fields carrying `annotationName` (with or
/// without the leading `@`, dotted for a qualified annotation), in package
/// then source order.  A field with several annotations appears once per
/// matching annotation; a field annotated twice with the same name appears
/// twice.  An empty list means the program has no such annotation.
///
/// # Errors
/// - `Unsupported`: the target embeds no annotation metadata (native).
/// - `Malformed`: an embedded document does not decode.
@stable(since = "0.1")
pub func fieldsWithAnnotation(annotationName: in String): Result[List[AnnotatedField], AnnotationMetaError]
  requires: annotationName.length > 0
{
  val wanted = stripAt(annotationName)
  match allAnnotatedFields() {
    case Err(e) -> Err(error = e)
    case Ok(all) -> {
      val acc: List[AnnotatedField] = newList()
      var i = 0
      while i < all.count {
        if all[i].annotationName == wanted {
          acc.add(all[i])
        }
        i = i + 1
      }
      Ok(value = acc)
    }
  }
}

/// The value of the argument written `name: value`, if present.  The first
/// match wins.
@stable(since = "0.1")
pub func namedArg(f: in AnnotatedField, name: in String): Option[String] {
  var i = 0
  while i < f.args.count {
    if f.args[i].name == name and name.length > 0 {
      return Some(value = f.args[i].value)
    }
    i = i + 1
  }
  None
}

/// The value of the `index`th positional (unnamed) argument, counting from
/// zero, if present.
@stable(since = "0.1")
pub func positionalArg(f: in AnnotatedField, index: in Int): Option[String] {
  var seen = 0
  var i = 0
  while i < f.args.count {
    if f.args[i].name.length == 0 {
      if seen == index {
        return Some(value = f.args[i].value)
      }
      seen = seen + 1
    }
    i = i + 1
  }
  None
}
