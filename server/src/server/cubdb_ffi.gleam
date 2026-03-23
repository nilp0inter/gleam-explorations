pub type Db

@external(erlang, "cubdb_bridge", "start_link")
pub fn start_link(path: String) -> Result(Db, String)

@external(erlang, "cubdb_bridge", "get")
pub fn get(db: Db, key: key) -> Result(value, Nil)

@external(erlang, "cubdb_bridge", "put")
pub fn put(db: Db, key: key, value: value) -> Nil

@external(erlang, "cubdb_bridge", "select_runs")
pub fn select_runs(db: Db) -> List(#(key, value))
