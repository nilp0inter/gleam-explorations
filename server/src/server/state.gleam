import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/string
import shared/classify
import shared/messages.{type TestRun}

const flush_interval_ms = 200

pub type State {
  State(
    self: Subject(Msg),
    connected_clients: List(Subject(String)),
    total: Int,
    force_counts: Dict(String, Int),
    duration_counts: Dict(String, Int),
    number_counts: Dict(String, Int),
    color_counts: Dict(String, Int),
    link_counts: Dict(String, Int),
    dirty: Bool,
    flush_scheduled: Bool,
  )
}

pub type Msg {
  ClientConnected(client: Subject(String))
  ClientDisconnected(client: Subject(String))
  IngestTestRun(run: TestRun)
  Flush
}

pub fn start() -> Result(Subject(Msg), actor.StartError) {
  let result =
    actor.new_with_initialiser(5000, fn(subject) {
      actor.initialised(State(
        self: subject,
        connected_clients: [],
        total: 0,
        force_counts: dict.new(),
        duration_counts: dict.new(),
        number_counts: dict.new(),
        color_counts: dict.new(),
        link_counts: dict.new(),
        dirty: False,
        flush_scheduled: False,
      ))
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle_message)
    |> actor.start()

  case result {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

fn increment(d: Dict(String, Int), key: String) -> Dict(String, Int) {
  let current = case dict.get(d, key) {
    Ok(v) -> v
    Error(_) -> 0
  }
  dict.insert(d, key, current + 1)
}

fn dict_to_bucket_counts(
  d: Dict(String, Int),
) -> List(messages.BucketCount) {
  dict.to_list(d)
  |> list.map(fn(pair) { messages.BucketCount(name: pair.0, count: pair.1) })
}

fn dict_to_sankey_links(
  d: Dict(String, Int),
) -> List(messages.SankeyLink) {
  dict.to_list(d)
  |> list.filter_map(fn(pair) {
    case string.split(pair.0, "||") {
      [source, target] ->
        Ok(messages.SankeyLink(source:, target:, value: pair.1))
      _ -> Error(Nil)
    }
  })
}

fn build_stats(state: State) -> messages.Stats {
  messages.Stats(
    total: state.total,
    force_counts: dict_to_bucket_counts(state.force_counts),
    duration_counts: dict_to_bucket_counts(state.duration_counts),
    number_counts: dict_to_bucket_counts(state.number_counts),
    color_counts: dict_to_bucket_counts(state.color_counts),
    links: dict_to_sankey_links(state.link_counts),
  )
}

fn broadcast_stats(state: State) -> Nil {
  let stats = build_stats(state)
  let json =
    messages.encode_server_message(messages.StatsSnapshot(stats))
  list.each(state.connected_clients, fn(client) {
    process.send(client, json)
  })
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    ClientConnected(client) -> {
      let new_state =
        State(..state, connected_clients: [client, ..state.connected_clients])
      let stats = build_stats(new_state)
      let json =
        messages.encode_server_message(messages.StatsSnapshot(stats))
      process.send(client, json)
      actor.continue(new_state)
    }

    ClientDisconnected(client) -> {
      let connected =
        list.filter(state.connected_clients, fn(c) { c != client })
      actor.continue(State(..state, connected_clients: connected))
    }

    IngestTestRun(run) -> {
      let force_label = classify.classify_force(run.force)
      let duration_label = classify.classify_duration(run.duration)
      let number_label = classify.classify_number(run.winning_number)
      let color_label = classify.classify_color(run.color)

      let new_state =
        State(
          ..state,
          total: state.total + 1,
          force_counts: increment(state.force_counts, force_label),
          duration_counts: increment(state.duration_counts, duration_label),
          number_counts: increment(state.number_counts, number_label),
          color_counts: increment(state.color_counts, color_label),
          link_counts: state.link_counts
            |> increment(force_label <> "||" <> duration_label)
            |> increment(duration_label <> "||" <> number_label)
            |> increment(number_label <> "||" <> color_label),
          dirty: True,
        )

      let new_state = case new_state.flush_scheduled {
        True -> new_state
        False -> {
          process.send_after(state.self, flush_interval_ms, Flush)
          State(..new_state, flush_scheduled: True)
        }
      }

      actor.continue(new_state)
    }

    Flush -> {
      case state.dirty {
        True -> {
          broadcast_stats(state)
          actor.continue(
            State(..state, dirty: False, flush_scheduled: False),
          )
        }
        False ->
          actor.continue(State(..state, flush_scheduled: False))
      }
    }
  }
}
