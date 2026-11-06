//! access.l - Access.Platform: the native lyric-ui host's accessibility tree, published through AccessKit
//! (docs/67 G10, issue #8489).
//!
//! `attach` makes the platform adapter for a window: AT-SPI over D-Bus on Linux, NSAccessibility
//! on macOS (the window's content view is subclassed), UI Automation on Windows (the window is
//! subclassed, so `attach` must run before the window is first shown).  Each frame the host builds
//! the tree with `Ui.Native.Access.buildTree`, diffs it, and hands both to `publish`, which numbers
//! the nodes (`Access.Plan`) and sends AccessKit the nodes that changed.  An adapter is inactive
//! until an assistive technology connects; AccessKit then asks for the whole tree, which `publish`
//! keeps ready for it.  What the assistive technology asks for (focus, click, set value, scroll
//! into view) is queued, and `takeRequests` gives it to the host as `Ui.Native.Access` requests
//! with the host's own node ids, for `resolveRequest`.
//!
//! On Linux AccessKit calls back from its own thread, so the plan it reads and the request queue
//! sit in a protected type; every other call belongs to the window's thread.  Coordinates are the
//! host's logical pixels times `scale`, the window's pixel density.
@io
package Access.Platform

import Std.Core
import Std.Collections
import Std.Ffi as Ffi
import Window
import Ui.Native.Access.{AccessNode, AccessTree, AccessUpdate, AccessRequest, RequestKind, ReqFocus, ReqClick, ReqSetValue, ReqScrollIntoView, Role, RoleWindow, RoleGroup, RoleForm, RoleHeading, RoleParagraph, RoleLabel, RoleStatus, RoleAlert, RoleProgress, RoleButton, RoleLink, RoleTextInput, RolePasswordInput, RoleMultilineInput, RoleSpinButton, RoleCheckBox, RoleComboBox, RoleTable, RoleGrid, RoleRow, RoleCell, RoleColumnHeader, RoleDialog, Toggled, NotToggle, Unchecked, Checked, rootId}
import Access.Plan.{Numbering, Plan, PlannedNode, PlannedRun, newNumbering, numberOf, resolveNumber, planTree, planUpdate}
import Access.Kernel.Accesskit

// ─── Pointers as numbers ──────────────────────────────────────────────────────
@library("c")
@unsafe_ffi
extern func memcpyToLong(dst: NativePtr[Long], src: NativePtr[NativePtr[Byte]], n: Long): NativePtr[Byte] = "memcpy"

@library("c")
@unsafe_ffi
extern func memcpyToPtr(dst: NativePtr[NativePtr[Byte]], src: NativePtr[Long], n: Long): NativePtr[Byte] = "memcpy"

@library("c")
@unsafe_ffi
extern func memcpyLongAt(dst: NativePtr[Long], src: NativePtr[Byte], n: Long): NativePtr[Byte] = "memcpy"

@library("c")
@unsafe_ffi
extern func memcpyIntAt(dst: NativePtr[Int], src: NativePtr[Byte], n: Long): NativePtr[Byte] = "memcpy"

@unsafe_ffi
func ptrToLong(p: NativePtr[Byte]): Long {
  var src = p
  var dst: Long = 0
  val _ = memcpyToLong(nativeAddrOf(dst), nativeAddrOf(src), 8)
  dst
}

@unsafe_ffi
func longToPtr(v: Long): NativePtr[Byte] {
  var src = v
  var dst: NativePtr[Byte] = nativeNullPtr()
  val _ = memcpyToPtr(nativeAddrOf(dst), nativeAddrOf(src), 8)
  dst
}

@unsafe_ffi
func readLongAt(p: NativePtr[Byte], off: Long): Long {
  var v: Long = 0
  val _ = memcpyLongAt(nativeAddrOf(v), longToPtr(ptrToLong(p) + off), 8)
  v
}

@unsafe_ffi
func readIntAt(p: NativePtr[Byte], off: Long): Int {
  var v = 0
  val _ = memcpyIntAt(nativeAddrOf(v), longToPtr(ptrToLong(p) + off), 4)
  v
}

