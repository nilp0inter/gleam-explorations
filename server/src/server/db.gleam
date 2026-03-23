import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import server/cubdb_ffi.{type Db}
import shared/classify
import shared/messages.{type FullSample, type RunInfo, type StepMetric}

// === Stored sample record (Erlang term in CubDB) ===

pub type StoredSample {
  StoredSample(
    id: Int,
    force: Float,
    duration: Float,
    winning_number: Int,
    color: String,
    start_date: String,
    end_date: String,
    status: String,
    logs: List(String),
    gherkin_text: String,
    step_metrics: List(StepMetric),
    force_label: String,
    duration_label: String,
    number_label: String,
    color_label: String,
  )
}

// CubDB key types
pub type SampleKey {
  SampleKey(run_id: String, id: Int)
}

pub type MetaKey {
  MetaKey(run_id: String)
}

pub type IndexKey {
  IndexKey(run_id: String, dimension: String, label: String, id: Int)
}

pub type RunInfoKey {
  RunInfoKey(run_id: String)
}

// === Actor types ===

pub type State {
  State(
    db: Db,
    next_ids: Dict(String, Int),
    active_queries: Dict(Subject(String), #(String, List(String))),
    no_query_clients: Dict(Subject(String), String),
    all_clients: List(Subject(String)),
  )
}

pub type Msg {
  StoreSample(run_id: String, sample: FullSample)
  RegisterQuery(client: Subject(String), run_id: String, nodes: List(String))
  UnregisterQuery(client: Subject(String))
  RegisterNoQuery(client: Subject(String), run_id: String)
  UnregisterClient(client: Subject(String))
  GetAllSamples(client: Subject(String), run_id: String)
  GetSampleDetail(run_id: String, id: Int, client: Subject(String))
  GetRunList(client: Subject(String))
  ClientSelectRun(client: Subject(String), run_id: String)
}

pub fn start(data_dir: String) -> Result(Subject(Msg), actor.StartError) {
  let result =
    actor.new_with_initialiser(5000, fn(subject) {
      let assert Ok(db) = cubdb_ffi.start_link(data_dir)

      let run_infos: List(#(RunInfoKey, RunInfo)) =
        cubdb_ffi.select_run_infos(db)
      let next_ids =
        list.fold(run_infos, dict.new(), fn(acc, entry) {
          let run_id = entry.0.run_id
          let next: Int = case cubdb_ffi.get(db, MetaKey(run_id)) {
            Ok(n) -> n
            Error(_) -> 1
          }
          dict.insert(acc, run_id, next)
        })

      actor.initialised(State(
        db: db,
        next_ids: next_ids,
        active_queries: dict.new(),
        no_query_clients: dict.new(),
        all_clients: [],
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

fn get_next_id(state: State, run_id: String) -> Int {
  case dict.get(state.next_ids, run_id) {
    Ok(n) -> n
    Error(_) -> 1
  }
}

fn get_created_at(db: Db, run_id: String) -> String {
  let result: Result(RunInfo, Nil) = cubdb_ffi.get(db, RunInfoKey(run_id))
  case result {
    Ok(info) -> info.created_at
    Error(_) -> ""
  }
}

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    StoreSample(run_id, sample) -> {
      let id = get_next_id(state, run_id)
      let force_label = classify.classify_force(sample.force)
      let duration_label = classify.classify_duration(sample.duration)
      let number_label = classify.classify_number(sample.winning_number)
      let color_label = classify.classify_color(sample.color)

      let stored =
        StoredSample(
          id: id,
          force: sample.force,
          duration: sample.duration,
          winning_number: sample.winning_number,
          color: sample.color,
          start_date: sample.start_date,
          end_date: sample.end_date,
          status: sample.status,
          logs: sample.logs,
          gherkin_text: sample.gherkin_text,
          step_metrics: sample.step_metrics,
          force_label: force_label,
          duration_label: duration_label,
          number_label: number_label,
          color_label: color_label,
        )

      cubdb_ffi.put(state.db, SampleKey(run_id, id), stored)
      cubdb_ffi.put(state.db, MetaKey(run_id), id + 1)

      cubdb_ffi.put(
        state.db,
        IndexKey(run_id, "force", force_label, id),
        True,
      )
      cubdb_ffi.put(
        state.db,
        IndexKey(run_id, "duration", duration_label, id),
        True,
      )
      cubdb_ffi.put(
        state.db,
        IndexKey(run_id, "number", number_label, id),
        True,
      )
      cubdb_ffi.put(
        state.db,
        IndexKey(run_id, "color", color_label, id),
        True,
      )

      // Check if this is a new run_id (first time seeing it)
      let is_new = case dict.get(state.next_ids, run_id) {
        Ok(_) -> False
        Error(_) -> True
      }

      let new_next_ids = dict.insert(state.next_ids, run_id, id + 1)

      case is_new {
        True -> {
          let info =
            messages.RunInfo(
              run_id: run_id,
              created_at: sample.start_date,
              sample_count: 1,
            )
          cubdb_ffi.put(state.db, RunInfoKey(run_id), info)
          let json =
            messages.encode_server_message(messages.RunCreated(info))
          list.each(state.all_clients, fn(client) {
            process.send(client, json)
          })
        }
        False -> {
          let created_at = get_created_at(state.db, run_id)
          let info =
            messages.RunInfo(
              run_id: run_id,
              created_at: created_at,
              sample_count: id,
            )
          cubdb_ffi.put(state.db, RunInfoKey(run_id), info)
        }
      }

      let summary =
        messages.SampleSummary(
          id: id,
          start_date: sample.start_date,
          end_date: sample.end_date,
          status: sample.status,
        )

      let labels = [force_label, duration_label, number_label, color_label]

      let _ =
        dict.each(state.active_queries, fn(client, query) {
          let #(client_run_id, nodes) = query
          case client_run_id == run_id {
            True ->
              case sample_matches_selection(labels, nodes) {
                True -> {
                  let json =
                    messages.encode_server_message(
                      messages.MatchingSampleAppend(summary),
                    )
                  process.send(client, json)
                }
                False -> Nil
              }
            False -> Nil
          }
        })

      let _ =
        dict.each(state.no_query_clients, fn(client, client_run_id) {
          case client_run_id == run_id {
            True -> {
              let json =
                messages.encode_server_message(messages.NewSample(summary))
              process.send(client, json)
            }
            False -> Nil
          }
        })

      actor.continue(State(..state, next_ids: new_next_ids))
    }

    RegisterQuery(client, run_id, nodes) -> {
      let no_query = dict.delete(state.no_query_clients, client)
      let new_queries =
        dict.insert(state.active_queries, client, #(run_id, nodes))
      let new_state =
        State(
          ..state,
          active_queries: new_queries,
          no_query_clients: no_query,
        )

      let matching = query_matching_samples(state.db, run_id, nodes)
      let json =
        messages.encode_server_message(messages.MatchingSamples(matching))
      process.send(client, json)

      actor.continue(new_state)
    }

    UnregisterQuery(client) -> {
      let run_id = case dict.get(state.active_queries, client) {
        Ok(#(rid, _)) -> rid
        Error(_) -> ""
      }
      let new_queries = dict.delete(state.active_queries, client)
      let no_query = dict.insert(state.no_query_clients, client, run_id)
      let new_state =
        State(
          ..state,
          active_queries: new_queries,
          no_query_clients: no_query,
        )

      let all = get_all_sample_summaries(state.db, run_id)
      let json =
        messages.encode_server_message(messages.AllSamples(all))
      process.send(client, json)

      actor.continue(new_state)
    }

    RegisterNoQuery(client, run_id) -> {
      let no_query = dict.insert(state.no_query_clients, client, run_id)
      let all_clients = [client, ..state.all_clients]
      actor.continue(
        State(..state, no_query_clients: no_query, all_clients: all_clients),
      )
    }

    UnregisterClient(client) -> {
      let new_queries = dict.delete(state.active_queries, client)
      let no_query = dict.delete(state.no_query_clients, client)
      let all_clients =
        list.filter(state.all_clients, fn(c) { c != client })
      actor.continue(
        State(
          ..state,
          active_queries: new_queries,
          no_query_clients: no_query,
          all_clients: all_clients,
        ),
      )
    }

    GetAllSamples(client, run_id) -> {
      let all = get_all_sample_summaries(state.db, run_id)
      let json =
        messages.encode_server_message(messages.AllSamples(all))
      process.send(client, json)
      actor.continue(state)
    }

    GetSampleDetail(run_id, id, client) -> {
      case get_stored_sample(state.db, run_id, id) {
        Ok(stored) -> {
          let detail =
            messages.SampleDetail(
              id: stored.id,
              force: stored.force,
              duration: stored.duration,
              winning_number: stored.winning_number,
              color: stored.color,
              start_date: stored.start_date,
              end_date: stored.end_date,
              status: stored.status,
              logs: stored.logs,
              gherkin_text: stored.gherkin_text,
              step_metrics: stored.step_metrics,
              force_label: stored.force_label,
              duration_label: stored.duration_label,
              number_label: stored.number_label,
              color_label: stored.color_label,
            )
          let json =
            messages.encode_server_message(
              messages.SampleDetailResponse(detail),
            )
          process.send(client, json)
        }
        Error(_) -> Nil
      }
      actor.continue(state)
    }

    GetRunList(client) -> {
      let infos: List(#(RunInfoKey, RunInfo)) =
        cubdb_ffi.select_run_infos(state.db)
      let runs = list.map(infos, fn(entry) { entry.1 })
      let json =
        messages.encode_server_message(messages.RunList(runs))
      process.send(client, json)
      actor.continue(state)
    }

    ClientSelectRun(client, run_id) -> {
      let new_queries = dict.delete(state.active_queries, client)
      let no_query = dict.insert(state.no_query_clients, client, run_id)
      let new_state =
        State(
          ..state,
          active_queries: new_queries,
          no_query_clients: no_query,
        )

      let all = get_all_sample_summaries(state.db, run_id)
      let json =
        messages.encode_server_message(messages.AllSamples(all))
      process.send(client, json)

      actor.continue(new_state)
    }
  }
}

fn sample_matches_selection(
  labels: List(String),
  selected_nodes: List(String),
) -> Bool {
  list.all(selected_nodes, fn(node) { list.contains(labels, node) })
}

fn query_matching_samples(
  db: Db,
  run_id: String,
  nodes: List(String),
) -> List(messages.SampleSummary) {
  get_all_stored_samples(db, run_id)
  |> list.filter(fn(stored) {
    let labels = [
      stored.force_label,
      stored.duration_label,
      stored.number_label,
      stored.color_label,
    ]
    sample_matches_selection(labels, nodes)
  })
  |> list.map(fn(stored) {
    messages.SampleSummary(
      id: stored.id,
      start_date: stored.start_date,
      end_date: stored.end_date,
      status: stored.status,
    )
  })
  |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
}

fn get_all_sample_summaries(
  db: Db,
  run_id: String,
) -> List(messages.SampleSummary) {
  get_all_stored_samples(db, run_id)
  |> list.map(fn(stored) {
    messages.SampleSummary(
      id: stored.id,
      start_date: stored.start_date,
      end_date: stored.end_date,
      status: stored.status,
    )
  })
  |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
}

fn get_all_stored_samples(db: Db, run_id: String) -> List(StoredSample) {
  let all_entries: List(#(SampleKey, StoredSample)) =
    cubdb_ffi.select_runs_for(db, run_id)
  list.map(all_entries, fn(entry) { entry.1 })
}

fn get_stored_sample(
  db: Db,
  run_id: String,
  id: Int,
) -> Result(StoredSample, Nil) {
  cubdb_ffi.get(db, SampleKey(run_id, id))
}
