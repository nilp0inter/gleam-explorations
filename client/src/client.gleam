import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre
import lustre/attribute
import lustre/effect
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event
import lustre_websocket as ws
import shared/messages.{type TestRun}

// === FFI ===

@external(javascript, "./client_ffi.mjs", "updateChart")
fn do_update_chart(json_string: String) -> Nil

@external(javascript, "./client_ffi.mjs", "highlightNodes")
fn do_highlight_nodes(json_array: String) -> Nil

@external(javascript, "./client_ffi.mjs", "clearHighlight")
fn do_clear_highlight() -> Nil

// === Model ===

pub type Model {
  Model(
    runs: List(TestRun),
    run_count: Int,
    socket: Option(ws.WebSocket),
    expanded_steps: List(Int),
    selected_nodes: List(String),
  )
}

// === Messages ===

pub type Msg {
  WsEvent(ws.WebSocketEvent)
  ToggleStep(Int)
  ToggleNode(String, Int)
  ClearSelection
}

// === Init ===

fn init(_flags) -> #(Model, effect.Effect(Msg)) {
  let model =
    Model(
      runs: [],
      run_count: 0,
      socket: None,
      expanded_steps: [],
      selected_nodes: [],
    )
  #(model, ws.init("/ws", WsEvent))
}

// === Bucket classification ===

fn classify_force(force: Float) -> String {
  case force <. 3.0 {
    True -> "Low Force"
    False ->
      case force <=. 7.0 {
        True -> "Medium Force"
        False -> "High Force"
      }
  }
}

fn classify_duration(duration: Float) -> String {
  case duration <. 3.0 {
    True -> "Short Duration"
    False ->
      case duration <=. 7.0 {
        True -> "Medium Duration"
        False -> "Long Duration"
      }
  }
}

fn classify_number(n: Int) -> String {
  int.to_string(n)
}

fn classify_color(color: String) -> String {
  case color {
    "red" -> "Red"
    "black" -> "Black"
    "green" -> "Green"
    _ -> color
  }
}

fn classify_run_at_depth(run: TestRun, depth: Int) -> String {
  case depth {
    0 -> classify_force(run.force)
    1 -> classify_duration(run.duration)
    2 -> classify_number(run.winning_number)
    3 -> classify_color(run.color)
    _ -> ""
  }
}

fn bucket_counts(
  runs: List(TestRun),
  depth: Int,
) -> List(#(String, Int)) {
  let classified = list.map(runs, fn(run) { classify_run_at_depth(run, depth) })
  let buckets = bucket_names_for_depth(depth)
  list.map(buckets, fn(bucket) {
    let count =
      list.filter(classified, fn(c) { c == bucket })
      |> list.length
    #(bucket, count)
  })
}

fn bucket_names_for_depth(depth: Int) -> List(String) {
  case depth {
    0 -> ["Low Force", "Medium Force", "High Force"]
    1 -> ["Short Duration", "Medium Duration", "Long Duration"]
    2 ->
      list.map(list.range(0, 36), int.to_string)
    3 -> ["Green", "Red", "Black"]
    _ -> []
  }
}

// === Highlight effect ===

fn apply_highlight(selected_nodes: List(String)) -> effect.Effect(Msg) {
  case selected_nodes {
    [] -> effect.from(fn(_d) { do_clear_highlight() })
    nodes -> {
      let json_str =
        json.array(nodes, json.string)
        |> json.to_string
      effect.from(fn(_d) { do_highlight_nodes(json_str) })
    }
  }
}

// === Update ===

fn encode_runs(runs: List(TestRun)) -> String {
  json.array(runs, fn(run) {
    json.object([
      #("force", json.float(run.force)),
      #("duration", json.float(run.duration)),
      #("winning_number", json.int(run.winning_number)),
      #("color", json.string(run.color)),
    ])
  })
  |> json.to_string
}

fn update_chart(runs: List(TestRun)) -> effect.Effect(Msg) {
  effect.from(fn(_dispatch) {
    let json_str = encode_runs(runs)
    do_update_chart(json_str)
  })
}

fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    WsEvent(ws.OnOpen(socket)) -> {
      #(Model(..model, socket: Some(socket)), effect.none())
    }

    WsEvent(ws.OnTextMessage(text)) -> {
      case json.parse(text, messages.server_message_decoder()) {
        Ok(messages.NewTestRun(run)) -> {
          let new_runs = [run, ..model.runs]
          let new_count = model.run_count + 1
          let new_model = Model(..model, runs: new_runs, run_count: new_count)
          #(new_model, update_chart(new_runs))
        }
        Error(_) -> #(model, effect.none())
      }
    }

    WsEvent(ws.OnClose(_)) -> #(Model(..model, socket: None), effect.none())
    WsEvent(ws.InvalidUrl) -> #(model, effect.none())
    WsEvent(ws.OnBinaryMessage(_)) -> #(model, effect.none())

    ToggleStep(depth) -> {
      let is_expanded = list.contains(model.expanded_steps, depth)
      case is_expanded {
        True -> {
          // Collapse: remove step and deselect any nodes from this depth
          let depth_buckets = bucket_names_for_depth(depth)
          let new_selected =
            list.filter(model.selected_nodes, fn(n) {
              !list.contains(depth_buckets, n)
            })
          let new_model =
            Model(
              ..model,
              expanded_steps: list.filter(model.expanded_steps, fn(d) {
                d != depth
              }),
              selected_nodes: new_selected,
            )
          #(new_model, apply_highlight(new_selected))
        }
        False -> {
          #(
            Model(
              ..model,
              expanded_steps: [depth, ..model.expanded_steps],
            ),
            effect.none(),
          )
        }
      }
    }

    ToggleNode(node, depth) -> {
      let is_selected = list.contains(model.selected_nodes, node)
      case is_selected {
        // Clicking the active node: deselect it (clear this step's filter)
        True -> {
          let new_selected =
            list.filter(model.selected_nodes, fn(n) { n != node })
          let new_model = Model(..model, selected_nodes: new_selected)
          #(new_model, apply_highlight(new_selected))
        }
        // Clicking a different node: replace any existing selection at this depth
        False -> {
          let depth_buckets = bucket_names_for_depth(depth)
          let without_depth =
            list.filter(model.selected_nodes, fn(n) {
              !list.contains(depth_buckets, n)
            })
          let new_selected = [node, ..without_depth]
          let new_model = Model(..model, selected_nodes: new_selected)
          #(new_model, apply_highlight(new_selected))
        }
      }
    }

    ClearSelection -> {
      #(
        Model(..model, expanded_steps: [], selected_nodes: []),
        effect.from(fn(_d) { do_clear_highlight() }),
      )
    }
  }
}

// === View ===

fn view(model: Model) -> Element(Msg) {
  html.div(
    [attribute.class("flex h-screen bg-gray-50 text-gray-900 font-sans")],
    [view_gherkin(model), view_chart()],
  )
}

