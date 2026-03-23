import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre
import lustre/attribute
import lustre/effect
import lustre/element.{type Element, text}
import lustre/element/html
import lustre/event
import lustre_websocket as ws
import shared/classify
import shared/messages.{
  type RunInfo, type SampleDetail, type SampleSummary, type Stats,
  type StepMetric,
}

// === FFI ===

@external(javascript, "./client_ffi.mjs", "updateChart")
fn do_update_chart(json_string: String) -> Nil

@external(javascript, "./client_ffi.mjs", "highlightNodes")
fn do_highlight_nodes(json_array: String) -> Nil

@external(javascript, "./client_ffi.mjs", "clearHighlight")
fn do_clear_highlight() -> Nil

@external(javascript, "./client_ffi.mjs", "doResizeChart")
fn do_resize_chart() -> Nil

// === Model ===

pub type Tab {
  SankeyTab
  TableTab
}

pub type Model {
  Model(
    stats: Option(Stats),
    socket: Option(ws.WebSocket),
    expanded_steps: List(Int),
    selected_nodes: List(String),
    active_tab: Tab,
    samples: List(SampleSummary),
    expanded_sample_id: Option(Int),
    sample_detail: Option(SampleDetail),
    runs: List(RunInfo),
    selected_run_id: Option(String),
  )
}

// === Messages ===

pub type Msg {
  WsEvent(ws.WebSocketEvent)
  ToggleStep(Int)
  ToggleNode(node: String, depth: Int, ctrl: Bool)
  ClearSelection
  SwitchTab(Tab)
  ClickSample(Int)
  CollapseSample
  SelectRun(run_id: String)
}

// === Init ===

fn init(_flags) -> #(Model, effect.Effect(Msg)) {
  let model =
    Model(
      stats: None,
      socket: None,
      expanded_steps: [],
      selected_nodes: [],
      active_tab: SankeyTab,
      samples: [],
      expanded_sample_id: None,
      sample_detail: None,
      runs: [],
      selected_run_id: None,
    )
  #(model, ws.init("/ws", WsEvent))
}

// === Highlight effect ===

fn resize_chart() -> effect.Effect(Msg) {
  effect.from(fn(_d) { do_resize_chart() })
}

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

// === WebSocket send helpers ===

fn ws_send(
  socket: Option(ws.WebSocket),
  msg: messages.ClientMessage,
) -> effect.Effect(Msg) {
  case socket {
    Some(s) -> {
      let json_str = messages.encode_client_message(msg)
      ws.send(s, json_str)
    }
    None -> effect.none()
  }
}

// === Update ===

fn encode_links(links: List(messages.SankeyLink)) -> String {
  json.array(links, fn(link) {
    json.object([
      #("source", json.string(link.source)),
      #("target", json.string(link.target)),
      #("value", json.int(link.value)),
    ])
  })
  |> json.to_string
}

fn update_chart(stats: Stats) -> effect.Effect(Msg) {
  effect.from(fn(_dispatch) {
    let json_str = encode_links(stats.links)
    do_update_chart(json_str)
  })
}

fn send_selection_query(model: Model) -> effect.Effect(Msg) {
  case model.selected_nodes {
    [] -> ws_send(model.socket, messages.ClearSelectionQuery)
    nodes -> ws_send(model.socket, messages.SetSelection(nodes))
  }
}

fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    WsEvent(ws.OnOpen(socket)) -> {
      #(Model(..model, socket: Some(socket)), effect.none())
    }

    WsEvent(ws.OnTextMessage(text)) -> {
      case json.parse(text, messages.server_message_decoder()) {
        Ok(messages.StatsSnapshot(stats)) -> {
          let new_model = Model(..model, stats: Some(stats))
          #(new_model, update_chart(stats))
        }
        Ok(messages.AllSamples(samples)) -> {
          #(
            Model(
              ..model,
              samples: samples,
              expanded_sample_id: None,
              sample_detail: None,
            ),
            effect.none(),
          )
        }
        Ok(messages.MatchingSamples(samples)) -> {
          #(
            Model(
              ..model,
              samples: samples,
              expanded_sample_id: None,
              sample_detail: None,
            ),
            effect.none(),
          )
        }
        Ok(messages.MatchingSampleAppend(sample)) -> {
          #(
            Model(..model, samples: [sample, ..model.samples]),
            effect.none(),
          )
        }
        Ok(messages.NewSample(sample)) -> {
          #(
            Model(..model, samples: [sample, ..model.samples]),
            effect.none(),
          )
        }
        Ok(messages.SampleDetailResponse(detail)) -> {
          #(Model(..model, sample_detail: Some(detail)), effect.none())
        }
        Ok(messages.RunList(runs)) -> {
          #(Model(..model, runs: runs), effect.none())
        }
        Ok(messages.RunCreated(run)) -> {
          #(
            Model(..model, runs: [run, ..model.runs]),
            effect.none(),
          )
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
          let depth_buckets = classify.bucket_names_for_depth(depth)
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
          let eff =
            effect.batch([
              apply_highlight(new_selected),
              send_selection_query(new_model),
            ])
          #(new_model, eff)
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

    ToggleNode(node, depth, ctrl) -> {
      let is_selected = list.contains(model.selected_nodes, node)
      let new_selected = case is_selected {
        True -> list.filter(model.selected_nodes, fn(n) { n != node })
        False ->
          case ctrl {
            True -> [node, ..model.selected_nodes]
            False -> {
              let depth_buckets = classify.bucket_names_for_depth(depth)
              let without_depth =
                list.filter(model.selected_nodes, fn(n) {
                  !list.contains(depth_buckets, n)
                })
              [node, ..without_depth]
            }
          }
      }
      let new_model = Model(..model, selected_nodes: new_selected)
      let eff =
        effect.batch([
          apply_highlight(new_selected),
          send_selection_query(new_model),
        ])
      #(new_model, eff)
    }

    ClearSelection -> {
      let new_model =
        Model(..model, expanded_steps: [], selected_nodes: [])
      let eff =
        effect.batch([
          effect.from(fn(_d) { do_clear_highlight() }),
          ws_send(model.socket, messages.ClearSelectionQuery),
        ])
      #(new_model, eff)
    }

    SwitchTab(tab) -> {
      let eff = case tab {
        SankeyTab -> resize_chart()
        TableTab -> effect.none()
      }
      #(Model(..model, active_tab: tab), eff)
    }

    ClickSample(id) -> {
      case model.expanded_sample_id {
        Some(current_id) if current_id == id -> {
          #(
            Model(..model, expanded_sample_id: None, sample_detail: None),
            effect.none(),
          )
        }
        _ -> {
          let new_model =
            Model(..model, expanded_sample_id: Some(id), sample_detail: None)
          let eff =
            ws_send(model.socket, messages.RequestSampleDetail(id))
          #(new_model, eff)
        }
      }
    }

    CollapseSample -> {
      #(
        Model(..model, expanded_sample_id: None, sample_detail: None),
        effect.none(),
      )
    }

    SelectRun(run_id) -> {
      let new_model =
        Model(
          ..model,
          selected_run_id: Some(run_id),
          stats: None,
          samples: [],
          expanded_sample_id: None,
          sample_detail: None,
          selected_nodes: [],
          expanded_steps: [],
        )
      let eff =
        effect.batch([
          ws_send(model.socket, messages.SelectRun(run_id)),
          effect.from(fn(_d) { do_clear_highlight() }),
        ])
      #(new_model, eff)
    }
  }
}

// === View ===

fn view(model: Model) -> Element(Msg) {
  html.div(
    [attribute.class("flex h-screen bg-gray-50 text-gray-900 font-sans")],
    [
      view_sidebar(model),
      case model.selected_run_id {
        Some(_) ->
          html.div(
            [attribute.class("flex flex-1 min-w-0")],
            [view_gherkin(model), view_right_panel(model)],
          )
        None ->
          html.div(
            [
              attribute.class(
                "flex-1 flex items-center justify-center text-gray-400 text-lg",
              ),
            ],
            [text("Select a run from the sidebar")],
          )
      },
    ],
  )
}

fn truncate_id(id: String) -> String {
  case string.length(id) > 8 {
    True -> string.slice(id, 0, 8) <> "..."
    False -> id
  }
}

