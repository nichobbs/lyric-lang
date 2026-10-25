//! Example.UiWidgets — a widget plugin for lyric-ui (docs/65 §6.5,
//! docs/69 §16 P6).  It provides two widgets:
//!
//!   - `rating`: a row of stars.  Configuration `{"max": 1-10, "label": text}`;
//!     clicking a star rates, and the widget tells its screen with the
//!     outcome `rated` (payload: the rating).
//!   - `tags`: a list of tags with an input to add one and a button to remove
//!     each.  Configuration `{"maxTags": 1-50, "placeholder": text}`; every
//!     change is the outcome `tagsChanged` (payload: the tags).
//!
//! The plugin keeps nothing between calls: each answer is computed from the
//! configuration, the state and the message the host passes in, and the
//! state it returns is JSON the host stores for it.  `Lyric.PluginExpand`
//! generates its `main`, its manifest and the codecs.
//!
//!   lyric plugin pack --manifest examples/plugins/ui-widgets/widgets/lyric.toml --targets dotnet,jvm \
//!     --sign-key examples/plugins/keys/example-publisher.key -o <dir>
package Example.UiWidgets

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Parse.{parseOptInt}
import Std.JsonValue
import Ui.Plugins
import Ui.Plugins.Build as B

@plugin(id = "example.ui-widgets", version = "1.0.0", publisher = "lyric-examples", implements(WidgetPlugin))
pub record ExampleWidgets {
}

// ─── JSON helpers ─────────────────────────────────────────────────────────────
func jsonObject(fields: in List[JsonField]): JsonValue {
  JObject(fields = fields)
}

func intField(v: in JsonValue, name: in String, fallback: in Int): Int {
  match getInt(v, name) {
    case Some(n) -> n.toInt()
    case None -> fallback
  }
}

func stringField(v: in JsonValue, name: in String, fallback: in String): String {
  match getString(v, name) {
    case Some(s) -> s
    case None -> fallback
  }
}

func schema(text: in String): JsonValue {
  match parseValue(text) {
    case Ok(v) -> v
    case Err(_) -> JNull
  }
}

func outcome(name: in String, payload: in JsonValue): List[WidgetOutcome] {
  val os: List[WidgetOutcome] = newList()
  os.add(WidgetOutcome(name = name, payload = payload))
  os
}

func noOutcomes(): List[WidgetOutcome] {
  newList()
}

// ─── rating ───────────────────────────────────────────────────────────────────
record RatingConfig {
  max: Int
  label: String
}

func ratingConfig(v: in JsonValue): Result[RatingConfig, WidgetError] {
  val max = intField(v, "max", 5)
  if max < 1 or max > 10 {
    return Err(error = InvalidConfig(detail = "max must be between 1 and 10, not " + max.toString()))
  }
  Ok(value = RatingConfig(max = max, label = stringField(v, "label", "Rating")))
}

func ratingState(value: in Int): JsonValue {
  val fs: List[JsonField] = newList()
  fs.add(JsonField(name = "value", value = JInt(value = value.toLong())))
  jsonObject(fs)
}

func ratingValue(state: in JsonValue, cfg: in RatingConfig): Int {
  val v = intField(state, "value", 0)
  if v < 0 {
    0
  } else if v > cfg.max {
    cfg.max
  } else {
    v
  }
}

func ratingView(cfg: in RatingConfig, value: in Int): WidgetTree {
  val stars: List[WidgetTree] = newList()
  var i = 1
  while i <= cfg.max {
    val glyph = if i <= value then "★" else "☆"
    val variant = if i <= value then "primary" else "default"
    stars.add(B.keyed("star-" + i.toString(), B.buttonWith(glyph, "set:" + i.toString(), variant, false)))
    i = i + 1
  }
  val kids: List[WidgetTree] = newList()
  kids.add(B.row(stars))
  val summary = if value == 0 then "Not rated" else value.toString() + " of " + cfg.max.toString()
  kids.add(B.keyed("summary", B.paragraph(summary)))
  kids.add(B.keyed("clear", B.buttonWith("Clear", "clear", "default", value == 0)))
  B.card(cfg.label, kids)
}

