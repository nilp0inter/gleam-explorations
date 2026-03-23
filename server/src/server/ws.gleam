import gleam/erlang/process
import gleam/json
import gleam/option.{Some}
import mist
import server/db
import server/state
import shared/messages

pub type WsState {
  WsState(
    subject: process.Subject(String),
    state_actor: process.Subject(state.Msg),
    db_actor: process.Subject(db.Msg),
  )
}

pub fn on_init(
  state_actor: process.Subject(state.Msg),
  db_actor: process.Subject(db.Msg),
) -> fn(mist.WebsocketConnection) ->
  #(WsState, option.Option(process.Selector(String))) {
  fn(_conn: mist.WebsocketConnection) {
    let client_subject = process.new_subject()

    process.send(state_actor, state.ClientConnected(client_subject))

    let selector =
      process.new_selector()
      |> process.select(for: client_subject)

    #(
      WsState(
        subject: client_subject,
        state_actor: state_actor,
        db_actor: db_actor,
      ),
      Some(selector),
    )
  }
}

pub fn handler(
  ws_state: WsState,
  msg: mist.WebsocketMessage(String),
  conn: mist.WebsocketConnection,
) -> mist.Next(WsState, String) {
  case msg {
    mist.Text(text) -> {
      case json.parse(text, messages.client_message_decoder()) {
        Ok(messages.SubmitTestRun(run)) -> {
          process.send(ws_state.state_actor, state.IngestTestRun(run))
        }
        Ok(messages.SubmitFullTestRun(run)) -> {
          process.send(
            ws_state.state_actor,
            state.IngestFullTestRun(run),
          )
        }
        Ok(messages.SetSelection(nodes)) -> {
          process.send(
            ws_state.db_actor,
            db.RegisterQuery(ws_state.subject, nodes),
          )
        }
        Ok(messages.ClearSelectionQuery) -> {
          process.send(
            ws_state.db_actor,
            db.UnregisterQuery(ws_state.subject),
          )
        }
        Ok(messages.RequestRunDetail(id)) -> {
          process.send(
            ws_state.db_actor,
            db.GetRunDetail(id, ws_state.subject),
          )
        }
        Error(_) -> Nil
      }
      mist.continue(ws_state)
    }
    mist.Custom(json_string) -> {
      let _ = mist.send_text_frame(conn, json_string)
      mist.continue(ws_state)
    }
    mist.Closed | mist.Shutdown -> {
      process.send(
        ws_state.state_actor,
        state.ClientDisconnected(ws_state.subject),
      )
      mist.stop()
    }
    mist.Binary(_) -> mist.continue(ws_state)
  }
}

pub fn on_close(ws_state: WsState) -> Nil {
  process.send(
    ws_state.state_actor,
    state.ClientDisconnected(ws_state.subject),
  )
}