// ─── State shared with AccessKit's thread ─────────────────────────────────────
/// A request as AccessKit delivered it: the action code, the node's number and, for a set-value
/// request, the new text.
pub record PendingRequest {
  action: Int
  node: Long
  text: String
}

/// What AccessKit's callbacks read and write: the plan of the whole current tree (the answer when
/// an assistive technology connects) and the requests not yet taken.
pub protected type AccessShared {
  var whole: Option[Plan] = None
  var requests: List[PendingRequest] = newList()
  entry publish(p: in Plan) {
    whole = Some(value = p)
  }
  entry latest(): Option[Plan] {
    return whole
  }
  entry push(r: in PendingRequest) {
    requests.add(r)
  }
  entry take(): List[PendingRequest] {
    val taken = requests
    requests = newList()
    return taken
  }
}

/// A request for the host: the id of the node it names (as `Ui.Native.Access` gave it) and what
/// is asked.
pub record TargetedRequest {
  id: String
  request: AccessRequest
}

/// A window's adapter.  Use it from the window's thread only.
pub ref record Adapter {
  title: String
  scale: Float
  rootNum: Long
  shared: AccessShared
  numbering: Numbering
  /// The AccessKit adapter, by platform: 1 AT-SPI, 2 macOS, 3 Windows.
  platform: Int
  handle: Long
  keptActivation: Long
  keptAction: Long
  keptDeactivation: Long
  var last: Option[AccessTree]
}

// ─── Building AccessKit nodes ─────────────────────────────────────────────────
func roleCode(r: Role): Int {
  match r {
    case RoleWindow -> ACCESSKIT_ROLE_WINDOW
    case RoleGroup -> ACCESSKIT_ROLE_GROUP
    case RoleForm -> ACCESSKIT_ROLE_FORM
    case RoleHeading -> ACCESSKIT_ROLE_HEADING
    case RoleParagraph -> ACCESSKIT_ROLE_PARAGRAPH
    case RoleLabel -> ACCESSKIT_ROLE_LABEL
    case RoleStatus -> ACCESSKIT_ROLE_STATUS
    case RoleAlert -> ACCESSKIT_ROLE_ALERT
    case RoleProgress -> ACCESSKIT_ROLE_PROGRESS_INDICATOR
    case RoleButton -> ACCESSKIT_ROLE_BUTTON
    case RoleLink -> ACCESSKIT_ROLE_LINK
    case RoleTextInput -> ACCESSKIT_ROLE_TEXT_INPUT
    case RolePasswordInput -> ACCESSKIT_ROLE_PASSWORD_INPUT
    case RoleMultilineInput -> ACCESSKIT_ROLE_MULTILINE_TEXT_INPUT
    case RoleSpinButton -> ACCESSKIT_ROLE_SPIN_BUTTON
    case RoleCheckBox -> ACCESSKIT_ROLE_CHECK_BOX
    case RoleComboBox -> ACCESSKIT_ROLE_COMBO_BOX
    case RoleTable -> ACCESSKIT_ROLE_TABLE
    case RoleGrid -> ACCESSKIT_ROLE_GRID
    case RoleRow -> ACCESSKIT_ROLE_ROW
    case RoleCell -> ACCESSKIT_ROLE_CELL
    case RoleColumnHeader -> ACCESSKIT_ROLE_COLUMN_HEADER
    case RoleDialog -> ACCESSKIT_ROLE_DIALOG
  }
}

func actionCode(name: String): Option[Int] {
  if name == "focus" {
    Some(value = ACCESSKIT_ACTION_FOCUS)
  } else if name == "click" {
    Some(value = ACCESSKIT_ACTION_CLICK)
  } else if name == "setValue" {
    Some(value = ACCESSKIT_ACTION_SET_VALUE)
  } else {
    None
  }
}

/// The request an AccessKit action code stands for; `None` for actions the host does not offer.
pub func requestKindOf(action: in Int): Option[RequestKind] {
  if action == ACCESSKIT_ACTION_FOCUS {
    Some(value = ReqFocus)
  } else if action == ACCESSKIT_ACTION_CLICK {
    Some(value = ReqClick)
  } else if action == ACCESSKIT_ACTION_SET_VALUE {
    Some(value = ReqSetValue)
  } else if action == ACCESSKIT_ACTION_SCROLL_INTO_VIEW {
    Some(value = ReqScrollIntoView)
  } else {
    None
  }
}

