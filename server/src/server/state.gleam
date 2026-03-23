import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/string
import server/cubdb_ffi.{type Db}
import server/db
import shared/classify
import shared/messages.{type FullTestRun, type TestRun}

const flush_interval_ms = 200

// Keys for persisted stats
pub type StatsKey {
  TotalKey
  ForceCounts
  DurationCounts
  NumberCounts
  ColorCounts
  LinkCounts
}

pub type State {
  State(
    self: Subject(Msg),
    connected_clients: List(Subject(String)),
    db_actor: Subject(db.Msg),
    stats_db: Db,
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
  IngestFullTestRun(run: FullTestRun)
  Flush
}

pub fn start(
  db_actor: Subject(db.Msg),
  stats_data_dir: String,
) -> Result(Subject(Msg), actor.StartError) {
  let result =
    actor.new_with_initialiser(5000, fn(subject) {
      let assert Ok(stats_db) = cubdb_ffi.start_link(stats_data_dir)

      // Load persisted counters
      let total: Int = case cubdb_ffi.get(stats_db, TotalKey) {
        Ok(n) -> n
        Error(_) -> 0
      }
      let force_counts: Dict(String, Int) =
        case cubdb_ffi.get(stats_db, ForceCounts) {
          Ok(d) -> d
          Error(_) -> dict.new()
        }
      let duration_counts: Dict(String, Int) =
        case cubdb_ffi.get(stats_db, DurationCounts) {
          Ok(d) -> d
          Error(_) -> dict.new()
        }
      let number_counts: Dict(String, Int) =
        case cubdb_ffi.get(stats_db, NumberCounts) {
          Ok(d) -> d
          Error(_) -> dict.new()
        }
      let color_counts: Dict(String, Int) =
        case cubdb_ffi.get(stats_db, ColorCounts) {
          Ok(d) -> d
          Error(_) -> dict.new()
        }
      let link_counts: Dict(String, Int) =
        case cubdb_ffi.get(stats_db, LinkCounts) {
          Ok(d) -> d
          Error(_) -> dict.new()
        }

      actor.initialised(State(
        self: subject,
        connected_clients: [],
        db_actor: db_actor,
        stats_db: stats_db,
        total: total,
        force_counts: force_counts,
        duration_counts: duration_counts,
        number_counts: number_counts,
        color_counts: color_counts,
        link_counts: link_counts,
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

fn persist_stats(state: State) -> Nil {
  cubdb_ffi.put(state.stats_db, TotalKey, state.total)
  cubdb_ffi.put(state.stats_db, ForceCounts, state.force_counts)
  cubdb_ffi.put(state.stats_db, DurationCounts, state.duration_counts)
  cubdb_ffi.put(state.stats_db, NumberCounts, state.number_counts)
  cubdb_ffi.put(state.stats_db, ColorCounts, state.color_counts)
  cubdb_ffi.put(state.stats_db, LinkCounts, state.link_counts)
}

fn ingest_run_common(
  state: State,
  force: Float,
  duration: Float,
  winning_number: Int,
  color: String,
) -> State {
  let force_label = classify.classify_force(force)
  let duration_label = classify.classify_duration(duration)
  let number_label = classify.classify_number(winning_number)
  let color_label = classify.classify_color(color)

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

  case new_state.flush_scheduled {
    True -> new_state
    False -> {
      process.send_after(state.self, flush_interval_ms, Flush)
      State(..new_state, flush_scheduled: True)
    }
  }
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

      // Register client with DB actor for all-runs updates
      process.send(state.db_actor, db.RegisterNoQuery(client))
      process.send(state.db_actor, db.GetAllRuns(client))

      actor.continue(new_state)
    }

    ClientDisconnected(client) -> {
      let connected =
        list.filter(state.connected_clients, fn(c) { c != client })
      process.send(state.db_actor, db.UnregisterClient(client))
      actor.continue(State(..state, connected_clients: connected))
    }

    IngestTestRun(run) -> {
      let new_state =
        ingest_run_common(
          state,
          run.force,
          run.duration,
          run.winning_number,
          run.color,
        )

      // Convert to FullTestRun with defaults and store in DB
      let full_run =
        messages.FullTestRun(
          force: run.force,
          duration: run.duration,
          winning_number: run.winning_number,
          color: run.color,
          start_date: "",
          end_date: "",
          status: "pass",
          logs: [],
          gherkin_text: "",
          step_metrics: [],
        )
      process.send(state.db_actor, db.StoreRun(run: full_run))

      actor.continue(new_state)
    }

    IngestFullTestRun(run) -> {
      let new_state =
        ingest_run_common(
          state,
          run.force,
          run.duration,
          run.winning_number,
          run.color,
        )

      process.send(state.db_actor, db.StoreRun(run: run))

      actor.continue(new_state)
    }

    Flush -> {
      case state.dirty {
        True -> {
          broadcast_stats(state)
          persist_stats(state)
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
