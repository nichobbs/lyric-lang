//! Ui.Session — the pure core of the per-session loop
//! (docs/65-ui-library-sketch.md §8).
//! Stability: @experimental — Phase U1 of docs/65.
//!
//! A session owns the current model and the last rendered tree.  Each step
//! (start, a dispatched message, or a host event) returns an `Output`: the
//! next session, the patches to send, the application effects to run, and
//! the host commands (navigation, toasts) to forward.  The step functions
//! are pure: drivers (`Ui.Host.*`) own the message queue, the transport and
//! the concurrent execution of effects, and tests drive a session directly.
//!
//! The rendered tree wraps the application view in a fixed two-child root,
//! `column[app, overlay]`, where `overlay` shows a pending confirmation
//! dialog.  Host paths therefore start with `0` for the application view.
//!
//! Host events name nodes by key where a node has one (D138, Q-UI-005):
//! `handleEvent` resolves a key only when exactly one sibling carries it, so
//! an event aimed at a row that has since moved still reaches that row, and
//! one aimed at a row that is gone is dropped instead of reaching whichever
//! row took its place.
//!
//! A session whose host has disconnected is `detach`ed: the rendered tree is
//! dropped (it is derivable from the model because `view` is pure) and
//! `resume` renders it again when a host reconnects (D138, Q-UI-007).
@runtime_checked
package Ui.Session

import Std.Core
import Ui.Core.{View, Element, Text, Empty, Handler, OnClick, Prop, WidgetKind, Step, UiEffect, Navigate, Back, Confirm, Notify, toastLevelName, eventName, fire, mapView, childrenOf}
import Ui.Diff.{Patch, SetProp, diff, replaceAll, keyOf}
import Ui.Protocol.{Event, NodeRef, At, Keyed, ValueEcho, refsKey, pathKey}

// ─── Program ──────────────────────────────────────────────────────────────────
/// What a session runs: the screen's pure functions, and how to recognise
/// the effects the UI runtime interprets itself.
pub record Program[M, Msg, E] {
  update: (M, Msg) -> Step[M, E]
  view: (M) -> View[Msg]
  uiEffect: (E) -> Option[UiEffect[Msg]]
}

/// Messages of the rendered tree: application messages plus the session's
/// own (answering the confirmation dialog).
pub union SessionMsg[Msg] {
  case App(msg: Msg)
  case AnswerDialog(yes: Bool)
}

/// A confirmation dialog waiting for an answer.
pub record PendingDialog[Msg] {
  question: String
  onYes: Msg
}

/// A command for the host that is not a tree patch.
pub union HostCommand {
  case NavigateTo(url: String)
  case GoBack
  case ShowToast(message: String, level: String)
}

/// The input version last processed for one text input, identified by its
/// event path (keys where the path's nodes have them), so the record follows
/// the input when its row moves.
pub record InputVersion {
  key: String
  path: List[NodeRef]
  version: Int
}

/// The state of one session.  `tree` is `Empty` while the session is
/// detached.
pub record Session[M, Msg] {
  model: M
  tree: View[SessionMsg[Msg]]
  version: Int
  dialog: Option[PendingDialog[Msg]]
  inputVersions: List[InputVersion]
}

/// The result of one step.  `dropped` is true when a host event did not
/// resolve to a handler (stale path or unknown event); nothing else changes
/// in that case and the driver logs it.  `echoes` are the input versions to
/// send with this step's `value` patches.
pub record Output[M, Msg, E] {
  session: Session[M, Msg]
  patches: List[Patch]
  echoes: List[ValueEcho]
  effects: List[E]
  commands: List[HostCommand]
  dropped: Bool
}

// ─── Steps ────────────────────────────────────────────────────────────────────
/// A new session from the screen's initial step.  The patches replace the
/// host's whole tree.
pub func start[M, Msg, E](p: in Program[M, Msg, E], init: in Step[M, E]): Output[M, Msg, E] {
  val noDialog: Option[PendingDialog[Msg]] = None
  val effects: List[E] = init.effects
  val model: M = init.model
  val split: Split[E, Msg] = splitEffects(p, effects, noDialog)
  val dialog: Option[PendingDialog[Msg]] = split.dialog
  val tree: View[SessionMsg[Msg]] = render(p, model, dialog)
  val ivs: List[InputVersion] = newList()
  val s: Session[M, Msg] = Session(model = model, tree = tree, version = 1, dialog = dialog, inputVersions = ivs)
  return output(s, replaceAll(tree), split, false)
}

