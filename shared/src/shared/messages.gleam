import gleam/dynamic/decode
import gleam/json

// === Types ===

pub type TestRun {
  TestRun(force: Float, duration: Float, winning_number: Int, color: String)
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

// === Server -> Client Messages ===

pub type ServerMessage {
  StatsSnapshot(stats: Stats)
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

pub fn encode_server_message(msg: ServerMessage) -> String {
  case msg {
    StatsSnapshot(stats) ->
      json.object([
        #("type", json.string("stats_snapshot")),
        ..encode_stats(stats)
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

pub fn server_message_decoder() -> decode.Decoder(ServerMessage) {
  use tag <- decode.then(decode.at(["type"], decode.string))
  case tag {
    "stats_snapshot" -> stats_decoder() |> decode.map(StatsSnapshot)
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
    _ ->
      decode.failure(
        SubmitTestRun(TestRun(0.0, 0.0, 0, "")),
        "ClientMessage",
      )
  }
}
