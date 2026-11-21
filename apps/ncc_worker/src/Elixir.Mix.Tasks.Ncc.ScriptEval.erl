-module('Elixir.Mix.Tasks.Ncc.ScriptEval').
%% `mix ncc.script_eval`: one evaluation of the script check
%% (NccWorker.Portability.ScriptCheck). Run in the run's own project, in a
%% Mix VM, as the traced compile's driver runs: Mix, Mix.Project and Hex are
%% loaded, and Mix.Dep.load_and_cache/0 evaluates every rebar3 dependency's
%% rebar.config.script as it does when it loads the dependencies. For each
%% app the check names it writes the config Mix writes as that app's
%% mix.rebar.config (Mix.Rebar.dependency_config/1, then serialize_config/1),
%% hashed whole, and one hash per top-level key of it but `deps`.
%%
%% What to report and where comes from script_eval.etf next to this beam,
%% never from the environment or the arguments, which are the words under
%% test. Written in Erlang so the worker app needs no :mix dependency; Mix
%% finds it by name.
-export([run/1, '__info__'/1]).

%% Mix reads module.__info__(:attributes) for @shortdoc, @recursive and
%% @requirements; this task has none of them.
'__info__'(_Kind) -> [].

run(_Args) ->
    Dir = filename:dirname(code:which(?MODULE)),
    {ok, Bin} = file:read_file(filename:join(Dir, "script_eval.etf")),
    #{apps := Apps, out := Out} = binary_to_term(Bin, [safe]),
    Deps = 'Elixir.Mix.Dep':load_and_cache(),
    Lines = [lines(D) || D <- Deps, lists:member(app_bin(D), Apps)],
    ok = file:write_file(Out, Lines).

app_bin(#{app := App}) when is_atom(App) -> atom_to_binary(App);
app_bin(_Dep) -> none.

lines(#{extra := Extra} = Dep) when is_list(Extra) ->
    App = app_bin(Dep),
    Config = 'Elixir.Mix.Rebar':dependency_config(Extra),
    Full = hex(iolist_to_binary('Elixir.Mix.Rebar':serialize_config(Config))),
    Keys = maps:to_list(lists:foldl(fun group/2, #{}, Config)),
    [[App, <<"\tfull\t">>, Full, <<"\n">>]
     | [[App, <<"\tkey\t">>, K, <<"\t">>, hex(term_to_binary(lists:reverse(Es), [deterministic])),
         <<"\n">>]
        || {K, Es} <- lists:sort(Keys), K =/= <<"deps">>]];
lines(Dep) -> [app_bin(Dep), <<"\tnone\n">>].

group(Entry, Acc) ->
    Key = key(Entry),
    maps:update_with(Key, fun(Es) -> [Entry | Es] end, [Entry], Acc).

key(Entry) when is_tuple(Entry), tuple_size(Entry) > 0, is_atom(element(1, Entry)) ->
    atom_to_binary(element(1, Entry));
key(Entry) ->
    hex(term_to_binary(Entry, [deterministic])).

hex(Bin) -> binary:encode_hex(crypto:hash(sha256, Bin), lowercase).
