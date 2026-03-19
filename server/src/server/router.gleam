import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http
import server/state
import wisp.{type Request, type Response}

pub type Context {
  Context(state_actor: Subject(state.Msg), static_dir: String)
}

pub fn handle_request(req: Request, ctx: Context) -> Response {
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use <- wisp.serve_static(req, under: "/static", from: ctx.static_dir)

  case wisp.path_segments(req) {
    [] -> serve_html()

    ["publish", queue_name] -> {
      case req.method {
        http.Post -> publish_message(req, ctx, queue_name)
        _ -> wisp.method_not_allowed([http.Post])
      }
    }

    _ -> wisp.not_found()
  }
}

fn serve_html() -> Response {
  let html =
    "<!DOCTYPE html>
<html>
<head>
  <meta charset=\"utf-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
  <title>Queue Explorer</title>
  <link rel=\"stylesheet\" href=\"/static/app.css\">
</head>
<body>
  <div id=\"app\"></div>
  <script type=\"module\">
    import { main } from \"/static/app.js\";
    main();
  </script>
</body>
</html>"
  wisp.html_response(html, 200)
}

fn publish_message(req: Request, ctx: Context, queue_name: String) -> Response {
  use json_body <- wisp.require_json(req)
  let decoder =
    decode.field("message", decode.string, fn(message) {
      decode.success(message)
    })
  case decode.run(json_body, decoder) {
    Ok(message) -> {
      process.send(ctx.state_actor, state.PublishMessage(queue_name, message))
      wisp.json_response("{\"ok\": true}", 200)
    }
    Error(_) -> wisp.bad_request("Invalid JSON body")
  }
}
