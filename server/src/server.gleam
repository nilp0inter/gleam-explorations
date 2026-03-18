import gleam/erlang/application
import gleam/erlang/process
import gleam/http/request
import gleam/io
import mist
import server/router
import server/state
import server/ws
import wisp
import wisp/wisp_mist

pub fn main() {
  wisp.configure_logger()

  let assert Ok(state_actor) = state.start()

  let assert Ok(priv) = application.priv_directory("server")
  let static_dir = priv <> "/static"

  let ctx = router.Context(state_actor: state_actor, static_dir: static_dir)

  let secret_key_base = wisp.random_string(64)

  let wisp_handler =
    wisp_mist.handler(
      fn(req) { router.handle_request(req, ctx) },
      secret_key_base,
    )

  let handler = fn(req) {
    case request.path_segments(req) {
      ["ws"] ->
        mist.websocket(
          request: req,
          handler: ws.handler,
          on_init: ws.on_init(state_actor),
          on_close: ws.on_close,
        )
      _ -> wisp_handler(req)
    }
  }

  let assert Ok(_) =
    mist.new(handler)
    |> mist.port(8080)
    |> mist.start()

  io.println("Server started on http://localhost:8080")
  process.sleep_forever()
}
