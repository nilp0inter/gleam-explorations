pub type Db

@external(erlang, "cubdb_bridge", "start_link")
pub fn start_link(path: String) -> Result(Db, String)

@external(erlang, "cubdb_bridge", "get")
pub fn get(db: Db, key: key) -> Result(value, Nil)

@external(erlang, "cubdb_bridge", "put")
pub fn put(db: Db, key: key, value: value) -> Nil

@external(erlang, "cubdb_bridge", "select_runs")
pub fn select_runs(db: Db) -> List(#(key, value))

@external(erlang, "cubdb_bridge", "select_runs_for")
pub fn select_runs_for(db: Db, run_id: String) -> List(#(key, value))

@external(erlang, "cubdb_bridge", "select_run_infos")
pub fn select_run_infos(db: Db) -> List(#(key, value))