func ratingStep(cfg: in RatingConfig, value: in Int, outcomes: in List[WidgetOutcome]): WidgetStep {
  WidgetStep(state = ratingState(value), view = ratingView(cfg, value), outcomes = outcomes)
}

func ratingUpdate(cfg: in RatingConfig, state: in JsonValue, m: in WidgetMessage): Result[WidgetStep, WidgetError] {
  if m.message == "clear" {
    return Ok(value = ratingStep(cfg, 0, outcome("rated", JInt(value = 0i64))))
  }
  if Str.startsWith(m.message, "set:") {
    match parseOptInt(Str.substring(m.message, 4)) {
      case Some(n) -> if n >= 1 and n <= cfg.max {
        return Ok(value = ratingStep(cfg, n, outcome("rated", JInt(value = n.toLong()))))
      }
      case None -> ()
    }
  }
  Err(error = WidgetFailed(detail = "rating does not understand '" + m.message + "'"))
}

// ─── tags ─────────────────────────────────────────────────────────────────────
record TagsConfig {
  maxTags: Int
  placeholder: String
}

record TagsState {
  draft: String
  tags: List[String]
}

func tagsConfig(v: in JsonValue): Result[TagsConfig, WidgetError] {
  val max = intField(v, "maxTags", 10)
  if max < 1 or max > 50 {
    return Err(error = InvalidConfig(detail = "maxTags must be between 1 and 50, not " + max.toString()))
  }
  Ok(value = TagsConfig(maxTags = max, placeholder = stringField(v, "placeholder", "New tag")))
}

func tagsState(v: in JsonValue): TagsState {
  val tags: List[String] = newList()
  match getArray(v, "tags") {
    case Some(items) -> {
      for it in items {
        match asString(it) {
          case Some(s) -> tags.add(s)
          case None -> ()
        }
      }
    }
    case None -> ()
  }
  TagsState(draft = stringField(v, "draft", ""), tags = tags)
}

func tagsJson(tags: in List[String]): JsonValue {
  val items: List[JsonValue] = newList()
  for t in tags {
    items.add(JString(value = t))
  }
  JArray(items = items)
}

func tagsStateJson(s: in TagsState): JsonValue {
  val fs: List[JsonField] = newList()
  fs.add(JsonField(name = "draft", value = JString(value = s.draft)))
  fs.add(JsonField(name = "tags", value = tagsJson(s.tags)))
  jsonObject(fs)
}

func tagsView(cfg: in TagsConfig, s: in TagsState): WidgetTree {
  val chips: List[WidgetTree] = newList()
  for t in s.tags {
    val chip: List[WidgetTree] = newList()
    chip.add(B.badge(t, "info"))
    chip.add(B.button("Remove " + t, "remove:" + t))
    chips.add(B.keyed("tag-" + t, B.row(chip)))
  }
  if s.tags.count == 0 {
    chips.add(B.keyed("empty", B.paragraph("No tags yet")))
  }
  val entry: List[WidgetTree] = newList()
  entry.add(B.keyed("draft", B.textInput("text", s.draft, "draft", cfg.placeholder)))
  entry.add(B.keyed("add", B.buttonWith("Add", "add", "primary", s.tags.count >= cfg.maxTags)))
  val kids: List[WidgetTree] = newList()
  kids.add(B.keyed("tags", B.column(chips)))
  kids.add(B.keyed("entry", B.form("add", entry)))
  B.column(kids)
}

func tagsStep(cfg: in TagsConfig, s: in TagsState, outcomes: in List[WidgetOutcome]): WidgetStep {
  WidgetStep(state = tagsStateJson(s), view = tagsView(cfg, s), outcomes = outcomes)
}

