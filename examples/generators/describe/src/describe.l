//! Acme.Describe — a custom source generator (docs/40 §6).
//!
//! For each record annotated `@generate(Acme.Describe)` it emits
//! `<Type>.describe(v): String`, which renders the type's name and fields
//! as `Order { id: Int, note: String }`.  A union or interface gets a
//! warning and no code.
@runtime_checked
@io
package Acme.Describe

import Std.Core
import Std.Collections
import Lyric.GeneratorSdk

pub func generate(req: in GeneratorRequest): GeneratorResponse {
  val td = req.typeDescriptor
  val noImports: List[String] = newList()
  val diags: List[GeneratorDiagnostic] = newList()
  match td.kind {
    case Union -> {
      diags.add(
        GeneratorDiagnostic(severity = Warning, message = describeOnlyRecords(td.name), code = Some(value = "AD001"))
      )
      return GeneratorResponse(lyricSource = "", additionalImports = noImports.toArray(), diagnostics = diags.toArray())
    }
    case Interface -> {
      diags.add(
        GeneratorDiagnostic(severity = Warning, message = describeOnlyRecords(td.name), code = Some(value = "AD001"))
      )
      return GeneratorResponse(lyricSource = "", additionalImports = noImports.toArray(), diagnostics = diags.toArray())
    }
    case _ -> ()
  }
  var fields = ""
  var i = 0
  while i < td.fields.length {
    val f = td.fields[i]
    if i > 0 {
      fields = fields + ", "
    }
    fields = fields + f.name + ": " + f.fieldType.name
    i += 1
  }
  val rendered = td.name + " { " + fields + " }"
  val src = "pub func " + td.name + ".describe(v: in " + td.name + "): String {\n  \"" + rendered + "\"\n}\n"
  GeneratorResponse(lyricSource = src, additionalImports = noImports.toArray(), diagnostics = diags.toArray())
}

func describeOnlyRecords(name: in String): String {
  "Acme.Describe describes records only; '" + name + "' gets no describe()"
}

func main(): Int {
  runGenerator(generate)
}