/// Applies an application message (typically an effect's result).
pub func dispatch[M, Msg, E](p: in Program[M, Msg, E], s: in Session[M, Msg], msg: in Msg): Output[M, Msg, E] {
  val before: M = s.model
  val st: Step[M, E] = p.update(before, msg)
  val effects: List[E] = st.effects
  val model: M = st.model
  val pending: Option[PendingDialog[Msg]] = s.dialog
  val split: Split[E, Msg] = splitEffects(p, effects, pending)
  val dialog: Option[PendingDialog[Msg]] = split.dialog
  return rerender(p, s, model, dialog, split, s.inputVersions)
}

/// Resolves a host event against the current tree and applies the message
/// it produces.  Input events record their input version (docs/65 §9.4).
pub func handleEvent[M, Msg, E](p: in Program[M, Msg, E], s: in Session[M, Msg], ev: in Event): Output[M, Msg, E] {
  val current: View[SessionMsg[Msg]] = s.tree
  val found: Option[Handler[SessionMsg[Msg]]] = handlerAt(current, ev.path, ev.name)
  val handler: Handler[SessionMsg[Msg]] = match found { case Some(h) -> h; case None -> return unchanged(p, s, true) }
  val ivs = if ev.inputVersion > 0 then recordInputVersion(s.inputVersions, ev.path, ev.inputVersion) else s.inputVersions
  val s1: Session[M, Msg] = withInputVersions(s, ivs)
  val fired: SessionMsg[Msg] = fire(handler, ev.data)
  return match fired {
    case App(m) -> dispatch(p, s1, m)
    case AnswerDialog(yes) -> {
      val noDialog: Option[PendingDialog[Msg]] = None
      val model: M = s1.model
      val tree: View[SessionMsg[Msg]] = s1.tree
      val closed = Session(model = model, tree = tree, version = s1.version, dialog = noDialog, inputVersions = ivs)
      val pending: Option[PendingDialog[Msg]] = s1.dialog
      match pending {
        case Some(d) -> if yes {
          val onYes: Msg = d.onYes
          dispatch(p, closed, onYes)
        } else {
          val none: List[E] = newList()
          val split = splitEffects(p, none, noDialog)
          rerender(p, closed, model, noDialog, split, ivs)
        }
        case None -> unchanged(p, s1, true)
      }
    }
  }
}

/// The patches that bring a host up to date after it lost track of the
/// tree: a replacement of the whole tree.
pub func resync[M, Msg](s: in Session[M, Msg]): List[Patch] {
  return replaceAll(s.tree)
}

/// `s` without its rendered tree and input versions, for a session whose
/// host has disconnected.  The model and any pending dialog are kept.
pub func detach[M, Msg](s: in Session[M, Msg]): Session[M, Msg] {
  val model: M = s.model
  val dialog: Option[PendingDialog[Msg]] = s.dialog
  val ivs: List[InputVersion] = newList()
  val none: View[SessionMsg[Msg]] = Empty
  return Session(model = model, tree = none, version = s.version, dialog = dialog, inputVersions = ivs)
}

/// `s` rendered again for a reconnected host: the whole tree, under a new
/// render version so events aimed at the old tree are recognisably stale.
pub func resume[M, Msg, E](p: in Program[M, Msg, E], s: in Session[M, Msg]): Output[M, Msg, E] {
  val model: M = s.model
  val dialog: Option[PendingDialog[Msg]] = s.dialog
  val tree: View[SessionMsg[Msg]] = render(p, model, dialog)
  val ivs: List[InputVersion] = newList()
  val next: Session[M, Msg] = Session(model = model, tree = tree, version = s.version + 1, dialog = dialog, inputVersions = ivs)
  val none: List[E] = newList()
  val noDialog: Option[PendingDialog[Msg]] = None
  val split: Split[E, Msg] = splitEffects(p, none, noDialog)
  return output(next, replaceAll(tree), split, false)
}

// ─── Internals ────────────────────────────────────────────────────────────────
pub record Split[E, Msg] {
  appEffects: List[E]
  commands: List[HostCommand]
  dialog: Option[PendingDialog[Msg]]
}