func tagsUpdate(cfg: in TagsConfig, state: in JsonValue, m: in WidgetMessage): Result[WidgetStep, WidgetError] {
  val s = tagsState(state)
  if m.message == "draft" {
    return Ok(value = tagsStep(cfg, TagsState(draft = m.data, tags = s.tags), noOutcomes()))
  }
  if m.message == "add" {
    val t = Str.trim(s.draft)
    if t.length == 0 or s.tags.contains(t) or s.tags.count >= cfg.maxTags {
      return Ok(value = tagsStep(cfg, s, noOutcomes()))
    }
    val tags: List[String] = newList()
    for x in s.tags {
      tags.add(x)
    }
    tags.add(t)
    return Ok(value = tagsStep(cfg, TagsState(draft = "", tags = tags), outcome("tagsChanged", tagsJson(tags))))
  }
  if Str.startsWith(m.message, "remove:") {
    val gone = Str.substring(m.message, 7)
    val tags: List[String] = newList()
    for x in s.tags {
      if x != gone {
        tags.add(x)
      }
    }
    return Ok(value = tagsStep(cfg, TagsState(draft = s.draft, tags = tags), outcome("tagsChanged", tagsJson(tags))))
  }
  Err(error = WidgetFailed(detail = "tags does not understand '" + m.message + "'"))
}

// ─── The point ────────────────────────────────────────────────────────────────
impl WidgetPlugin for ExampleWidgets {
  func init(req: in WidgetInit): Result[WidgetStep, WidgetError] {
    if req.widget == "rating" {
      return match ratingConfig(req.config) {
        case Ok(cfg) -> Ok(value = ratingStep(cfg, 0, noOutcomes()))
        case Err(e) -> Err(error = e)
      }
    }
    if req.widget == "tags" {
      return match tagsConfig(req.config) {
        case Ok(cfg) -> Ok(value = tagsStep(cfg, TagsState(draft = "", tags = newList()), noOutcomes()))
        case Err(e) -> Err(error = e)
      }
    }
    Err(error = UnknownWidget(widget = req.widget))
  }

  func update(req: in WidgetUpdate): Result[WidgetStep, WidgetError] {
    if req.widget == "rating" {
      return match ratingConfig(req.config) {
        case Ok(cfg) -> ratingUpdate(cfg, req.state, req.message)
        case Err(e) -> Err(error = e)
      }
    }
    if req.widget == "tags" {
      return match tagsConfig(req.config) {
        case Ok(cfg) -> tagsUpdate(cfg, req.state, req.message)
        case Err(e) -> Err(error = e)
      }
    }
    Err(error = UnknownWidget(widget = req.widget))
  }

  func configure(req: in WidgetConfigure): Result[WidgetStep, WidgetError] {
    if req.widget == "rating" {
      return match ratingConfig(req.config) {
        case Ok(cfg) -> Ok(value = ratingStep(cfg, ratingValue(req.state, cfg), noOutcomes()))
        case Err(e) -> Err(error = e)
      }
    }
    if req.widget == "tags" {
      return match tagsConfig(req.config) {
        case Ok(cfg) -> Ok(value = tagsStep(cfg, tagsState(req.state), noOutcomes()))
        case Err(e) -> Err(error = e)
      }
    }
    Err(error = UnknownWidget(widget = req.widget))
  }
}

@plugin_contributions(WidgetPlugin)
func contributions(): WidgetContributions {
  val ws: List[WidgetDecl] = newList()
  ws.add(
    WidgetDecl(
      name = "rating",
      title = "Rating",
      description = "A row of stars to rate something from 1 to max.",
      configSchema = schema(
        "{\"type\":\"object\",\"properties\":{\"max\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":10}," +
          "\"label\":{\"type\":\"string\"}},\"additionalProperties\":false}"
      ),
      defaultConfig = schema("{\"max\":5,\"label\":\"Rating\"}")
    )
  )
  ws.add(
    WidgetDecl(
      name = "tags",
      title = "Tags",
      description = "A list of tags to add to and remove from.",
      configSchema = schema(
        "{\"type\":\"object\",\"properties\":{\"maxTags\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":50}," +
          "\"placeholder\":{\"type\":\"string\"}},\"additionalProperties\":false}"
      ),
      defaultConfig = schema("{\"maxTags\":10,\"placeholder\":\"New tag\"}")
    )
  )
  WidgetContributions(widgets = ws)
}
