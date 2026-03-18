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
  html.div(
    [attribute.styles([#("display", "flex"), #("height", "100vh")])],
    [
      // Left sidebar: queue list
      html.div(
        [
          attribute.styles([
            #("width", "250px"),
            #("border-right", "1px solid #ccc"),
            #("padding", "16px"),
            #("overflow-y", "auto"),
          ]),
        ],
        [
          html.h2([], [text("Queues")]),
          case model.queues {
            [] -> html.p([attribute.styles([#("color", "#888")])], [text("No queues yet. POST to /publish/<name> to create one.")])
            queues ->
              html.ul(
                [attribute.styles([#("list-style", "none"), #("padding", "0")])],
                list.map(queues, fn(queue) {
                  let is_selected = model.selected_queue == Some(queue)
                  html.li(
                    [
                      event.on_click(ClickQueue(queue)),
                      attribute.styles([
                        #("cursor", "pointer"),
                        #("padding", "8px 12px"),
                        #("margin", "4px 0"),
                        #("border-radius", "4px"),
                        #("background", case is_selected {
                          True -> "#4a90d9"
                          False -> "#f0f0f0"
                        }),
                        #("color", case is_selected {
                          True -> "white"
                          False -> "#333"
                        }),
                      ]),
                    ],
                    [text(queue)],
                  )
                }),
              )
          },
        ],
      ),
      // Right panel: messages
      html.div(
        [
          attribute.styles([
            #("flex", "1"),
            #("padding", "16px"),
            #("overflow-y", "auto"),
          ]),
        ],
        [
          case model.selected_queue {
            None ->
              html.p(
                [attribute.styles([#("color", "#888")])],
                [text("Select a queue to view messages")],
              )
            Some(queue) -> {
              let msgs = case dict.get(model.messages, queue) {
                Ok(m) -> m
                Error(_) -> []
              }
              html.div([], [
                html.h2([], [text("Queue: " <> queue)]),
                case msgs {
                  [] -> html.p([attribute.styles([#("color", "#888")])], [text("No messages in this queue yet.")])
                  _ ->
                    html.ul(
                      [attribute.styles([#("list-style", "none"), #("padding", "0")])],
                      list.map(msgs, fn(m) {
                        html.li(
                          [
                            attribute.styles([
                              #("padding", "8px 12px"),
                              #("margin", "4px 0"),
                              #("background", "#f8f8f8"),
                              #("border-radius", "4px"),
                              #("border-left", "3px solid #4a90d9"),
                            ]),
                          ],
                          [text(m)],
                        )
                      }),
                    )
                },
              ])
            }
          },
        ],
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
