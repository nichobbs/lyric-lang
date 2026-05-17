// typechecker_scope.l — lexical scope and generic-context stacks.
// Mirrors compiler/src/Lyric.TypeChecker/Scope.fs.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer

// ─────────────────────────────────────────────────────────────────────────────
// §1. Local binding — a single val/var/let or parameter in scope.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record LocalBinding {
  name:      String
  ty:        Type
  isMutable: Bool
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Scope — stack of lexical frames (flat list + watermark indices).
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record Scope {
  bindings:    List[LocalBinding]
  frameStarts: List[Int]
}

pub func newScope(): Scope {
  val bindings: List[LocalBinding] = newList()
  val starts: List[Int] = newList()
  starts.add(0)
  Scope(bindings = bindings, frameStarts = starts)
}

pub func scopePush(sc: in Scope): Unit {
  sc.frameStarts.add(sc.bindings.count)
}

pub func scopePop(sc: in Scope): Unit {
  val n = sc.frameStarts.count
  if n > 1 {
    val start     = sc.frameStarts[n - 1]
    val toRemove  = sc.bindings.count - start
    var j = 0
    while j < toRemove {
      sc.bindings.removeAt(sc.bindings.count - 1)
      j = j + 1
    }
    sc.frameStarts.removeAt(n - 1)
  }
}

pub func scopeAdd(sc: in Scope, b: in LocalBinding): Unit {
  sc.bindings.add(b)
}

pub func scopeTryFind(sc: in Scope, name: in String): Option[LocalBinding] {
  var i = sc.bindings.count - 1
  while i >= 0 {
    if sc.bindings[i].name == name { return Some(value = sc.bindings[i]) }
    i = i - 1
  }
  None
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. GenericContext — type-parameter names currently in scope.
// ─────────────────────────────────────────────────────────────────────────────

@stable(since="0.1")
pub record GenericContext {
  params:      List[String]
  stackDepths: List[Int]
}

pub func newGenericContext(): GenericContext {
  val params: List[String] = newList()
  val depths: List[Int]    = newList()
  GenericContext(params = params, stackDepths = depths)
}

pub func gctxPush(ctx: in GenericContext, names: in List[String]): Unit {
  ctx.stackDepths.add(ctx.params.count)
  var i = 0
  while i < names.count {
    ctx.params.add(names[i])
    i = i + 1
  }
}

pub func gctxPop(ctx: in GenericContext): Unit {
  val n = ctx.stackDepths.count
  if n > 0 {
    val start    = ctx.stackDepths[n - 1]
    val toRemove = ctx.params.count - start
    var j = 0
    while j < toRemove {
      ctx.params.removeAt(ctx.params.count - 1)
      j = j + 1
    }
    ctx.stackDepths.removeAt(n - 1)
  }
}

pub func gctxIsTypeParam(ctx: in GenericContext, name: in String): Bool {
  var i = 0
  while i < ctx.params.count {
    if ctx.params[i] == name { return true }
    i = i + 1
  }
  false
}
