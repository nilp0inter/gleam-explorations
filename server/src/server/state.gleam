import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/set.{type Set}
import gleam/string
import server/cubdb_ffi.{type Db}
import server/db
import shared/classify
import shared/messages.{type FullSample, type Sample}

const flush_interval_ms = 200

// Keys for persisted stats (per run_id)
pub type StatsKey {
  TotalKey(run_id: String)
  ForceCounts(run_id: String)
  DurationCounts(run_id: String)
  NumberCounts(run_id: String)
  ColorCounts(run_id: String)
  LinkCounts(run_id: String)
  StatsRunIdsKey
}

pub type RunStats {
  RunStats(
    total: Int,
    force_counts: Dict(String, Int),
    duration_counts: Dict(String, Int),
    number_counts: Dict(String, Int),
    color_counts: Dict(String, Int),
    link_counts: Dict(String, Int),
  )
}

pub type State {
  State(
    self: Subject(Msg),
    connected_clients: List(Subject(String)),
    db_actor: Subject(db.Msg),
    stats_db: Db,
    run_stats: Dict(String, RunStats),
    dirty_runs: Set(String),
    flush_scheduled: Bool,
    client_run_selection: Dict(Subject(String), String),
  )
}

pub type Msg {
  ClientConnected(client: Subject(String))
  ClientDisconnected(client: Subject(String))
  IngestSample(run_id: String, sample: Sample)
  IngestFullSample(run_id: String, sample: FullSample)
  ClientSelectRun(client: Subject(String), run_id: String)
  Flush
}

fn empty_run_stats() -> RunStats {
  RunStats(
    total: 0,
    force_counts: dict.new(),
    duration_counts: dict.new(),
    number_counts: dict.new(),
    color_counts: dict.new(),
    link_counts: dict.new(),
  )
}