// Separates the effects the runtime interprets from the application's own.
// A new `Confirm` replaces any pending dialog.
pub func splitEffects[M, Msg, E](
  p: in Program[M, Msg, E], effects: in List[E], dialog: in Option[PendingDialog[Msg]]
): Split[E, Msg] {
  val app: List[E] = newList()
  val cmds: List[HostCommand] = newList()
  var d = dialog
  for e in effects {
    match p.uiEffect(e) {
      case None -> app.add(e)
      case Some(ue) -> match ue {
        case Navigate(url) -> cmds.add(NavigateTo(url = url))
        case Back -> cmds.add(GoBack)
        case Confirm(q, yes) -> {
          val onYes: Msg = yes
          val pd: PendingDialog[Msg] = PendingDialog(question = q, onYes = onYes)
          d = Some(value = pd)
        }
        case Notify(m, level) -> cmds.add(ShowToast(message = m, level = toastLevelName(level)))
      }
    }
  }
  return Split(appEffects = app, commands = cmds, dialog = d)
}

pub func rerender[M, Msg, E](
  p: in Program[M, Msg, E],
  s: in Session[M, Msg],
  model: in M,
  dialog: in Option[PendingDialog[Msg]],
  split: in Split[E, Msg],
  ivs: in List[InputVersion],
): Output[M, Msg, E] {
  val tree: View[SessionMsg[Msg]] = render(p, model, dialog)
  val current: View[SessionMsg[Msg]] = s.tree
  val patches: List[Patch] = diff(current, tree)
  val version = if patches.count > 0 then s.version + 1 else s.version
  val next: Session[M, Msg] = Session(
    model = model,
    tree = tree,
    version = version,
    dialog = dialog,
    inputVersions = liveInputVersions(tree, ivs)
  )
  return output(next, patches, split, false)
}

pub func output[M, Msg, E](
  s: in Session[M, Msg], patches: in List[Patch], split: in Split[E, Msg], dropped: in Bool
): Output[M, Msg, E] {
  val effects: List[E] = split.appEffects
  val commands: List[HostCommand] = split.commands
  val tree: View[SessionMsg[Msg]] = s.tree
  val echoes: List[ValueEcho] = echoesFor(tree, patches, s.inputVersions)
  return Output(
    session = s,
    patches = patches,
    echoes = echoes,
    effects = effects,
    commands = commands,
    dropped = dropped
  )
}

pub func unchanged[M, Msg, E](p: in Program[M, Msg, E], s: in Session[M, Msg], dropped: in Bool): Output[M, Msg, E] {
  val none: List[E] = newList()
  val noDialog: Option[PendingDialog[Msg]] = None
  val noPatches: List[Patch] = newList()
  val split: Split[E, Msg] = splitEffects(p, none, noDialog)
  return output(s, noPatches, split, dropped)
}

pub func withInputVersions[M, Msg](s: in Session[M, Msg], ivs: in List[InputVersion]): Session[M, Msg] {
  val model: M = s.model
  val tree: View[SessionMsg[Msg]] = s.tree
  val dialog: Option[PendingDialog[Msg]] = s.dialog
  return Session(model = model, tree = tree, version = s.version, dialog = dialog, inputVersions = ivs)
}

pub func render[M, Msg, E](
  p: in Program[M, Msg, E], model: in M, dialog: in Option[PendingDialog[Msg]]
): View[SessionMsg[Msg]] {
  val v: View[Msg] = p.view(model)
  val wrap: (Msg) -> SessionMsg[Msg] = { m -> App(msg = m) }
  val app: View[SessionMsg[Msg]] = mapView(v, wrap)
  val overlay: View[SessionMsg[Msg]] = match dialog {
    case Some(d) -> {
      val pd: PendingDialog[Msg] = d
      dialogView(pd)
    }
    case None -> Empty
  }
  val cs: List[View[SessionMsg[Msg]]] = newList()
  cs.add(app)
  cs.add(overlay)
  val ps: List[Prop] = newList()
  val hs: List[Handler[SessionMsg[Msg]]] = newList()
  return Element(kind = WidgetKind.Column, key = "", props = ps, handlers = hs, children = cs)
}

pub func dialogView[Msg](d: in PendingDialog[Msg]): View[SessionMsg[Msg]] {
  val buttons: List[View[SessionMsg[Msg]]] = newList()
  buttons.add(dialogButton("Cancel", "default", AnswerDialog(yes = false)))
  buttons.add(dialogButton("OK", "primary", AnswerDialog(yes = true)))
  val noProps: List[Prop] = newList()
  val noHs: List[Handler[SessionMsg[Msg]]] = newList()
  val actions: View[SessionMsg[Msg]] = Element(
    kind = WidgetKind.Row,
    key = "",
    props = noProps,
    handlers = noHs,
    children = buttons
  )
  val body: List[View[SessionMsg[Msg]]] = newList()
  body.add(Text(value = d.question))
  body.add(actions)
  val dps: List[Prop] = newList()
  dps.add(Prop(name = "modal", value = "true"))
  val dhs: List[Handler[SessionMsg[Msg]]] = newList()
  return Element(kind = WidgetKind.Dialog, key = "", props = dps, handlers = dhs, children = body)
}