fn view_sidebar(model: Model) -> Element(Msg) {
  html.div(
    [
      attribute.class(
        "w-52 bg-white border-r border-gray-200 flex flex-col overflow-y-auto",
      ),
    ],
    [
      html.div(
        [
          attribute.class(
            "px-3 py-3 border-b border-gray-200 text-xs font-semibold text-gray-500 uppercase tracking-wider",
          ),
        ],
        [text("Runs")],
      ),
      html.div(
        [attribute.class("flex-1 overflow-y-auto")],
        case model.runs {
          [] ->
            [
              html.div(
                [attribute.class("px-3 py-4 text-xs text-gray-400")],
                [text("No runs yet")],
              ),
            ]
          runs ->
            list.map(runs, fn(run) {
              let is_selected = model.selected_run_id == Some(run.run_id)
              html.button(
                [
                  attribute.class(
                    "w-full text-left px-3 py-2 text-xs border-b border-gray-100 transition-colors "
                    <> case is_selected {
                      True -> "bg-indigo-50 border-l-2 border-l-indigo-500"
                      False -> "hover:bg-gray-50"
                    },
                  ),
                  event.on_click(SelectRun(run.run_id)),
                ],
                [
                  html.div(
                    [attribute.class("font-mono font-medium text-gray-700")],
                    [text(truncate_id(run.run_id))],
                  ),
                  html.div(
                    [attribute.class("text-gray-400 mt-0.5")],
                    [
                      text(
                        int.to_string(run.sample_count)
                        <> " samples",
                      ),
                    ],
                  ),
                ],
              )
            })
        },
      ),
    ],
  )
}

fn get_total(model: Model) -> Int {
  case model.stats {
    Some(stats) -> stats.total
    None -> 0
  }
}

fn get_bucket_counts(
  model: Model,
  depth: Int,
) -> List(#(String, Int)) {
  let counts = case model.stats {
    Some(stats) ->
      case depth {
        0 -> stats.force_counts
        1 -> stats.duration_counts
        2 -> stats.number_counts
        3 -> stats.color_counts
        _ -> []
      }
    None -> []
  }
  let count_map =
    list.map(counts, fn(bc) { #(bc.name, bc.count) })
  let buckets = classify.bucket_names_for_depth(depth)
  list.map(buckets, fn(name) {
    case list.find(count_map, fn(pair) { pair.0 == name }) {
      Ok(pair) -> pair
      Error(_) -> #(name, 0)
    }
  })
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
    ],
  )
}