fn view_gherkin(model: Model) -> Element(Msg) {
  html.div(
    [
      attribute.class(
        "w-2/5 bg-white border-r border-gray-200 flex flex-col overflow-y-auto p-6",
      ),
    ],
    [
      html.h1([attribute.class("text-xl font-bold mb-4")], [
        text("Roulette Test Scenario"),
      ]),
      html.div(
        [
          attribute.class(
            "bg-gray-50 rounded-lg p-5 font-mono text-sm leading-relaxed border border-gray-200",
          ),
        ],
        [
          gherkin_line(
            "Feature:",
            " Roulette Wheel Spin",
            "text-purple-700",
            None,
            model,
          ),
          html.div([attribute.class("mt-3")], [
            gherkin_line(
              "Scenario Outline:",
              " Spinning the roulette wheel",
              "text-purple-700",
              None,
              model,
            ),
          ]),
          html.div([attribute.class("ml-4 mt-2 space-y-0")], [
            gherkin_line(
              "Given",
              " a roulette wheel with numbers 0-36",
              "text-blue-600",
              None,
              model,
            ),
            gherkin_line(
              "When",
              " the ball is launched with force <force>",
              "text-blue-600",
              Some(0),
              model,
            ),
            gherkin_line(
              "And",
              " the wheel spins for <duration> seconds",
              "text-blue-600",
              Some(1),
              model,
            ),
            gherkin_line(
              "Then",
              " the ball lands on number <winning_number>",
              "text-blue-600",
              Some(2),
              model,
            ),
            gherkin_line(
              "And",
              " the color is <color>",
              "text-blue-600",
              Some(3),
              model,
            ),
          ]),
        ],
      ),
      case model.selected_nodes {
        [] -> element.none()
        _ ->
          html.div([attribute.class("mt-4")], [
            html.button(
              [
                attribute.class(
                  "text-xs text-gray-500 hover:text-gray-700 underline",
                ),
                event.on_click(ClearSelection),
              ],
              [text("Clear all filters")],
            ),
          ])
      },
      html.div([attribute.class("mt-6 space-y-2")], [
        html.div(
          [attribute.class("flex items-center gap-2 text-sm text-gray-600")],
          [
            html.span(
              [
                attribute.class(
                  "inline-flex items-center justify-center w-8 h-8 rounded-full bg-indigo-100 text-indigo-700 font-bold text-xs",
                ),
              ],
              [text(int.to_string(model.run_count))],
            ),
            text("test runs received"),
          ],
        ),
        case model.socket {
          Some(_) ->
            html.div(
              [attribute.class("flex items-center gap-2 text-sm text-green-600")],
              [
                html.span(
                  [
                    attribute.class(
                      "w-2 h-2 rounded-full bg-green-500 inline-block",
                    ),
                  ],
                  [],
                ),
                text("Connected"),
              ],
            )
          None ->
            html.div(
              [attribute.class("flex items-center gap-2 text-sm text-red-600")],
              [
                html.span(
                  [
                    attribute.class(
                      "w-2 h-2 rounded-full bg-red-500 inline-block",
                    ),
                  ],
                  [],
                ),
                text("Disconnected"),
              ],
            )
        },
      ]),
      html.div([attribute.class("mt-6")], [
        html.h2([attribute.class("text-sm font-semibold text-gray-500 mb-2")], [
          text("RECENT RUNS"),
        ]),
        html.div(
          [attribute.class("space-y-1 max-h-64 overflow-y-auto")],
          list.map(list.take(model.runs, 20), fn(run) {
            html.div(
              [
                attribute.class(
                  "text-xs font-mono px-3 py-1.5 bg-gray-100 rounded flex justify-between",
                ),
              ],
              [
                html.span([], [
                  text(
                    "#"
                    <> int.to_string(run.winning_number)
                    <> " "
                    <> run.color,
                  ),
                ]),
                html.span([attribute.class("text-gray-400")], [
                  text(
                    "F:"
                    <> float_to_short(run.force)
                    <> " D:"
                    <> float_to_short(run.duration)
                    <> "s",
                  ),
                ]),
              ],
            )
          }),
        ),
      ]),
    ],
  )
}

fn float_to_short(f: Float) -> String {
  let s = int.to_string(float_to_int(f))
  let d =
    int.to_string(float_to_int(
      { f -. int_to_float(float_to_int(f)) } *. 10.0,
    ))
  s <> "." <> d
}

@external(javascript, "./client_ffi_helpers.mjs", "floatToInt")
fn float_to_int(f: Float) -> Int

@external(javascript, "./client_ffi_helpers.mjs", "intToFloat")
fn int_to_float(i: Int) -> Float

fn bucket_color(name: String) -> String {
  case name {
    "Low Force" -> "#60a5fa"
    "Medium Force" -> "#f59e0b"
    "High Force" -> "#ef4444"
    "Short Duration" -> "#34d399"
    "Medium Duration" -> "#a78bfa"
    "Long Duration" -> "#f87171"
    "Red" -> "#dc2626"
    "Black" -> "#1f2937"
    "Green" -> "#16a34a"
    _ -> number_color(name)
  }
}

fn number_color(name: String) -> String {
  case name {
    "0" -> "#16a34a"
    "1" | "3" | "5" | "7" | "9" | "12" | "14" | "16" | "18" | "19" | "21"
    | "23" | "25" | "27" | "30" | "32" | "34" | "36" -> "#dc2626"
    _ -> "#1f2937"
  }
}