pub func dialogButton[Msg](label: in String, variant: in String, msg: in SessionMsg[Msg]): View[SessionMsg[Msg]] {
  val ps: List[Prop] = newList()
  ps.add(Prop(name = "label", value = label))
  ps.add(Prop(name = "variant", value = variant))
  val hs: List[Handler[SessionMsg[Msg]]] = newList()
  hs.add(OnClick(msg = msg))
  val cs: List[View[SessionMsg[Msg]]] = newList()
  return Element(kind = WidgetKind.Button, key = "", props = ps, handlers = hs, children = cs)
}

/// The node an event path names in `tree`, if it still exists.  A key step
/// matches only when exactly one sibling carries that key.
pub func resolveRefs[Msg](tree: in View[Msg], path: in List[NodeRef]): Option[View[Msg]] {
  var node = tree
  for r in path {
    val cs = childrenOf(node)
    match r {
      case At(i) -> {
        if i < 0 or i >= cs.count {
          return None
        }
        node = cs[i]
      }
      case Keyed(k) -> {
        var found = -1
        var i = 0
        while i < cs.count {
          if keyOf(cs[i]) == k {
            if found >= 0 {
              return None
            }
            found = i
          }
          i = i + 1
        }
        if found < 0 {
          return None
        }
        node = cs[found]
      }
    }
  }
  return Some(value = node)
}

/// The event path of the node at child-index path `path` in `tree`: each
/// step is the node's key when it has one, its index otherwise (the form a
/// host sends).
pub func refsOf[Msg](tree: in View[Msg], path: in List[Int]): List[NodeRef] {
  val acc: List[NodeRef] = newList()
  var node = tree
  for i in path {
    val cs = childrenOf(node)
    if i < 0 or i >= cs.count {
      return acc
    }
    node = cs[i]
    val k = keyOf(node)
    if k.length > 0 {
      acc.add(Keyed(key = k))
    } else {
      acc.add(At(index = i))
    }
  }
  return acc
}

/// The handler for event `name` on the node `path` names, if any.
pub func handlerAt[Msg](tree: in View[Msg], path: in List[NodeRef], name: in String): Option[Handler[Msg]] {
  val target: View[Msg] = match resolveRefs(tree, path) { case Some(n) -> n; case None -> return None }
  return match target {
    case Element(_, _, _, handlers, _) -> {
      var found: Option[Handler[Msg]] = None
      for h in handlers {
        if eventName(h) == name {
          found = Some(value = h)
        }
      }
      found
    }
    case _ -> None
  }
}

/// `ivs` with the version for the input at `path` set to `version`.
pub func recordInputVersion(ivs: in List[InputVersion], path: in List[NodeRef], version: in Int): List[InputVersion] {
  val k = refsKey(path)
  val acc: List[InputVersion] = newList()
  for iv in ivs {
    if iv.key != k {
      acc.add(iv)
    }
  }
  acc.add(InputVersion(key = k, path = path, version = version))
  return acc
}

/// The entries of `ivs` whose input still exists in `tree`.
pub func liveInputVersions[Msg](tree: in View[Msg], ivs: in List[InputVersion]): List[InputVersion] {
  val acc: List[InputVersion] = newList()
  for iv in ivs {
    match resolveRefs(tree, iv.path) {
      case Some(_) -> acc.add(iv)
      case None -> ()
    }
  }
  return acc
}

/// The input versions to send with the `value` patches in `patches`, whose
/// paths are child-index paths into `tree` (the tree after the patches).
pub func echoesFor[Msg](tree: in View[Msg], patches: in List[Patch], ivs: in List[InputVersion]): List[ValueEcho] {
  val acc: List[ValueEcho] = newList()
  if ivs.count == 0 {
    return acc
  }
  for p in patches {
    match p {
      case SetProp(path, name, _) -> if name == "value" {
        val k = refsKey(refsOf(tree, path))
        for iv in ivs {
          if iv.key == k {
            acc.add(ValueEcho(pathKey = pathKey(path), version = iv.version))
          }
        }
      }
      case _ -> ()
    }
  }
  return acc
}
