import gleam/dict.{type Dict}
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
import shared/messages

// === Model ===

pub type Model {
  Model(
    queues: List(String),
    selected_queue: Option(String),
    messages: Dict(String, List(String)),
    socket: Option(ws.WebSocket),
  )
}

// === Messages ===

pub type Msg {
  WsEvent(ws.WebSocketEvent)
  ClickQueue(String)
}

// === Init ===

fn init(_flags) -> #(Model, effect.Effect(Msg)) {
  let model =
    Model(
      queues: [],
      selected_queue: None,
      messages: dict.new(),
      socket: None,
    )
  #(model, ws.init("/ws", WsEvent))
}

// === Update ===

fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    WsEvent(ws.OnOpen(socket)) -> {
      #(Model(..model, socket: Some(socket)), effect.none())
    }

    WsEvent(ws.OnTextMessage(text)) -> {
      case json.parse(text, messages.server_message_decoder()) {
        Ok(messages.QueueList(queues)) ->
          #(Model(..model, queues: queues), effect.none())

        Ok(messages.NewQueue(name)) ->
          #(
            Model(..model, queues: list.append(model.queues, [name])),
            effect.none(),
          )

        Ok(messages.QueueState(queue, msgs)) -> {
          let new_messages = dict.insert(model.messages, queue, msgs)
          #(Model(..model, messages: new_messages), effect.none())
        }

        Ok(messages.NewMessageInQueue(queue, message)) -> {
          let current = case dict.get(model.messages, queue) {
            Ok(msgs) -> msgs
            Error(_) -> []
          }
          let new_messages =
            dict.insert(model.messages, queue, list.append(current, [message]))
          #(Model(..model, messages: new_messages), effect.none())
        }

        Error(_) -> #(model, effect.none())
      }
    }

    WsEvent(ws.OnClose(_)) -> #(Model(..model, socket: None), effect.none())

    WsEvent(ws.InvalidUrl) -> #(model, effect.none())

    WsEvent(ws.OnBinaryMessage(_)) -> #(model, effect.none())

    ClickQueue(queue) -> {
      case model.socket {
        Some(socket) -> {
          let unsub_eff = case model.selected_queue {
            Some(old_queue) if old_queue != queue ->
              ws.send(
                socket,
                messages.encode_client_message(messages.Unsubscribe(old_queue)),
              )
            _ -> effect.none()
          }
          let sub_eff =
            ws.send(
              socket,
              messages.encode_client_message(messages.Subscribe(queue)),
            )
          #(
            Model(..model, selected_queue: Some(queue)),
            effect.batch([unsub_eff, sub_eff]),
          )
        }
        None -> #(model, effect.none())
      }
    }
  }
}

// === View ===

fn view(model: Model) -> Element(Msg) {
  html.div([attribute.class("flex h-screen bg-gray-50 text-gray-900 font-sans")], [
    // Left sidebar: queue list
    html.div(
      [attribute.class("w-72 bg-white border-r border-gray-200 flex flex-col")],
      [
        html.div(
          [attribute.class("px-5 py-4 text-sm font-semibold uppercase tracking-wider text-gray-500 border-b border-gray-200")],
          [text("Queues")],
        ),
        html.div([attribute.class("flex-1 overflow-y-auto p-3")], [
          case model.queues {
            [] ->
              html.p(
                [attribute.class("px-2 py-8 text-sm text-gray-400 text-center")],
                [text("No queues yet. POST to /publish/<name> to create one.")],
              )
            queues ->
              html.ul(
                [attribute.class("space-y-1")],
                list.map(queues, fn(queue) {
                  let is_selected = model.selected_queue == Some(queue)
                  html.li(
                    [
                      event.on_click(ClickQueue(queue)),
                      attribute.class(case is_selected {
                        True ->
                          "cursor-pointer px-3 py-2 rounded-lg text-sm font-medium bg-indigo-600 text-white"
                        False ->
                          "cursor-pointer px-3 py-2 rounded-lg text-sm font-medium text-gray-700 hover:bg-gray-100 transition-colors"
                      }),
                    ],
                    [text(queue)],
                  )
                }),
              )
          },
        ]),
      ],
    ),
    // Right panel: messages
    html.div(
      [attribute.class("flex-1 flex flex-col min-w-0")],
      [
        case model.selected_queue {
          None ->
            html.div(
              [attribute.class("flex-1 flex items-center justify-center")],
              [
                html.p(
                  [attribute.class("text-gray-400 text-lg")],
                  [text("Select a queue to view messages")],
                ),
              ],
            )
          Some(queue) -> {
            let msgs = case dict.get(model.messages, queue) {
              Ok(m) -> m
              Error(_) -> []
            }
            html.div([attribute.class("flex-1 flex flex-col min-h-0")], [
              html.div(
                [attribute.class("px-6 py-4 text-lg font-semibold border-b border-gray-200 bg-white")],
                [text("Queue: " <> queue)],
              ),
              html.div([attribute.class("flex-1 overflow-y-auto p-6")], [
                case msgs {
                  [] ->
                    html.p(
                      [attribute.class("text-gray-400 text-sm py-8 text-center")],
                      [text("No messages in this queue yet.")],
                    )
                  _ ->
                    html.ul(
                      [attribute.class("space-y-2")],
                      list.map(msgs, fn(m) {
                        html.li(
                          [attribute.class("px-4 py-3 bg-white rounded-lg border border-gray-200 text-sm font-mono shadow-sm")],
                          [text(m)],
                        )
                      }),
                    )
                },
              ]),
            ])
          }
        },
      ],
    ),
  ])
}

// === Main ===

pub fn main() {
  let app = lustre.application(init, update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
  Nil
}
