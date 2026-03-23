-module(cubdb_bridge).
-export([start_link/1, get/2, put/3, select_runs/1]).

start_link(Path) ->
    'Elixir.CubDB':start_link([{data_dir, Path}]).

get(Db, Key) ->
    case 'Elixir.CubDB':get(Db, Key) of
        nil -> {error, nil};
        Value -> {ok, Value}
    end.

put(Db, Key, Value) ->
    'Elixir.CubDB':put(Db, Key, Value).

%% Select only entries whose key matches {run_key, _Id}
select_runs(Db) ->
    Stream = 'Elixir.CubDB':select(Db, [{min_key, {run_key, 0}}, {max_key, {run_key, inf}}]),
    'Elixir.Enum':to_list(Stream).
