import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre
import lustre/attribute
import lustre/effect
import lustre/element.{type Element, text}
import lustre/element/html
import lustre_websocket as ws
import shared/messages.{type TestRun}

// === FFI ===

@external(javascript, "./client_ffi.mjs", "updateChart")
fn do_update_chart(json_string: String) -> Nil

// === Model ===

pub type Model {
  Model(runs: List(TestRun), run_count: Int, socket: Option(ws.WebSocket))
}

// === Messages ===

pub type Msg {
  WsEvent(ws.WebSocketEvent)
}

// === Init ===

fn init(_flags) -> #(Model, effect.Effect(Msg)) {
  let model = Model(runs: [], run_count: 0, socket: None)
  #(model, ws.init("/ws", WsEvent))
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
          gherkin_line("Feature:", " Roulette Wheel Spin", "text-purple-700"),
          html.div([attribute.class("mt-3")], [
            gherkin_line(
              "Scenario Outline:",
              " Spinning the roulette wheel",
              "text-purple-700",
            ),
          ]),
          html.div([attribute.class("ml-4 mt-2 space-y-1")], [
            gherkin_line(
              "Given",
              " a roulette wheel with numbers 0-36",
              "text-blue-600",
            ),
            gherkin_line(
              "When",
              " the ball is launched with force <force>",
              "text-blue-600",
            ),
            gherkin_line(
              "And",
              " the wheel spins for <duration> seconds",
              "text-blue-600",
            ),
            gherkin_line(
              "Then",
              " the ball lands on number <winning_number>",
              "text-blue-600",
            ),
            gherkin_line(
              "And",
              " the color is <color>",
              "text-blue-600",
            ),
          ]),
        ],
      ),
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
                  [attribute.class("w-2 h-2 rounded-full bg-green-500 inline-block")],
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
                  [attribute.class("w-2 h-2 rounded-full bg-red-500 inline-block")],
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
                    "F:" <> float_to_short(run.force) <> " D:" <> float_to_short(run.duration) <> "s",
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
  let d = int.to_string(float_to_int({ f -. int_to_float(float_to_int(f)) } *. 10.0))
  s <> "." <> d
}

@external(javascript, "./client_ffi_helpers.mjs", "floatToInt")
fn float_to_int(f: Float) -> Int

@external(javascript, "./client_ffi_helpers.mjs", "intToFloat")
fn int_to_float(i: Int) -> Float

fn gherkin_line(
  keyword: String,
  rest: String,
  color: String,
) -> Element(Msg) {
  html.div([], [
    html.span([attribute.class(color <> " font-bold")], [text(keyword)]),
    html.span([], [text(rest)]),
  ])
}

fn view_chart() -> Element(Msg) {
  html.div([attribute.class("flex-1 flex flex-col min-w-0 p-4")], [
    html.h2(
      [
        attribute.class(
          "text-sm font-semibold text-gray-500 uppercase tracking-wider mb-2",
        ),
      ],
      [text("Data Flow: Force → Duration → Number → Color")],
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