pub fn start(
  db_actor: Subject(db.Msg),
  stats_data_dir: String,
) -> Result(Subject(Msg), actor.StartError) {
  let result =
    actor.new_with_initialiser(5000, fn(subject) {
      let assert Ok(stats_db) = cubdb_ffi.start_link(stats_data_dir)

      let run_ids: List(String) =
        case cubdb_ffi.get(stats_db, StatsRunIdsKey) {
          Ok(ids) -> ids
          Error(_) -> []
        }

      let run_stats =
        list.fold(run_ids, dict.new(), fn(acc, run_id) {
          let total: Int = case cubdb_ffi.get(stats_db, TotalKey(run_id)) {
            Ok(n) -> n
            Error(_) -> 0
          }
          let force_counts: Dict(String, Int) =
            case cubdb_ffi.get(stats_db, ForceCounts(run_id)) {
              Ok(d) -> d
              Error(_) -> dict.new()
            }
          let duration_counts: Dict(String, Int) =
            case cubdb_ffi.get(stats_db, DurationCounts(run_id)) {
              Ok(d) -> d
              Error(_) -> dict.new()
            }
          let number_counts: Dict(String, Int) =
            case cubdb_ffi.get(stats_db, NumberCounts(run_id)) {
              Ok(d) -> d
              Error(_) -> dict.new()
            }
          let color_counts: Dict(String, Int) =
            case cubdb_ffi.get(stats_db, ColorCounts(run_id)) {
              Ok(d) -> d
              Error(_) -> dict.new()
            }
          let link_counts: Dict(String, Int) =
            case cubdb_ffi.get(stats_db, LinkCounts(run_id)) {
              Ok(d) -> d
              Error(_) -> dict.new()
            }
          dict.insert(
            acc,
            run_id,
            RunStats(
              total:,
              force_counts:,
              duration_counts:,
              number_counts:,
              color_counts:,
              link_counts:,
            ),
          )
        })

      actor.initialised(State(
        self: subject,
        connected_clients: [],
        db_actor: db_actor,
        stats_db: stats_db,
        run_stats: run_stats,
        dirty_runs: set.new(),
        flush_scheduled: False,
        client_run_selection: dict.new(),
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

fn build_stats_from_run_stats(rs: RunStats) -> messages.Stats {
  messages.Stats(
    total: rs.total,
    force_counts: dict_to_bucket_counts(rs.force_counts),
    duration_counts: dict_to_bucket_counts(rs.duration_counts),
    number_counts: dict_to_bucket_counts(rs.number_counts),
    color_counts: dict_to_bucket_counts(rs.color_counts),
    links: dict_to_sankey_links(rs.link_counts),
  )
}

fn empty_stats() -> messages.Stats {
  messages.Stats(
    total: 0,
    force_counts: [],
    duration_counts: [],
    number_counts: [],
    color_counts: [],
    links: [],
  )
}

fn broadcast_stats_for_run(state: State, run_id: String) -> Nil {
  let stats = case dict.get(state.run_stats, run_id) {
    Ok(rs) -> build_stats_from_run_stats(rs)
    Error(_) -> empty_stats()
  }
  let json =
    messages.encode_server_message(messages.StatsSnapshot(stats))
  let _ =
    dict.each(state.client_run_selection, fn(client, crid) {
      case crid == run_id {
        True -> process.send(client, json)
        False -> Nil
      }
    })
  Nil
}

fn persist_stats_for_run(state: State, run_id: String) -> Nil {
  case dict.get(state.run_stats, run_id) {
    Ok(rs) -> {
      cubdb_ffi.put(state.stats_db, TotalKey(run_id), rs.total)
      cubdb_ffi.put(state.stats_db, ForceCounts(run_id), rs.force_counts)
      cubdb_ffi.put(
        state.stats_db,
        DurationCounts(run_id),
        rs.duration_counts,
      )
      cubdb_ffi.put(state.stats_db, NumberCounts(run_id), rs.number_counts)
      cubdb_ffi.put(state.stats_db, ColorCounts(run_id), rs.color_counts)
      cubdb_ffi.put(state.stats_db, LinkCounts(run_id), rs.link_counts)
    }
    Error(_) -> Nil
  }
}

fn save_run_ids(state: State) -> Nil {
  let run_ids = dict.keys(state.run_stats)
  cubdb_ffi.put(state.stats_db, StatsRunIdsKey, run_ids)
}

fn ingest_sample_common(
  state: State,
  run_id: String,
  force: Float,
  duration: Float,
  winning_number: Int,
  color: String,
) -> State {
  let force_label = classify.classify_force(force)
  let duration_label = classify.classify_duration(duration)
  let number_label = classify.classify_number(winning_number)
  let color_label = classify.classify_color(color)

  let rs = case dict.get(state.run_stats, run_id) {
    Ok(existing) -> existing
    Error(_) -> empty_run_stats()
  }

  let new_rs =
    RunStats(
      total: rs.total + 1,
      force_counts: increment(rs.force_counts, force_label),
      duration_counts: increment(rs.duration_counts, duration_label),
      number_counts: increment(rs.number_counts, number_label),
      color_counts: increment(rs.color_counts, color_label),
      link_counts: rs.link_counts
        |> increment(force_label <> "||" <> duration_label)
        |> increment(duration_label <> "||" <> number_label)
        |> increment(number_label <> "||" <> color_label),
    )

  let new_run_stats = dict.insert(state.run_stats, run_id, new_rs)
  let new_dirty = set.insert(state.dirty_runs, run_id)

  let new_state =
    State(..state, run_stats: new_run_stats, dirty_runs: new_dirty)

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

      process.send(state.db_actor, db.RegisterNoQuery(client, ""))
      process.send(state.db_actor, db.GetRunList(client))

      actor.continue(new_state)
    }

    ClientDisconnected(client) -> {
      let connected =
        list.filter(state.connected_clients, fn(c) { c != client })
      let client_selection = dict.delete(state.client_run_selection, client)
      process.send(state.db_actor, db.UnregisterClient(client))
      actor.continue(
        State(
          ..state,
          connected_clients: connected,
          client_run_selection: client_selection,
        ),
      )
    }

    IngestSample(run_id, sample) -> {
      let new_state =
        ingest_sample_common(
          state,
          run_id,
          sample.force,
          sample.duration,
          sample.winning_number,
          sample.color,
        )

      let full_sample =
        messages.FullSample(
          force: sample.force,
          duration: sample.duration,
          winning_number: sample.winning_number,
          color: sample.color,
          start_date: "",
          end_date: "",
          status: "pass",
          logs: [],
          gherkin_text: "",
          step_metrics: [],
        )
      process.send(
        state.db_actor,
        db.StoreSample(run_id:, sample: full_sample),
      )

      actor.continue(new_state)
    }

    IngestFullSample(run_id, sample) -> {
      let new_state =
        ingest_sample_common(
          state,
          run_id,
          sample.force,
          sample.duration,
          sample.winning_number,
          sample.color,
        )

      process.send(
        state.db_actor,
        db.StoreSample(run_id:, sample: sample),
      )

      actor.continue(new_state)
    }

    ClientSelectRun(client, run_id) -> {
      let new_selection =
        dict.insert(state.client_run_selection, client, run_id)
      let new_state = State(..state, client_run_selection: new_selection)

      let stats = case dict.get(state.run_stats, run_id) {
        Ok(rs) -> build_stats_from_run_stats(rs)
        Error(_) -> empty_stats()
      }
      let json =
        messages.encode_server_message(messages.StatsSnapshot(stats))
      process.send(client, json)

      actor.continue(new_state)
    }

    Flush -> {
      case set.is_empty(state.dirty_runs) {
        True ->
          actor.continue(State(..state, flush_scheduled: False))
        False -> {
          let _ = set.each(state.dirty_runs, fn(run_id) {
            broadcast_stats_for_run(state, run_id)
            persist_stats_for_run(state, run_id)
          })
          save_run_ids(state)
          actor.continue(
            State(
              ..state,
              dirty_runs: set.new(),
              flush_scheduled: False,
            ),
          )
        }
      }
    }
  }
}
