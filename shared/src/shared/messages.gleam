import gleam/dynamic/decode
import gleam/json

// === Types ===

pub type TestRun {
  TestRun(force: Float, duration: Float, winning_number: Int, color: String)
}

pub type FullTestRun {
  FullTestRun(
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
  )
}

pub type StepMetric {
  StepMetric(name: String, duration_ms: Float, status: String)
}

pub type BucketCount {
  BucketCount(name: String, count: Int)
}

pub type SankeyLink {
  SankeyLink(source: String, target: String, value: Int)
}

pub type Stats {
  Stats(
    total: Int,
    force_counts: List(BucketCount),
    duration_counts: List(BucketCount),
    number_counts: List(BucketCount),
    color_counts: List(BucketCount),
    links: List(SankeyLink),
  )
}

pub type RunSummary {
  RunSummary(id: Int, start_date: String, end_date: String, status: String)
}

pub type RunDetail {
  RunDetail(
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

// === Server -> Client Messages ===

pub type ServerMessage {
  StatsSnapshot(stats: Stats)
  MatchingRuns(runs: List(RunSummary))
  MatchingRunAppend(run: RunSummary)
  AllRuns(runs: List(RunSummary))
  NewRun(run: RunSummary)
  RunDetailResponse(detail: RunDetail)
}

// === Client -> Server Messages ===

pub type ClientMessage {
  SubmitTestRun(run: TestRun)
  SubmitFullTestRun(run: FullTestRun)
  SetSelection(selected_nodes: List(String))
  ClearSelectionQuery
  RequestRunDetail(id: Int)
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

fn encode_full_test_run_fields(
  run: FullTestRun,
) -> List(#(String, json.Json)) {
  [
    #("force", json.float(run.force)),
    #("duration", json.float(run.duration)),
    #("winning_number", json.int(run.winning_number)),
    #("color", json.string(run.color)),
    #("start_date", json.string(run.start_date)),
    #("end_date", json.string(run.end_date)),
    #("status", json.string(run.status)),
    #("logs", json.array(run.logs, json.string)),
    #("gherkin_text", json.string(run.gherkin_text)),
    #(
      "step_metrics",
      json.array(run.step_metrics, encode_step_metric),
    ),
  ]
}

fn encode_step_metric(sm: StepMetric) -> json.Json {
  json.object([
    #("name", json.string(sm.name)),
    #("duration_ms", json.float(sm.duration_ms)),
    #("status", json.string(sm.status)),
  ])
}

fn encode_bucket_count(bc: BucketCount) -> json.Json {
  json.object([
    #("name", json.string(bc.name)),
    #("count", json.int(bc.count)),
  ])
}

fn encode_sankey_link(link: SankeyLink) -> json.Json {
  json.object([
    #("source", json.string(link.source)),
    #("target", json.string(link.target)),
    #("value", json.int(link.value)),
  ])
}

fn encode_stats(stats: Stats) -> List(#(String, json.Json)) {
  [
    #("total", json.int(stats.total)),
    #("force_counts", json.array(stats.force_counts, encode_bucket_count)),
    #(
      "duration_counts",
      json.array(stats.duration_counts, encode_bucket_count),
    ),
    #("number_counts", json.array(stats.number_counts, encode_bucket_count)),
    #("color_counts", json.array(stats.color_counts, encode_bucket_count)),
    #("links", json.array(stats.links, encode_sankey_link)),
  ]
}

fn encode_run_summary(rs: RunSummary) -> json.Json {
  json.object([
    #("id", json.int(rs.id)),
    #("start_date", json.string(rs.start_date)),
    #("end_date", json.string(rs.end_date)),
    #("status", json.string(rs.status)),
  ])
}

fn encode_run_detail_fields(d: RunDetail) -> List(#(String, json.Json)) {
  [
    #("id", json.int(d.id)),
    #("force", json.float(d.force)),
    #("duration", json.float(d.duration)),
    #("winning_number", json.int(d.winning_number)),
    #("color", json.string(d.color)),
    #("start_date", json.string(d.start_date)),
    #("end_date", json.string(d.end_date)),
    #("status", json.string(d.status)),
    #("logs", json.array(d.logs, json.string)),
    #("gherkin_text", json.string(d.gherkin_text)),
    #("step_metrics", json.array(d.step_metrics, encode_step_metric)),
    #("force_label", json.string(d.force_label)),
    #("duration_label", json.string(d.duration_label)),
    #("number_label", json.string(d.number_label)),
    #("color_label", json.string(d.color_label)),
  ]
}

pub fn encode_server_message(msg: ServerMessage) -> String {
  case msg {
    StatsSnapshot(stats) ->
      json.object([
        #("type", json.string("stats_snapshot")),
        ..encode_stats(stats)
      ])
    MatchingRuns(runs) ->
      json.object([
        #("type", json.string("matching_runs")),
        #("runs", json.array(runs, encode_run_summary)),
      ])
    MatchingRunAppend(run) ->
      json.object([
        #("type", json.string("matching_run_append")),
        ..encode_run_summary_fields(run)
      ])
    AllRuns(runs) ->
      json.object([
        #("type", json.string("all_runs")),
        #("runs", json.array(runs, encode_run_summary)),
      ])
    NewRun(run) ->
      json.object([
        #("type", json.string("new_run")),
        ..encode_run_summary_fields(run)
      ])
    RunDetailResponse(detail) ->
      json.object([
        #("type", json.string("run_detail")),
        ..encode_run_detail_fields(detail)
      ])
  }
  |> json.to_string
}

fn encode_run_summary_fields(rs: RunSummary) -> List(#(String, json.Json)) {
  [
    #("id", json.int(rs.id)),
    #("start_date", json.string(rs.start_date)),
    #("end_date", json.string(rs.end_date)),
    #("status", json.string(rs.status)),
  ]
}

pub fn encode_client_message(msg: ClientMessage) -> String {
  case msg {
    SubmitTestRun(run) ->
      json.object([
        #("type", json.string("submit_test_run")),
        ..encode_test_run_fields(run)
      ])
    SubmitFullTestRun(run) ->
      json.object([
        #("type", json.string("submit_full_test_run")),
        ..encode_full_test_run_fields(run)
      ])
    SetSelection(nodes) ->
      json.object([
        #("type", json.string("set_selection")),
        #("selected_nodes", json.array(nodes, json.string)),
      ])
    ClearSelectionQuery ->
      json.object([#("type", json.string("clear_selection_query"))])
    RequestRunDetail(id) ->
      json.object([
        #("type", json.string("request_run_detail")),
        #("id", json.int(id)),
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

fn full_test_run_decoder() -> decode.Decoder(FullTestRun) {
  decode.field("force", decode.float, fn(force) {
    decode.field("duration", decode.float, fn(duration) {
      decode.field("winning_number", decode.int, fn(winning_number) {
        decode.field("color", decode.string, fn(color) {
          decode.field("start_date", decode.string, fn(start_date) {
            decode.field("end_date", decode.string, fn(end_date) {
              decode.field("status", decode.string, fn(status) {
                decode.field(
                  "logs",
                  decode.list(decode.string),
                  fn(logs) {
                    decode.field(
                      "gherkin_text",
                      decode.string,
                      fn(gherkin_text) {
                        decode.field(
                          "step_metrics",
                          decode.list(step_metric_decoder()),
                          fn(step_metrics) {
                            decode.success(FullTestRun(
                              force:,
                              duration:,
                              winning_number:,
                              color:,
                              start_date:,
                              end_date:,
                              status:,
                              logs:,
                              gherkin_text:,
                              step_metrics:,
                            ))
                          },
                        )
                      },
                    )
                  },
                )
              })
            })
          })
        })
      })
    })
  })
}

fn step_metric_decoder() -> decode.Decoder(StepMetric) {
  decode.field("name", decode.string, fn(name) {
    decode.field("duration_ms", decode.float, fn(duration_ms) {
      decode.field("status", decode.string, fn(status) {
        decode.success(StepMetric(name:, duration_ms:, status:))
      })
    })
  })
}

fn bucket_count_decoder() -> decode.Decoder(BucketCount) {
  decode.field("name", decode.string, fn(name) {
    decode.field("count", decode.int, fn(count) {
      decode.success(BucketCount(name:, count:))
    })
  })
}

fn sankey_link_decoder() -> decode.Decoder(SankeyLink) {
  decode.field("source", decode.string, fn(source) {
    decode.field("target", decode.string, fn(target) {
      decode.field("value", decode.int, fn(value) {
        decode.success(SankeyLink(source:, target:, value:))
      })
    })
  })
}

fn stats_decoder() -> decode.Decoder(Stats) {
  decode.field("total", decode.int, fn(total) {
    decode.field("force_counts", decode.list(bucket_count_decoder()), fn(fc) {
      decode.field(
        "duration_counts",
        decode.list(bucket_count_decoder()),
        fn(dc) {
          decode.field(
            "number_counts",
            decode.list(bucket_count_decoder()),
            fn(nc) {
              decode.field(
                "color_counts",
                decode.list(bucket_count_decoder()),
                fn(cc) {
                  decode.field(
                    "links",
                    decode.list(sankey_link_decoder()),
                    fn(links) {
                      decode.success(Stats(
                        total:,
                        force_counts: fc,
                        duration_counts: dc,
                        number_counts: nc,
                        color_counts: cc,
                        links:,
                      ))
                    },
                  )
                },
              )
            },
          )
        },
      )
    })
  })
}

fn run_summary_decoder() -> decode.Decoder(RunSummary) {
  decode.field("id", decode.int, fn(id) {
    decode.field("start_date", decode.string, fn(start_date) {
      decode.field("end_date", decode.string, fn(end_date) {
        decode.field("status", decode.string, fn(status) {
          decode.success(RunSummary(id:, start_date:, end_date:, status:))
        })
      })
    })
  })
}

fn run_detail_decoder() -> decode.Decoder(RunDetail) {
  decode.field("id", decode.int, fn(id) {
    decode.field("force", decode.float, fn(force) {
      decode.field("duration", decode.float, fn(duration) {
        decode.field("winning_number", decode.int, fn(winning_number) {
          decode.field("color", decode.string, fn(color) {
            decode.field("start_date", decode.string, fn(start_date) {
              decode.field("end_date", decode.string, fn(end_date) {
                decode.field("status", decode.string, fn(status) {
                  decode.field(
                    "logs",
                    decode.list(decode.string),
                    fn(logs) {
                      decode.field(
                        "gherkin_text",
                        decode.string,
                        fn(gherkin_text) {
                          decode.field(
                            "step_metrics",
                            decode.list(step_metric_decoder()),
                            fn(step_metrics) {
                              decode.field(
                                "force_label",
                                decode.string,
                                fn(force_label) {
                                  decode.field(
                                    "duration_label",
                                    decode.string,
                                    fn(duration_label) {
                                      decode.field(
                                        "number_label",
                                        decode.string,
                                        fn(number_label) {
                                          decode.field(
                                            "color_label",
                                            decode.string,
                                            fn(color_label) {
                                              decode.success(RunDetail(
                                                id:,
                                                force:,
                                                duration:,
                                                winning_number:,
                                                color:,
                                                start_date:,
                                                end_date:,
                                                status:,
                                                logs:,
                                                gherkin_text:,
                                                step_metrics:,
                                                force_label:,
                                                duration_label:,
                                                number_label:,
                                                color_label:,
                                              ))
                                            },
                                          )
                                        },
                                      )
                                    },
                                  )
                                },
                              )
                            },
                          )
                        },
                      )
                    },
                  )
                })
              })
            })
          })
        })
      })
    })
  })
}

pub fn server_message_decoder() -> decode.Decoder(ServerMessage) {
  use tag <- decode.then(decode.at(["type"], decode.string))
  case tag {
    "stats_snapshot" -> stats_decoder() |> decode.map(StatsSnapshot)
    "matching_runs" ->
      decode.field(
        "runs",
        decode.list(run_summary_decoder()),
        fn(runs) { decode.success(MatchingRuns(runs)) },
      )
    "matching_run_append" ->
      run_summary_decoder() |> decode.map(MatchingRunAppend)
    "all_runs" ->
      decode.field(
        "runs",
        decode.list(run_summary_decoder()),
        fn(runs) { decode.success(AllRuns(runs)) },
      )
    "new_run" -> run_summary_decoder() |> decode.map(NewRun)
    "run_detail" -> run_detail_decoder() |> decode.map(RunDetailResponse)
    _ ->
      decode.failure(
        StatsSnapshot(Stats(
          total: 0,
          force_counts: [],
          duration_counts: [],
          number_counts: [],
          color_counts: [],
          links: [],
        )),
        "ServerMessage",
      )
  }
}

pub fn client_message_decoder() -> decode.Decoder(ClientMessage) {
  use tag <- decode.then(decode.at(["type"], decode.string))
  case tag {
    "submit_test_run" -> test_run_decoder() |> decode.map(SubmitTestRun)
    "submit_full_test_run" ->
      full_test_run_decoder() |> decode.map(SubmitFullTestRun)
    "set_selection" ->
      decode.field(
        "selected_nodes",
        decode.list(decode.string),
        fn(nodes) { decode.success(SetSelection(nodes)) },
      )
    "clear_selection_query" -> decode.success(ClearSelectionQuery)
    "request_run_detail" ->
      decode.field("id", decode.int, fn(id) {
        decode.success(RequestRunDetail(id))
      })
    _ ->
      decode.failure(
        SubmitTestRun(TestRun(0.0, 0.0, 0, "")),
        "ClientMessage",
      )
  }
}
