import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import shared/messages

pub type State {
  State(
    queues: Dict(String, List(String)),
    subscribers: Dict(String, List(Subject(String))),
    connected_clients: List(Subject(String)),
  )
}

pub type Msg {
  ClientConnected(client: Subject(String))
  ClientDisconnected(client: Subject(String))
  SubscribeToQueue(queue: String, client: Subject(String))
  UnsubscribeFromQueue(queue: String, client: Subject(String))
  PublishMessage(queue: String, message: String)
}

pub fn start() -> Result(Subject(Msg), actor.StartError) {
  let result =
    actor.new(State(
      queues: dict.new(),
      subscribers: dict.new(),
      connected_clients: [],
    ))
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
      let queue_names = dict.keys(state.queues)
      let json_msg =
        messages.encode_server_message(messages.QueueList(queue_names))
      process.send(client, json_msg)
      actor.continue(
        State(..state, connected_clients: [client, ..state.connected_clients]),
      )
    }

    ClientDisconnected(client) -> {
      let connected =
        list.filter(state.connected_clients, fn(c) { c != client })
      let subscribers =
        dict.map_values(state.subscribers, fn(_k, subs) {
          list.filter(subs, fn(s) { s != client })
        })
      actor.continue(
        State(..state, connected_clients: connected, subscribers: subscribers),
      )
    }

    SubscribeToQueue(queue, client) -> {
      let current_subs = case dict.get(state.subscribers, queue) {
        Ok(subs) -> subs
        Error(_) -> []
      }
      let new_subscribers =
        dict.insert(state.subscribers, queue, [client, ..current_subs])
      let queue_messages = case dict.get(state.queues, queue) {
        Ok(msgs) -> msgs
        Error(_) -> []
      }
      let json_msg =
        messages.encode_server_message(messages.QueueState(
          queue,
          queue_messages,
        ))
      process.send(client, json_msg)
      actor.continue(State(..state, subscribers: new_subscribers))
    }

    UnsubscribeFromQueue(queue, client) -> {
      let new_subscribers = case dict.get(state.subscribers, queue) {
        Ok(subs) ->
          dict.insert(
            state.subscribers,
            queue,
            list.filter(subs, fn(s) { s != client }),
          )
        Error(_) -> state.subscribers
      }
      actor.continue(State(..state, subscribers: new_subscribers))
    }

    PublishMessage(queue, message) -> {
      let is_new = !dict.has_key(state.queues, queue)
      let current_msgs = case dict.get(state.queues, queue) {
        Ok(msgs) -> msgs
        Error(_) -> []
      }
      let new_queues =
        dict.insert(state.queues, queue, list.append(current_msgs, [message]))

      case is_new {
        True -> {
          let new_queue_msg =
            messages.encode_server_message(messages.NewQueue(queue))
          list.each(state.connected_clients, fn(client) {
            process.send(client, new_queue_msg)
          })
        }
        False -> Nil
      }

      let subscriber_msg =
        messages.encode_server_message(messages.NewMessageInQueue(
          queue,
          message,
        ))
      let subs = case dict.get(state.subscribers, queue) {
        Ok(s) -> s
        Error(_) -> []
      }
      list.each(subs, fn(client) { process.send(client, subscriber_msg) })

      actor.continue(State(..state, queues: new_queues))
    }
  }
}