@unsafe_ffi
func setLabel(node: NativePtr[Byte], s: String): Unit {
  if s.length > 0 {
    val c = Ffi.toCString(s)
    accesskit_node_set_label(node, c)
    Ffi.release(c)
  }
}

@unsafe_ffi
func setDescription(node: NativePtr[Byte], s: String): Unit {
  if s.length > 0 {
    val c = Ffi.toCString(s)
    accesskit_node_set_description(node, c)
    Ffi.release(c)
  }
}

@unsafe_ffi
func setValue(node: NativePtr[Byte], s: String): Unit {
  val c = Ffi.toCString(s)
  accesskit_node_set_value(node, c)
  Ffi.release(c)
}

func rectOf(x: Float, y: Float, w: Float, h: Float, scale: Float): accesskit_rect {
  val s = scale.toDouble()
  accesskit_rect(x0 = x.toDouble() * s, y0 = y.toDouble() * s, x1 = (x + w).toDouble() * s, y1 = (y + h).toDouble() * s)
}

@unsafe_ffi
func runNode(r: PlannedRun, n: AccessNode, scale: Float): NativePtr[Byte] {
  val node = accesskit_node_new(ACCESSKIT_ROLE_TEXT_RUN.toByte())
  setValue(node, r.text)
  val count = r.lengths.count
  if count > 0 {
    val buf = Ffi.allocate(count.toLong())
    var i = 0
    while i < count {
      nativeStoreByte(buf, i.toLong(), r.lengths[i].toByte())
      i = i + 1
    }
    accesskit_node_set_character_lengths(node, count.toLong(), buf)
    Ffi.release(buf)
  }
  accesskit_node_set_bounds(node, rectOf(n.x, n.y, n.w, n.h, scale))
  node
}

@unsafe_ffi
func cNode(p: PlannedNode, scale: Float, isRoot: Bool): NativePtr[Byte] {
  val n = p.node
  val node = accesskit_node_new(roleCode(n.role).toByte())
  // AccessKit reads a label's text from its value, and every other node's name from its label.
  val isLabel = match n.role { case RoleLabel -> true; case _ -> false }
  if isLabel {
    setValue(node, n.name)
  } else {
    setLabel(node, n.name)
    if n.value.length > 0 or p.runs.count > 0 {
      setValue(node, n.value)
    }
  }
  setDescription(node, n.description)
  if n.level > 0 {
    accesskit_node_set_level(node, n.level.toLong())
  }
  match n.toggled {
    case NotToggle -> ()
    case Unchecked -> accesskit_node_set_toggled(node, ACCESSKIT_TOGGLED_FALSE.toByte())
    case Checked -> accesskit_node_set_toggled(node, ACCESSKIT_TOGGLED_TRUE.toByte())
  }
  match n.expanded {
    case Some(open) -> accesskit_node_set_expanded(node, if open { 1u8 } else { 0u8 })
    case None -> ()
  }
  if n.live == "polite" {
    accesskit_node_set_live(node, ACCESSKIT_LIVE_POLITE.toByte())
  } else if n.live == "assertive" {
    accesskit_node_set_live(node, ACCESSKIT_LIVE_ASSERTIVE.toByte())
  }
  if n.modal {
    accesskit_node_set_modal(node)
  }
  if n.disabled {
    accesskit_node_set_disabled(node)
  }
  if n.required {
    accesskit_node_set_required(node)
  }
  if n.readOnly {
    accesskit_node_set_read_only(node)
  }
  if n.invalid {
    accesskit_node_set_invalid(node, ACCESSKIT_INVALID_TRUE.toByte())
  }
  if n.sort == "ascending" {
    accesskit_node_set_sort_direction(node, ACCESSKIT_SORT_DIRECTION_ASCENDING.toByte())
  } else if n.sort == "descending" {
    accesskit_node_set_sort_direction(node, ACCESSKIT_SORT_DIRECTION_DESCENDING.toByte())
  } else if n.sort == "none" {
    accesskit_node_set_sort_direction(node, ACCESSKIT_SORT_DIRECTION_OTHER.toByte())
  }
  // AccessKit counts rows and columns from 0; `Ui.Native.Access` from 1, as ARIA does.
  if n.rowCount > 0 {
    accesskit_node_set_row_count(node, n.rowCount.toLong())
  }
  if n.colCount > 0 {
    accesskit_node_set_column_count(node, n.colCount.toLong())
  }
  if n.rowIndex > 0 {
    accesskit_node_set_row_index(node, (n.rowIndex - 1).toLong())
  }
  if n.colIndex > 0 {
    accesskit_node_set_column_index(node, (n.colIndex - 1).toLong())
  }
  accesskit_node_set_bounds(node, rectOf(n.x, n.y, n.w, n.h, scale))
  for a in n.actions {
    match actionCode(a) {
      case Some(code) -> accesskit_node_add_action(node, code.toByte())
      case None -> ()
    }
  }
  if not isRoot {
    accesskit_node_add_action(node, ACCESSKIT_ACTION_SCROLL_INTO_VIEW.toByte())
  }
  for c in p.childNums {
    accesskit_node_push_child(node, c)
  }
  match p.selection {
    case Some(s) -> accesskit_node_set_text_selection(
      node,
      accesskit_text_selection(
        anchor = accesskit_text_position(node = s.anchorRun, character_index = s.anchorIndex.toLong()),
        focus = accesskit_text_position(node = s.focusRun, character_index = s.focusIndex.toLong())
      )
    )
    case None -> ()
  }
  node
}

