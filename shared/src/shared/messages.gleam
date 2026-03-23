import gleam/dynamic/decode
import gleam/json

// === Types ===

pub type RunInfo {
  RunInfo(run_id: String, created_at: String, sample_count: Int)
}

pub type Sample {
  Sample(force: Float, duration: Float, winning_number: Int, color: String)
}

pub type FullSample {
  FullSample(
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

pub type SampleSummary {
  SampleSummary(id: Int, start_date: String, end_date: String, status: String)
}

pub type SampleDetail {
  SampleDetail(
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
  MatchingSamples(samples: List(SampleSummary))
  MatchingSampleAppend(sample: SampleSummary)
  AllSamples(samples: List(SampleSummary))
  NewSample(sample: SampleSummary)
  SampleDetailResponse(detail: SampleDetail)
  RunList(runs: List(RunInfo))
  RunCreated(run: RunInfo)
}

// === Client -> Server Messages ===

pub type ClientMessage {
  SubmitSample(run_id: String, sample: Sample)
  SubmitFullSample(run_id: String, sample: FullSample)
  SetSelection(selected_nodes: List(String))
  ClearSelectionQuery
  RequestSampleDetail(id: Int)
  ListRuns
  SelectRun(run_id: String)
}

// === Encoders ===

fn encode_sample_fields(sample: Sample) -> List(#(String, json.Json)) {
  [
    #("force", json.float(sample.force)),
    #("duration", json.float(sample.duration)),
    #("winning_number", json.int(sample.winning_number)),
    #("color", json.string(sample.color)),
  ]
}

fn encode_full_sample_fields(
  sample: FullSample,
) -> List(#(String, json.Json)) {
  [
    #("force", json.float(sample.force)),
    #("duration", json.float(sample.duration)),
    #("winning_number", json.int(sample.winning_number)),
    #("color", json.string(sample.color)),
    #("start_date", json.string(sample.start_date)),
    #("end_date", json.string(sample.end_date)),
    #("status", json.string(sample.status)),
    #("logs", json.array(sample.logs, json.string)),
    #("gherkin_text", json.string(sample.gherkin_text)),
    #(
      "step_metrics",
      json.array(sample.step_metrics, encode_step_metric),
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

fn encode_sample_summary(ss: SampleSummary) -> json.Json {
  json.object(encode_sample_summary_fields(ss))
}

fn encode_sample_summary_fields(
  ss: SampleSummary,
) -> List(#(String, json.Json)) {
  [
    #("id", json.int(ss.id)),
    #("start_date", json.string(ss.start_date)),
    #("end_date", json.string(ss.end_date)),
    #("status", json.string(ss.status)),
  ]
}

fn encode_sample_detail_fields(
  d: SampleDetail,
) -> List(#(String, json.Json)) {
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

fn encode_run_info(info: RunInfo) -> json.Json {
  json.object(encode_run_info_fields(info))
}

fn encode_run_info_fields(info: RunInfo) -> List(#(String, json.Json)) {
  [
    #("run_id", json.string(info.run_id)),
    #("created_at", json.string(info.created_at)),
    #("sample_count", json.int(info.sample_count)),
  ]
}

pub fn encode_server_message(msg: ServerMessage) -> String {
  case msg {
    StatsSnapshot(stats) ->
      json.object([
        #("type", json.string("stats_snapshot")),
        ..encode_stats(stats)
      ])
    MatchingSamples(samples) ->
      json.object([
        #("type", json.string("matching_samples")),
        #("samples", json.array(samples, encode_sample_summary)),
      ])
    MatchingSampleAppend(sample) ->
      json.object([
        #("type", json.string("matching_sample_append")),
        ..encode_sample_summary_fields(sample)
      ])
    AllSamples(samples) ->
      json.object([
        #("type", json.string("all_samples")),
        #("samples", json.array(samples, encode_sample_summary)),
      ])
    NewSample(sample) ->
      json.object([
        #("type", json.string("new_sample")),
        ..encode_sample_summary_fields(sample)
      ])
    SampleDetailResponse(detail) ->
      json.object([
        #("type", json.string("sample_detail")),
        ..encode_sample_detail_fields(detail)
      ])
    RunList(runs) ->
      json.object([
        #("type", json.string("run_list")),
        #("runs", json.array(runs, encode_run_info)),
      ])
    RunCreated(run) ->
      json.object([
        #("type", json.string("run_created")),
        ..encode_run_info_fields(run)
      ])
  }
  |> json.to_string
}

pub fn encode_client_message(msg: ClientMessage) -> String {
  case msg {
    SubmitSample(run_id, sample) ->
      json.object([
        #("type", json.string("submit_sample")),
        #("run_id", json.string(run_id)),
        ..encode_sample_fields(sample)
      ])
    SubmitFullSample(run_id, sample) ->
      json.object([
        #("type", json.string("submit_full_sample")),
        #("run_id", json.string(run_id)),
        ..encode_full_sample_fields(sample)
      ])
    SetSelection(nodes) ->
      json.object([
        #("type", json.string("set_selection")),
        #("selected_nodes", json.array(nodes, json.string)),
      ])
    ClearSelectionQuery ->
      json.object([#("type", json.string("clear_selection_query"))])
    RequestSampleDetail(id) ->
      json.object([
        #("type", json.string("request_sample_detail")),
        #("id", json.int(id)),
      ])
    ListRuns ->
      json.object([#("type", json.string("list_runs"))])
    SelectRun(run_id) ->
      json.object([
        #("type", json.string("select_run")),
        #("run_id", json.string(run_id)),
      ])
  }
  |> json.to_string
}

// === Decoders ===

fn sample_decoder() -> decode.Decoder(Sample) {
  decode.field("force", decode.float, fn(force) {
    decode.field("duration", decode.float, fn(duration) {
      decode.field("winning_number", decode.int, fn(winning_number) {
        decode.field("color", decode.string, fn(color) {
          decode.success(Sample(force:, duration:, winning_number:, color:))
        })
      })
    })
  })
}

fn full_sample_decoder() -> decode.Decoder(FullSample) {
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
                            decode.success(FullSample(
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

fn sample_summary_decoder() -> decode.Decoder(SampleSummary) {
  decode.field("id", decode.int, fn(id) {
    decode.field("start_date", decode.string, fn(start_date) {
      decode.field("end_date", decode.string, fn(end_date) {
        decode.field("status", decode.string, fn(status) {
          decode.success(SampleSummary(id:, start_date:, end_date:, status:))
        })
      })
    })
  })
}

fn sample_detail_decoder() -> decode.Decoder(SampleDetail) {
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
                                              decode.success(SampleDetail(
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

fn run_info_decoder() -> decode.Decoder(RunInfo) {
  decode.field("run_id", decode.string, fn(run_id) {
    decode.field("created_at", decode.string, fn(created_at) {
      decode.field("sample_count", decode.int, fn(sample_count) {
        decode.success(RunInfo(run_id:, created_at:, sample_count:))
      })
    })
  })
}

pub fn server_message_decoder() -> decode.Decoder(ServerMessage) {
  use tag <- decode.then(decode.at(["type"], decode.string))
  case tag {
    "stats_snapshot" -> stats_decoder() |> decode.map(StatsSnapshot)
    "matching_samples" ->
      decode.field(
        "samples",
        decode.list(sample_summary_decoder()),
        fn(samples) { decode.success(MatchingSamples(samples)) },
      )
    "matching_sample_append" ->
      sample_summary_decoder() |> decode.map(MatchingSampleAppend)
    "all_samples" ->
      decode.field(
        "samples",
        decode.list(sample_summary_decoder()),
        fn(samples) { decode.success(AllSamples(samples)) },
      )
    "new_sample" -> sample_summary_decoder() |> decode.map(NewSample)
    "sample_detail" ->
      sample_detail_decoder() |> decode.map(SampleDetailResponse)
    "run_list" ->
      decode.field(
        "runs",
        decode.list(run_info_decoder()),
        fn(runs) { decode.success(RunList(runs)) },
      )
    "run_created" ->
      run_info_decoder() |> decode.map(RunCreated)
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
    "submit_sample" ->
      decode.field("run_id", decode.string, fn(run_id) {
        sample_decoder()
        |> decode.map(fn(sample) { SubmitSample(run_id, sample) })
      })
    "submit_full_sample" ->
      decode.field("run_id", decode.string, fn(run_id) {
        full_sample_decoder()
        |> decode.map(fn(sample) { SubmitFullSample(run_id, sample) })
      })
    "set_selection" ->
      decode.field(
        "selected_nodes",
        decode.list(decode.string),
        fn(nodes) { decode.success(SetSelection(nodes)) },
      )
    "clear_selection_query" -> decode.success(ClearSelectionQuery)
    "request_sample_detail" ->
      decode.field("id", decode.int, fn(id) {
        decode.success(RequestSampleDetail(id))
      })
    "list_runs" -> decode.success(ListRuns)
    "select_run" ->
      decode.field("run_id", decode.string, fn(run_id) {
        decode.success(SelectRun(run_id))
      })
    _ ->
      decode.failure(
        SubmitSample("", Sample(0.0, 0.0, 0, "")),
        "ClientMessage",
      )
  }
}
