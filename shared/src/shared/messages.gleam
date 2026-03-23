import gleam/dynamic/decode
import gleam/json

// === Types ===

pub type TestRun {
  TestRun(force: Float, duration: Float, winning_number: Int, color: String)
}

// === Server -> Client Messages ===

pub type ServerMessage {
  NewTestRun(run: TestRun)
}

// === Client -> Server Messages ===

pub type ClientMessage {
  SubmitTestRun(run: TestRun)
}

// === Encoders ===

fn encode_test_run_fields(run: TestRun) -> List(#(String, json.Json)) {
  [
    #("force", json.float(run.force)),
    #("duration", json.float(run.duration)),
    #("winning_number", json.int(run.winning_number)),
    #("color", json.string(run.color)),
  ]
}

pub fn encode_server_message(msg: ServerMessage) -> String {
  case msg {
    NewTestRun(run) ->
      json.object([
        #("type", json.string("new_test_run")),
        ..encode_test_run_fields(run)
      ])
  }
  |> json.to_string
}

pub fn encode_client_message(msg: ClientMessage) -> String {
  case msg {
    SubmitTestRun(run) ->
      json.object([
        #("type", json.string("submit_test_run")),
        ..encode_test_run_fields(run)
      ])
  }
  |> json.to_string
}

// === Decoders ===

fn test_run_decoder() -> decode.Decoder(TestRun) {
  decode.field("force", decode.float, fn(force) {
    decode.field("duration", decode.float, fn(duration) {
      decode.field("winning_number", decode.int, fn(winning_number) {
        decode.field("color", decode.string, fn(color) {
          decode.success(TestRun(force:, duration:, winning_number:, color:))
        })
      })
    })
  })
}

pub fn server_message_decoder() -> decode.Decoder(ServerMessage) {
  use tag <- decode.then(decode.at(["type"], decode.string))
  case tag {
    "new_test_run" -> test_run_decoder() |> decode.map(NewTestRun)
    _ -> decode.failure(NewTestRun(TestRun(0.0, 0.0, 0, "")), "ServerMessage")
  }
}

pub fn client_message_decoder() -> decode.Decoder(ClientMessage) {
  use tag <- decode.then(decode.at(["type"], decode.string))
  case tag {
    "submit_test_run" -> test_run_decoder() |> decode.map(SubmitTestRun)
    _ ->
      decode.failure(
        SubmitTestRun(TestRun(0.0, 0.0, 0, "")),
        "ClientMessage",
      )
  }
}