@unsafe_ffi
func treeInfo(rootNum: Long): NativePtr[Byte] {
  val info = accesskit_tree_info_new(rootNum)
  val name = Ffi.toCString("lyric-ui")
  accesskit_tree_info_set_toolkit_name(info, name)
  Ffi.release(name)
  val version = Ffi.toCString("0.1.0")
  accesskit_tree_info_set_toolkit_version(info, version)
  Ffi.release(version)
  info
}

/// An AccessKit tree update for `p`; ownership passes to whoever AccessKit hands it to.
@unsafe_ffi
func cUpdate(p: Plan, scale: Float): NativePtr[Byte] {
  var count = p.nodes.count
  for n in p.nodes {
    count = count + n.runs.count
  }
  val update = accesskit_tree_update_with_capacity_and_focus(count.toLong(), p.focusNum)
  if p.full {
    accesskit_tree_update_set_tree_info(update, treeInfo(p.rootNum))
  }
  for n in p.nodes {
    accesskit_tree_update_push_node(update, n.num, cNode(n, scale, n.num == p.rootNum))
    for r in n.runs {
      accesskit_tree_update_push_node(update, r.num, runNode(r, n.node, scale))
    }
  }
  update
}

// What AccessKit is given when an assistive technology connects before the first frame: the
// window alone.
@unsafe_ffi
func placeholderUpdate(rootNum: Long, title: String): NativePtr[Byte] {
  val update = accesskit_tree_update_with_capacity_and_focus(1, rootNum)
  accesskit_tree_update_set_tree_info(update, treeInfo(rootNum))
  val root = accesskit_node_new(ACCESSKIT_ROLE_WINDOW.toByte())
  setLabel(root, title)
  accesskit_tree_update_push_node(update, rootNum, root)
  update
}

@unsafe_ffi
func activationUpdate(shared: AccessShared, rootNum: Long, title: String, scale: Float): NativePtr[Byte] {
  match shared.latest() {
    case Some(p) -> cUpdate(p, scale)
    case None -> placeholderUpdate(rootNum, title)
  }
}

// Offsets in `accesskit_action_request`, checked against <accesskit.h> by
// platform/native/accesskit_layout_check.c.
val offAction: Long = 0

val offTargetNode: Long = 24

val offDataHasValue: Long = 32

val offDataTag: Long = 40

val offDataValue: Long = 48

