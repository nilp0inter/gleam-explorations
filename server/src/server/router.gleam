import gleam/erlang/process.{type Subject}
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
  <title>Roulette Test Visualization</title>
  <link rel=\"stylesheet\" href=\"/static/app.css\">
  <script src=\"https://cdn.jsdelivr.net/npm/echarts@5/dist/echarts.min.js\"></script>
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
