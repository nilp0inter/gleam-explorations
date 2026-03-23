-module(cubdb_bridge).
-export([start_link/1, get/2, put/3, select_runs/1, select_runs_for/2, select_run_infos/1]).

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

%% Select runs for a specific run_id: {run_key, RunId, 0} to {run_key, RunId, inf}
select_runs_for(Db, RunId) ->
    Stream = 'Elixir.CubDB':select(Db, [
        {min_key, {run_key, RunId, 0}},
        {max_key, {run_key, RunId, inf}}
    ]),
    'Elixir.Enum':to_list(Stream).

%% Select all run info entries: {run_info_key, _}
%% Note: atoms sort BEFORE binaries in Erlang term ordering, so we can't use
%% 'inf' as max bound for string keys. <<255>> sorts after all valid UTF-8 strings.
select_run_infos(Db) ->
    Stream = 'Elixir.CubDB':select(Db, [
        {min_key, {run_info_key, <<>>}},
        {max_key, {run_info_key, <<255>>}}
    ]),
    'Elixir.Enum':to_list(Stream).
