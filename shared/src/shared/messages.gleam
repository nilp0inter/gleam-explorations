import gleam/dynamic/decode
import gleam/json

// === Server -> Client Messages ===

pub type ServerMessage {
  QueueList(queues: List(String))
  NewQueue(name: String)
  QueueState(queue: String, messages: List(String))
  NewMessageInQueue(queue: String, message: String)
}

// === Client -> Server Messages ===

pub type ClientMessage {
  Subscribe(queue: String)
  Unsubscribe(queue: String)
}

// === Encoders ===

pub fn encode_server_message(msg: ServerMessage) -> String {
  case msg {
    QueueList(queues) ->
      json.object([
        #("type", json.string("queue_list")),
        #("queues", json.array(queues, json.string)),
      ])
    NewQueue(name) ->
      json.object([
        #("type", json.string("new_queue")),
        #("name", json.string(name)),
      ])
    QueueState(queue, messages) ->
      json.object([
        #("type", json.string("queue_state")),
        #("queue", json.string(queue)),
        #("messages", json.array(messages, json.string)),
      ])
    NewMessageInQueue(queue, message) ->
      json.object([
        #("type", json.string("new_message_in_queue")),
        #("queue", json.string(queue)),
        #("message", json.string(message)),
      ])
  }
  |> json.to_string
}

pub fn encode_client_message(msg: ClientMessage) -> String {
  case msg {
    Subscribe(queue) ->
      json.object([
        #("type", json.string("subscribe")),
        #("queue", json.string(queue)),
      ])
    Unsubscribe(queue) ->
      json.object([
        #("type", json.string("unsubscribe")),
        #("queue", json.string(queue)),
      ])
  }
  |> json.to_string
}

// === Decoders ===

pub fn server_message_decoder() -> decode.Decoder(ServerMessage) {
  use tag <- decode.then(decode.at(["type"], decode.string))
  case tag {
    "queue_list" -> {
      decode.at(["queues"], decode.list(decode.string))
      |> decode.map(QueueList)
    }
    "new_queue" -> {
      decode.at(["name"], decode.string)
      |> decode.map(NewQueue)
    }
    "queue_state" -> {
      decode.field("queue", decode.string, fn(queue) {
        decode.field("messages", decode.list(decode.string), fn(messages) {
          decode.success(QueueState(queue, messages))
        })
      })
    }
    "new_message_in_queue" -> {
      decode.field("queue", decode.string, fn(queue) {
        decode.field("message", decode.string, fn(message) {
          decode.success(NewMessageInQueue(queue, message))
        })
      })
    }
    _ -> decode.failure(QueueList([]), "ServerMessage")
  }
}

pub fn client_message_decoder() -> decode.Decoder(ClientMessage) {
  use tag <- decode.then(decode.at(["type"], decode.string))
  case tag {
    "subscribe" -> {
      decode.at(["queue"], decode.string)
      |> decode.map(Subscribe)
    }
    "unsubscribe" -> {
      decode.at(["queue"], decode.string)
      |> decode.map(Unsubscribe)
    }
    _ -> decode.failure(Subscribe(""), "ClientMessage")
  }
}
