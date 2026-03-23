import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor

pub type State {
  State(connected_clients: List(Subject(String)))
}

pub type Msg {
  ClientConnected(client: Subject(String))
  ClientDisconnected(client: Subject(String))
  BroadcastTestRun(json: String)
}

pub fn start() -> Result(Subject(Msg), actor.StartError) {
  let result =
    actor.new(State(connected_clients: []))
    |> actor.on_message(handle_message)
    |> actor.start()

  case result {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    ClientConnected(client) -> {
      actor.continue(
        State(connected_clients: [client, ..state.connected_clients]),
      )
    }

    ClientDisconnected(client) -> {
      let connected =
        list.filter(state.connected_clients, fn(c) { c != client })
      actor.continue(State(connected_clients: connected))
    }

    BroadcastTestRun(json) -> {
      list.each(state.connected_clients, fn(client) {
        process.send(client, json)
      })
      actor.continue(state)
    }
  }
}