/// Queues the request AccessKit hands over and frees it.  Runs on whichever thread AccessKit calls
/// from.
@unsafe_ffi
func receive(shared: AccessShared, request: NativePtr[Byte]): Unit {
  val action = nativeLoadByte(request, offAction).toInt()
  val node = readLongAt(request, offTargetNode)
  var text = ""
  if nativeLoadByte(request, offDataHasValue) != 0u8 and readIntAt(request, offDataTag) == ACCESSKIT_ACTION_DATA_VALUE {
    match Ffi.tryFromCString(longToPtr(readLongAt(request, offDataValue))) {
      case Some(t) -> {
        text = t
      }
      case None -> ()
    }
  }
  accesskit_action_request_free(request)
  shared.push(PendingRequest(action = action, node = node, text = text))
}

// ─── Platform adapters ────────────────────────────────────────────────────────
val platformAtspi: Int = 1

val platformMacos: Int = 2

val platformWindows: Int = 3

func newAdapter(title: String, scale: Float, shared: AccessShared, numbering: Numbering, rootNum: Long): Adapter {
  Adapter(
    title = title,
    scale = scale,
    rootNum = rootNum,
    shared = shared,
    numbering = numbering,
    platform = 0,
    handle = 0,
    keptActivation = 0,
    keptAction = 0,
    keptDeactivation = 0,
    last = None
  )
}

@cfg(target_os = "linux")
@unsafe_ffi
func attachPlatform(win: Window.Window, base: Adapter): Result[Adapter, String] {
  val shared = base.shared
  val rootNum = base.rootNum
  val title = base.title
  val scale = base.scale
  val onActivate: () -> NativePtr[Byte] = { -> activationUpdate(shared, rootNum, title, scale) }
  val onAction: (NativePtr[Byte]) -> Unit = { request: NativePtr[Byte] -> receive(shared, request) }
  val onDeactivate: () -> Unit = { -> () }
  val ka = nativeKeepCallback(onActivate)
  val kb = nativeKeepCallback(onAction)
  val kc = nativeKeepCallback(onDeactivate)
  val handle = accesskit_unix_adapter_new(onActivate, ka, onAction, kb, onDeactivate, kc)
  if handle == nativeNullPtr() {
    nativeReleaseCallback(ka)
    nativeReleaseCallback(kb)
    nativeReleaseCallback(kc)
    return Err(error = "AccessKit could not create the AT-SPI adapter")
  }
  Ok(
    value = base.copy(
      platform = platformAtspi,
      handle = ptrToLong(handle),
      keptActivation = ptrToLong(ka),
      keptAction = ptrToLong(kb),
      keptDeactivation = ptrToLong(kc)
    )
  )
}

@cfg(target_os = "macos")
@unsafe_ffi
func attachPlatform(win: Window.Window, base: Adapter): Result[Adapter, String] {
  val nsWindow = match Window.nativeWindow(win) {
    case Cocoa(w) -> w
    case _ -> return Err(error = "the window has no NSWindow")
  }
  val shared = base.shared
  val rootNum = base.rootNum
  val title = base.title
  val scale = base.scale
  val onActivate: () -> NativePtr[Byte] = { -> activationUpdate(shared, rootNum, title, scale) }
  val onAction: (NativePtr[Byte]) -> Unit = { request: NativePtr[Byte] -> receive(shared, request) }
  val ka = nativeKeepCallback(onActivate)
  val kb = nativeKeepCallback(onAction)
  val handle = accesskit_macos_subclassing_adapter_for_window(longToPtr(nsWindow), onActivate, ka, onAction, kb)
  if handle == nativeNullPtr() {
    nativeReleaseCallback(ka)
    nativeReleaseCallback(kb)
    return Err(error = "AccessKit could not create the NSAccessibility adapter")
  }
  Ok(
    value = base.copy(
      platform = platformMacos,
      handle = ptrToLong(handle),
      keptActivation = ptrToLong(ka),
      keptAction = ptrToLong(kb)
    )
  )
}

// windows.h declares HWND as a pointer to a complete struct, so the binding takes NativePtr[HWND__].
@cfg(target_os = "windows")
@library("c")
@unsafe_ffi
extern func memcpyToHwnd(dst: NativePtr[NativePtr[HWND__]], src: NativePtr[Long], n: Long): NativePtr[Byte] = "memcpy"

@cfg(target_os = "windows")
@unsafe_ffi
func hwndOf(v: Long): NativePtr[HWND__] {
  var src = v
  var dst: NativePtr[HWND__] = nativeNullPtr()
  val _ = memcpyToHwnd(nativeAddrOf(dst), nativeAddrOf(src), 8)
  dst
}

