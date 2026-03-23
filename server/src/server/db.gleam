import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import server/cubdb_ffi.{type Db}
import shared/classify
import shared/messages.{type FullTestRun, type StepMetric}

// === Stored run record (Erlang term in CubDB) ===

pub type StoredRun {
  StoredRun(
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
pub type RunKey {
  RunKey(id: Int)
}

pub type MetaKey {
  MetaKey
}

pub type IndexKey {
  IndexKey(dimension: String, label: String, id: Int)
}

// === Actor types ===

pub type State {
  State(
    db: Db,
    next_id: Int,
    active_queries: Dict(Subject(String), List(String)),
    no_query_clients: List(Subject(String)),
  )
}

pub type Msg {
  StoreRun(run: FullTestRun)
  RegisterQuery(client: Subject(String), nodes: List(String))
  UnregisterQuery(client: Subject(String))
  RegisterNoQuery(client: Subject(String))
  UnregisterClient(client: Subject(String))
  GetAllRuns(client: Subject(String))
  GetRunDetail(id: Int, client: Subject(String))
}

pub fn start(data_dir: String) -> Result(Subject(Msg), actor.StartError) {
  let result =
    actor.new_with_initialiser(5000, fn(subject) {
      let assert Ok(db) = cubdb_ffi.start_link(data_dir)

      // Load next_id from CubDB or start at 1
      let next_id: Int = case cubdb_ffi.get(db, MetaKey) {
        Ok(n) -> n
        Error(_) -> 1
      }

      actor.initialised(State(
        db: db,
        next_id: next_id,
        active_queries: dict.new(),
        no_query_clients: [],
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

fn handle_message(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    StoreRun(run) -> {
      let id = state.next_id
      let force_label = classify.classify_force(run.force)
      let duration_label = classify.classify_duration(run.duration)
      let number_label = classify.classify_number(run.winning_number)
      let color_label = classify.classify_color(run.color)

      let stored =
        StoredRun(
          id: id,
          force: run.force,
          duration: run.duration,
          winning_number: run.winning_number,
          color: run.color,
          start_date: run.start_date,
          end_date: run.end_date,
          status: run.status,
          logs: run.logs,
          gherkin_text: run.gherkin_text,
          step_metrics: run.step_metrics,
          force_label: force_label,
          duration_label: duration_label,
          number_label: number_label,
          color_label: color_label,
        )

      // Store the run
      cubdb_ffi.put(state.db, RunKey(id), stored)

      // Update next_id
      cubdb_ffi.put(state.db, MetaKey, id + 1)

      // Store index entries
      cubdb_ffi.put(
        state.db,
        IndexKey("force", force_label, id),
        True,
      )
      cubdb_ffi.put(
        state.db,
        IndexKey("duration", duration_label, id),
        True,
      )
      cubdb_ffi.put(
        state.db,
        IndexKey("number", number_label, id),
        True,
      )
      cubdb_ffi.put(
        state.db,
        IndexKey("color", color_label, id),
        True,
      )

      let summary =
        messages.RunSummary(
          id: id,
          start_date: run.start_date,
          end_date: run.end_date,
          status: run.status,
        )

      let labels = [force_label, duration_label, number_label, color_label]

      // Push to clients with active queries if run matches
      let _ = dict.each(state.active_queries, fn(client, nodes) {
        case run_matches_selection(labels, nodes) {
          True -> {
            let json =
              messages.encode_server_message(
                messages.MatchingRunAppend(summary),
              )
            process.send(client, json)
          }
          False -> Nil
        }
      })

      // Push to clients with no query (they see all runs)
      list.each(state.no_query_clients, fn(client) {
        let json =
          messages.encode_server_message(messages.NewRun(summary))
        process.send(client, json)
      })

      actor.continue(State(..state, next_id: id + 1))
    }

    RegisterQuery(client, nodes) -> {
      // Remove from no-query list if present
      let no_query =
        list.filter(state.no_query_clients, fn(c) { c != client })
      let new_queries =
        dict.insert(state.active_queries, client, nodes)
      let new_state =
        State(
          ..state,
          active_queries: new_queries,
          no_query_clients: no_query,
        )

      // Send initial matching results
      let matching = query_matching_runs(state.db, nodes)
      let json =
        messages.encode_server_message(messages.MatchingRuns(matching))
      process.send(client, json)

      actor.continue(new_state)
    }

    UnregisterQuery(client) -> {
      let new_queries = dict.delete(state.active_queries, client)
      // Move back to no-query list
      let no_query = [client, ..state.no_query_clients]
      let new_state =
        State(
          ..state,
          active_queries: new_queries,
          no_query_clients: no_query,
        )

      // Send all runs
      let all = get_all_run_summaries(state.db)
      let json =
        messages.encode_server_message(messages.AllRuns(all))
      process.send(client, json)

      actor.continue(new_state)
    }

    RegisterNoQuery(client) -> {
      let no_query = [client, ..state.no_query_clients]
      actor.continue(State(..state, no_query_clients: no_query))
    }

    UnregisterClient(client) -> {
      let new_queries = dict.delete(state.active_queries, client)
      let no_query =
        list.filter(state.no_query_clients, fn(c) { c != client })
      actor.continue(
        State(
          ..state,
          active_queries: new_queries,
          no_query_clients: no_query,
        ),
      )
    }

    GetAllRuns(client) -> {
      let all = get_all_run_summaries(state.db)
      let json =
        messages.encode_server_message(messages.AllRuns(all))
      process.send(client, json)
      actor.continue(state)
    }

    GetRunDetail(id, client) -> {
      case get_stored_run(state.db, id) {
        Ok(stored) -> {
          let detail =
            messages.RunDetail(
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
              messages.RunDetailResponse(detail),
            )
          process.send(client, json)
        }
        Error(_) -> Nil
      }
      actor.continue(state)
    }
  }
}

// Check if a run's labels match all selected nodes
fn run_matches_selection(
  labels: List(String),
  selected_nodes: List(String),
) -> Bool {
  list.all(selected_nodes, fn(node) { list.contains(labels, node) })
}

// Query for all runs matching the selected nodes
fn query_matching_runs(
  db: Db,
  nodes: List(String),
) -> List(messages.RunSummary) {
  get_all_stored_runs(db)
  |> list.filter(fn(stored) {
    let labels = [
      stored.force_label,
      stored.duration_label,
      stored.number_label,
      stored.color_label,
    ]
    run_matches_selection(labels, nodes)
  })
  |> list.map(fn(stored) {
    messages.RunSummary(
      id: stored.id,
      start_date: stored.start_date,
      end_date: stored.end_date,
      status: stored.status,
    )
  })
  |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
}

fn get_all_run_summaries(db: Db) -> List(messages.RunSummary) {
  get_all_stored_runs(db)
  |> list.map(fn(stored) {
    messages.RunSummary(
      id: stored.id,
      start_date: stored.start_date,
      end_date: stored.end_date,
      status: stored.status,
    )
  })
  |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
}

fn get_all_stored_runs(db: Db) -> List(StoredRun) {
  let all_entries: List(#(RunKey, StoredRun)) = cubdb_ffi.select_runs(db)
  list.map(all_entries, fn(entry) { entry.1 })
}

fn get_stored_run(db: Db, id: Int) -> Result(StoredRun, Nil) {
  cubdb_ffi.get(db, RunKey(id))
}
