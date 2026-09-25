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
@runtime_checked
package Ui.Session

import Std.Core
import Ui.Core.{View, Element, Text, Empty, Handler, OnClick, Prop, WidgetKind, Step, UiEffect, Navigate, Back, Confirm, Notify, toastLevelName, eventName, fire, mapView, childrenOf}
import Ui.Diff.{Patch, diff, replaceAll}
import Ui.Protocol.{Event, InputVersion, pathKey}

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

/// The state of one session.
pub record Session[M, Msg] {
  model: M
  tree: View[SessionMsg[Msg]]
  version: Int
  dialog: Option[PendingDialog[Msg]]
  inputVersions: List[InputVersion]
}

/// The result of one step.  `dropped` is true when a host event did not
/// resolve to a handler (stale path or unknown event); nothing else changes
/// in that case and the driver logs it.
pub record Output[M, Msg, E] {
  session: Session[M, Msg]
  patches: List[Patch]
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

/// The patches that bring a (re)connected host up to date: a replacement of
/// the whole tree.
pub func resync[M, Msg](s: in Session[M, Msg]): List[Patch] {
  return replaceAll(s.tree)
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
    inputVersions = ivs
  )
  return output(next, patches, split, false)
}

pub func output[M, Msg, E](
  s: in Session[M, Msg], patches: in List[Patch], split: in Split[E, Msg], dropped: in Bool
): Output[M, Msg, E] {
  val effects: List[E] = split.appEffects
  val commands: List[HostCommand] = split.commands
  return Output(session = s, patches = patches, effects = effects, commands = commands, dropped = dropped)
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

/// The handler for event `name` on the node at `path`, if any.
pub func handlerAt[Msg](tree: in View[Msg], path: in List[Int], name: in String): Option[Handler[Msg]] {
  var node = tree
  for i in path {
    val cs = childrenOf(node)
    if i < 0 or i >= cs.count {
      return None
    }
    node = cs[i]
  }
  return match node {
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

pub func recordInputVersion(ivs: in List[InputVersion], path: in List[Int], version: in Int): List[InputVersion] {
  val k = pathKey(path)
  val acc: List[InputVersion] = newList()
  for iv in ivs {
    if iv.pathKey != k {
      acc.add(iv)
    }
  }
  acc.add(InputVersion(pathKey = k, version = version))
  return acc
}