@cfg(target_os = "windows")
@unsafe_ffi
func attachPlatform(win: Window.Window, base: Adapter): Result[Adapter, String] {
  val hwnd = match Window.nativeWindow(win) {
    case Win32(h, _) -> h
    case _ -> return Err(error = "the window has no HWND")
  }
  val shared = base.shared
  val rootNum = base.rootNum
  val title = base.title
  val scale = base.scale
  val onActivate: () -> NativePtr[Byte] = { -> activationUpdate(shared, rootNum, title, scale) }
  val onAction: (NativePtr[Byte]) -> Unit = { request: NativePtr[Byte] -> receive(shared, request) }
  val ka = nativeKeepCallback(onActivate)
  val kb = nativeKeepCallback(onAction)
  val handle = accesskit_windows_subclassing_adapter_new(hwndOf(hwnd), onActivate, ka, onAction, kb)
  if handle == nativeNullPtr() {
    nativeReleaseCallback(ka)
    nativeReleaseCallback(kb)
    return Err(error = "AccessKit could not create the UI Automation adapter")
  }
  Ok(
    value = base.copy(
      platform = platformWindows,
      handle = ptrToLong(handle),
      keptActivation = ptrToLong(ka),
      keptAction = ptrToLong(kb)
    )
  )
}

/// The adapter for `win`, whose title names the root node and whose pixel density is `scale`.
/// On Windows, call it before the window is first shown.
@unsafe_ffi
pub func attach(win: in Window.Window, title: in String, scale: in Float): Result[Adapter, String] {
  val numbering = newNumbering()
  val rootNum = numberOf(numbering, rootId())
  attachPlatform(win, newAdapter(title, scale, AccessShared(), numbering, rootNum))
}

@cfg(target_os = "linux")
@unsafe_ffi
func sendUpdate(a: Adapter, p: Plan): Unit {
  val scale = a.scale
  val factory: () -> NativePtr[Byte] = { -> cUpdate(p, scale) }
  accesskit_unix_adapter_update_if_active(longToPtr(a.handle), factory, factory)
}

@cfg(target_os = "macos")
@unsafe_ffi
func sendUpdate(a: Adapter, p: Plan): Unit {
  val scale = a.scale
  val factory: () -> NativePtr[Byte] = { -> cUpdate(p, scale) }
  val events = accesskit_macos_subclassing_adapter_update_if_active(longToPtr(a.handle), factory, factory)
  if events != nativeNullPtr() {
    accesskit_macos_queued_events_raise(events)
  }
}

@cfg(target_os = "windows")
@unsafe_ffi
func sendUpdate(a: Adapter, p: Plan): Unit {
  val scale = a.scale
  val factory: () -> NativePtr[Byte] = { -> cUpdate(p, scale) }
  val events = accesskit_windows_subclassing_adapter_update_if_active(longToPtr(a.handle), factory, factory)
  if events != nativeNullPtr() {
    accesskit_windows_queued_events_raise(events)
  }
}

/// Publishes `tree`, the accessibility tree of the frame just laid out: AccessKit gets the nodes
/// that changed since the last call, and keeps the whole tree for an assistive technology that
/// connects later.  Does nothing when the tree is unchanged.
@unsafe_ffi
pub func publish(a: in Adapter, tree: in AccessTree): Unit {
  val update = Ui.Native.Access.diffTrees(a.last, tree)
  if not update.full and update.changed.count == 0 and not update.focusChanged {
    return
  }
  val whole = planTree(a.numbering, tree)
  a.shared.publish(whole)
  a.last = Some(value = tree)
  match planUpdate(whole, update) {
    case Some(p) -> sendUpdate(a, p)
    case None -> ()
  }
}

/// The requests assistive technologies made since the last call, oldest first, for nodes that are
/// still in the tree and actions the host offers.
pub func takeRequests(a: in Adapter): List[TargetedRequest] {
  val found: List[TargetedRequest] = newList()
  for r in a.shared.take() {
    match requestKindOf(r.action) {
      case Some(kind) -> match resolveNumber(a.numbering, r.node) {
        case Some(id) -> found.add(
          TargetedRequest(
            id = id,
            request = AccessRequest(kind = kind, text = r.text)
          )
        )
        case None -> ()
      }
      case None -> ()
    }
  }
  found
}