fn bucket_color(name: String) -> String {
  case name {
    "Low Force" | "Short Duration" -> "#60a5fa"
    "Medium Force" | "Medium Duration" -> "#f59e0b"
    "High Force" | "Long Duration" -> "#a855f7"
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
      let buckets = classify.bucket_names_for_depth(d)
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

@external(javascript, "./client_ffi_helpers.mjs", "intToFloat")
fn int_to_float(i: Int) -> Float

fn float_to_short(f: Float) -> String {
  let i = float_to_int(f)
  let s = int.to_string(i)
  let d =
    int.to_string(float_to_int(
      { f -. int_to_float(i) } *. 10.0,
    ))
  s <> "." <> d
}

@external(javascript, "./client_ffi_helpers.mjs", "floatToInt")
fn float_to_int(f: Float) -> Int

fn view_bucket_panel(model: Model, depth: Int) -> Element(Msg) {
  let counts = get_bucket_counts(model, depth)
  let total = get_total(model)
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
              event.on("click", {
                decode.field("ctrlKey", decode.bool, fn(ctrl) {
                  decode.success(ToggleNode(name, depth, ctrl))
                })
              }),
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

// === Right panel with tabs ===

fn view_right_panel(model: Model) -> Element(Msg) {
  html.div([attribute.class("flex-1 flex flex-col min-w-0 p-4")], [
    html.div(
      [attribute.class("flex border-b border-gray-200 mb-3")],
      [
        tab_button("Sankey", SankeyTab, model.active_tab),
        tab_button(
          "Samples (" <> int.to_string(list.length(model.samples)) <> ")",
          TableTab,
          model.active_tab,
        ),
      ],
    ),
    case model.active_tab {
      SankeyTab -> view_sankey_content()
      TableTab -> view_table_content(model)
    },
  ])
}

fn tab_button(label: String, tab: Tab, active_tab: Tab) -> Element(Msg) {
  let is_active = tab == active_tab
  html.button(
    [
      attribute.class(
        "px-4 py-2 text-sm font-medium border-b-2 transition-colors "
        <> case is_active {
          True -> "border-indigo-500 text-indigo-600"
          False ->
            "border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300"
        },
      ),
      event.on_click(SwitchTab(tab)),
    ],
    [text(label)],
  )
}

fn view_sankey_content() -> Element(Msg) {
  html.div([attribute.class("flex-1 flex flex-col min-h-0")], [
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

fn view_table_content(model: Model) -> Element(Msg) {
  html.div([attribute.class("flex-1 flex flex-col min-h-0 overflow-hidden")], [
    html.div([attribute.class("flex-1 overflow-y-auto")], [
      case model.samples {
        [] ->
          html.div(
            [attribute.class("text-center text-gray-400 py-12")],
            [text("No samples yet")],
          )
        samples -> view_samples_table(samples, model)
      },
    ]),
    case model.expanded_sample_id {
      Some(_) -> view_detail_panel(model)
      None -> element.none()
    },
  ])
}

fn view_samples_table(
  samples: List(SampleSummary),
  model: Model,
) -> Element(Msg) {
  html.table(
    [attribute.class("w-full text-sm")],
    [
      html.thead([], [
        html.tr(
          [
            attribute.class(
              "bg-gray-100 text-left text-xs font-semibold text-gray-500 uppercase tracking-wider",
            ),
          ],
          [
            html.th([attribute.class("px-3 py-2 w-16")], [text("ID")]),
            html.th([attribute.class("px-3 py-2")], [text("Start")]),
            html.th([attribute.class("px-3 py-2")], [text("End")]),
            html.th([attribute.class("px-3 py-2 w-20")], [text("Status")]),
          ],
        ),
      ]),
      html.tbody(
        [],
        list.map(samples, fn(sample) { view_sample_row(sample, model) }),
      ),
    ],
  )
}

fn view_sample_row(sample: SampleSummary, model: Model) -> Element(Msg) {
  let is_expanded = model.expanded_sample_id == Some(sample.id)
  html.tr(
    [
      attribute.class(
        "border-b border-gray-100 cursor-pointer transition-colors "
        <> case is_expanded {
          True -> "bg-indigo-50"
          False -> "hover:bg-gray-50"
        },
      ),
      event.on_click(ClickSample(sample.id)),
    ],
    [
      html.td(
        [attribute.class("px-3 py-2 font-mono text-xs text-gray-600")],
        [text(int.to_string(sample.id))],
      ),
      html.td(
        [attribute.class("px-3 py-2 text-xs text-gray-600")],
        [text(format_date(sample.start_date))],
      ),
      html.td(
        [attribute.class("px-3 py-2 text-xs text-gray-600")],
        [text(format_date(sample.end_date))],
      ),
      html.td([attribute.class("px-3 py-2")], [
        status_badge(sample.status),
      ]),
    ],
  )
}

fn format_date(iso: String) -> String {
  case iso {
    "" -> "-"
    d -> d
  }
}

fn status_badge(status: String) -> Element(Msg) {
  let cls = case status {
    "pass" -> "bg-green-100 text-green-700"
    "fail" -> "bg-red-100 text-red-700"
    _ -> "bg-gray-100 text-gray-600"
  }
  html.span(
    [attribute.class("inline-block px-2 py-0.5 rounded text-xs font-medium " <> cls)],
    [text(status)],
  )
}

fn view_detail_panel(model: Model) -> Element(Msg) {
  html.div(
    [
      attribute.class(
        "border-t border-gray-200 bg-white max-h-[50%] overflow-y-auto p-4",
      ),
    ],
    [
      case model.sample_detail {
        None ->
          html.div(
            [attribute.class("text-center text-gray-400 py-4")],
            [text("Loading...")],
          )
        Some(detail) -> view_sample_detail(detail)
      },
    ],
  )
}

fn view_sample_detail(detail: SampleDetail) -> Element(Msg) {
  html.div([attribute.class("space-y-4")], [
    html.div(
      [attribute.class("flex items-center justify-between")],
      [
        html.h3([attribute.class("text-sm font-bold text-gray-700")], [
          text("Sample #" <> int.to_string(detail.id)),
        ]),
        html.div([attribute.class("flex gap-2")], [
          status_badge(detail.status),
          html.button(
            [
              attribute.class(
                "text-xs text-gray-400 hover:text-gray-600 ml-2",
              ),
              event.on_click(CollapseSample),
            ],
            [text("Close")],
          ),
        ]),
      ],
    ),
    html.div(
      [attribute.class("grid grid-cols-2 gap-2 text-xs")],
      [
        detail_field("Force", float_to_short(detail.force) <> " (" <> detail.force_label <> ")"),
        detail_field("Duration", float_to_short(detail.duration) <> " (" <> detail.duration_label <> ")"),
        detail_field("Number", int.to_string(detail.winning_number) <> " (" <> detail.number_label <> ")"),
        detail_field("Color", detail.color <> " (" <> detail.color_label <> ")"),
      ],
    ),
    case detail.gherkin_text {
      "" -> element.none()
      gherkin ->
        html.div([], [
          html.h4(
            [
              attribute.class(
                "text-xs font-semibold text-gray-500 uppercase tracking-wider mb-1",
              ),
            ],
            [text("Gherkin")],
          ),
          html.pre(
            [
              attribute.class(
                "bg-gray-50 rounded p-3 text-xs font-mono whitespace-pre-wrap border border-gray-200",
              ),
            ],
            [text(gherkin)],
          ),
        ])
    },
    case detail.step_metrics {
      [] -> element.none()
      metrics ->
        html.div([], [
          html.h4(
            [
              attribute.class(
                "text-xs font-semibold text-gray-500 uppercase tracking-wider mb-1",
              ),
            ],
            [text("Steps")],
          ),
          view_step_metrics_table(metrics),
        ])
    },
    case detail.logs {
      [] -> element.none()
      logs ->
        html.div([], [
          html.h4(
            [
              attribute.class(
                "text-xs font-semibold text-gray-500 uppercase tracking-wider mb-1",
              ),
            ],
            [text("Logs")],
          ),
          html.div(
            [
              attribute.class(
                "bg-gray-900 text-green-400 rounded p-3 text-xs font-mono max-h-40 overflow-y-auto",
              ),
            ],
            list.map(logs, fn(line) {
              html.div([], [text(line)])
            }),
          ),
        ])
    },
  ])
}

fn detail_field(label: String, value: String) -> Element(Msg) {
  html.div([attribute.class("bg-gray-50 rounded px-2 py-1 border border-gray-200")], [
    html.span([attribute.class("text-gray-500")], [text(label <> ": ")]),
    html.span([attribute.class("font-medium text-gray-700")], [text(value)]),
  ])
}

fn view_step_metrics_table(metrics: List(StepMetric)) -> Element(Msg) {
  html.table(
    [attribute.class("w-full text-xs border border-gray-200 rounded")],
    [
      html.thead([], [
        html.tr(
          [attribute.class("bg-gray-100 text-left text-gray-500")],
          [
            html.th([attribute.class("px-2 py-1")], [text("Step")]),
            html.th([attribute.class("px-2 py-1 w-24 text-right")], [
              text("Duration (ms)"),
            ]),
            html.th([attribute.class("px-2 py-1 w-16")], [text("Status")]),
          ],
        ),
      ]),
      html.tbody(
        [],
        list.map(metrics, fn(m) {
          html.tr(
            [attribute.class("border-t border-gray-100")],
            [
              html.td([attribute.class("px-2 py-1 text-gray-700")], [
                text(m.name),
              ]),
              html.td(
                [
                  attribute.class(
                    "px-2 py-1 text-right font-mono text-gray-600",
                  ),
                ],
                [text(float_to_short(m.duration_ms))],
              ),
              html.td([attribute.class("px-2 py-1")], [
                status_badge(m.status),
              ]),
            ],
          )
        }),
      ),
    ],
  )
}

// === Main ===

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}