fn gherkin_line(
  keyword: String,
  rest: String,
  color: String,
  depth: Option(Int),
  model: Model,
) -> Element(Msg) {
  let is_expanded = case depth {
    Some(d) -> list.contains(model.expanded_steps, d)
    None -> False
  }
  let has_selection_at_depth = case depth {
    Some(d) -> {
      let buckets = bucket_names_for_depth(d)
      list.any(model.selected_nodes, fn(n) { list.contains(buckets, n) })
    }
    None -> False
  }
  let line_class = case depth {
    Some(_) ->
      "rounded px-2 py-1 -mx-1 cursor-pointer transition-colors duration-150"
      <> case is_expanded {
        True -> " bg-indigo-100 border border-indigo-300"
        False ->
          case has_selection_at_depth {
            True -> " bg-indigo-50 border border-indigo-200"
            False -> " hover:bg-indigo-50"
          }
      }
    None -> "px-2 py-1 -mx-1"
  }
  let attrs = case depth {
    Some(d) -> [attribute.class(line_class), event.on_click(ToggleStep(d))]
    None -> [attribute.class(line_class)]
  }
  html.div([], [
    html.div(attrs, [
      html.span([attribute.class(color <> " font-bold")], [text(keyword)]),
      html.span([], [text(rest)]),
      case has_selection_at_depth, is_expanded {
        True, False ->
          html.span(
            [attribute.class("ml-2 text-xs text-indigo-500 font-sans")],
            [text("(filtered)")],
          )
        _, _ -> element.none()
      },
    ]),
    case is_expanded, depth {
      True, Some(d) -> view_bucket_panel(model, d)
      _, _ -> element.none()
    },
  ])
}

fn view_bucket_panel(model: Model, depth: Int) -> Element(Msg) {
  let counts = bucket_counts(model.runs, depth)
  let total = model.run_count
  html.div(
    [
      attribute.class(
        "ml-2 my-1 p-3 bg-white rounded-lg border border-indigo-200 shadow-sm font-sans",
      ),
    ],
    [
      html.div(
        [attribute.class("flex items-center justify-between mb-2")],
        [
          html.span(
            [
              attribute.class(
                "text-xs font-semibold text-gray-500 uppercase tracking-wider",
              ),
            ],
            [text(depth_label(depth))],
          ),
        ],
      ),
      html.div(
        [attribute.class("space-y-1")],
        list.map(counts, fn(pair) {
          let #(name, count) = pair
          let is_active = list.contains(model.selected_nodes, name)
          let pct = case total > 0 {
            True -> { int_to_float(count) *. 100.0 } /. int_to_float(total)
            False -> 0.0
          }
          let bg_color = bucket_color(name)
          html.button(
            [
              attribute.class(
                "w-full text-left rounded-md px-3 py-2 text-xs transition-all duration-150 flex items-center gap-2 border "
                <> case is_active {
                  True ->
                    "bg-indigo-50 border-indigo-300 ring-1 ring-indigo-300"
                  False -> "bg-gray-50 border-gray-200 hover:bg-gray-100"
                },
              ),
              event.on_click(ToggleNode(name, depth)),
            ],
            [
              html.span(
                [
                  attribute.class("w-3 h-3 rounded-full inline-block shrink-0"),
                  attribute.style("background-color", bg_color),
                ],
                [],
              ),
              html.span(
                [attribute.class("font-medium text-gray-700 flex-1")],
                [text(name)],
              ),
              html.span([attribute.class("text-gray-500 tabular-nums")], [
                text(int.to_string(count)),
              ]),
              html.span(
                [
                  attribute.class(
                    "text-gray-400 tabular-nums w-12 text-right",
                  ),
                ],
                [text(float_to_short(pct) <> "%")],
              ),
            ],
          )
        }),
      ),
    ],
  )
}

fn depth_label(depth: Int) -> String {
  case depth {
    0 -> "Force Distribution"
    1 -> "Duration Distribution"
    2 -> "Number Range"
    3 -> "Color Distribution"
    _ -> ""
  }
}

fn view_chart() -> Element(Msg) {
  html.div([attribute.class("flex-1 flex flex-col min-w-0 p-4")], [
    html.h2(
      [
        attribute.class(
          "text-sm font-semibold text-gray-500 uppercase tracking-wider mb-2",
        ),
      ],
      [
        text(
          "Data Flow: Force \u{2192} Duration \u{2192} Number \u{2192} Color",
        ),
      ],
    ),
    html.div(
      [attribute.id("sankey-chart"), attribute.class("flex-1 min-h-0")],
      [],
    ),
  ])
}

// === Main ===

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}