@cfg(target_os = "linux")
@unsafe_ffi
func focusPlatform(a: Adapter, focused: Bool): Unit {
  accesskit_unix_adapter_update_window_focus_state(longToPtr(a.handle), if focused { 1u8 } else { 0u8 })
}

@cfg(target_os = "macos")
@unsafe_ffi
func focusPlatform(a: Adapter, focused: Bool): Unit {
  val events = accesskit_macos_subclassing_adapter_update_view_focus_state(
    longToPtr(a.handle),
    if focused { 1u8 } else { 0u8 }
  )
  if events != nativeNullPtr() {
    accesskit_macos_queued_events_raise(events)
  }
}

// UI Automation follows the window's focus itself: the subclassed window sees WM_SETFOCUS and
// WM_KILLFOCUS.
@cfg(target_os = "windows")
@unsafe_ffi
func focusPlatform(a: Adapter, focused: Bool): Unit {
  ()
}

/// Tells the adapter whether the window has keyboard focus.
@unsafe_ffi
pub func setWindowFocused(a: in Adapter, focused: in Bool): Unit {
  focusPlatform(a, focused)
}

@cfg(target_os = "linux")
@unsafe_ffi
func boundsPlatform(a: Adapter, x: Int, y: Int, w: Int, h: Int, top: Int, left: Int, bottom: Int, right: Int): Unit {
  val inner = accesskit_rect(x0 = x.toDouble(), y0 = y.toDouble(), x1 = (x + w).toDouble(), y1 = (y + h).toDouble())
  val outer = accesskit_rect(
    x0 = (x - left).toDouble(),
    y0 = (y - top).toDouble(),
    x1 = (x + w + right).toDouble(),
    y1 = (y + h + bottom).toDouble()
  )
  accesskit_unix_adapter_set_root_window_bounds(longToPtr(a.handle), outer, inner)
}

// NSAccessibility and UI Automation place the tree through the window themselves.
@cfg(target_os = "macos")
@unsafe_ffi
func boundsPlatform(a: Adapter, x: Int, y: Int, w: Int, h: Int, top: Int, left: Int, bottom: Int, right: Int): Unit {
  ()
}

@cfg(target_os = "windows")
@unsafe_ffi
func boundsPlatform(a: Adapter, x: Int, y: Int, w: Int, h: Int, top: Int, left: Int, bottom: Int, right: Int): Unit {
  ()
}

/// Tells the adapter where the window is on the screen, in pixels: its client area and the
/// thickness of its decorations.  AT-SPI needs this to give screen coordinates (only an X11 window
/// knows its position); the other platforms find it themselves.
@unsafe_ffi
pub func setWindowBounds(a: in Adapter, b: in Window.Bounds): Unit {
  boundsPlatform(a, b.x, b.y, b.width, b.height, b.top, b.left, b.bottom, b.right)
}

@cfg(target_os = "linux")
@unsafe_ffi
func freePlatform(a: Adapter): Unit {
  accesskit_unix_adapter_free(longToPtr(a.handle))
}

@cfg(target_os = "macos")
@unsafe_ffi
func freePlatform(a: Adapter): Unit {
  accesskit_macos_subclassing_adapter_free(longToPtr(a.handle))
}

@cfg(target_os = "windows")
@unsafe_ffi
func freePlatform(a: Adapter): Unit {
  accesskit_windows_subclassing_adapter_free(longToPtr(a.handle))
}

/// Removes the adapter; the window's tree disappears from assistive technologies.  Call it before
/// the window is destroyed.
@unsafe_ffi
pub func detach(a: in Adapter): Unit {
  freePlatform(a)
  if a.keptActivation != 0 {
    nativeReleaseCallback(longToPtr(a.keptActivation))
  }
  if a.keptAction != 0 {
    nativeReleaseCallback(longToPtr(a.keptAction))
  }
  if a.keptDeactivation != 0 {
    nativeReleaseCallback(longToPtr(a.keptDeactivation))
  }
}
