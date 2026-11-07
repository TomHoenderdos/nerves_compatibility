-module(ncc_tracer_config).
%% The application env of the traced compile's Mix VM, taken before anything
%% compiles (precompiled portability spec, R5): Mix has loaded the project's
%% config, and no dependency's .app or mix.exs is loaded yet, which is what a
%% client's config lookup sees in its own project. Read straight from the
%% application controller's table, so taking it makes no traced
%% application:get_env call and sees the env of apps not loaded yet.
%%
%% Each value is encoded exactly as a manifest compile_env value: base64url of
%% term_to_binary({ok, V}, [deterministic]). The reader keeps it as text and
%% never decodes it. Bounded: at most max_entries rows, max_value bytes per
%% value (a bigger one is marked oversize, its size taken before it is
%% encoded) and max_total encoded bytes; past a cap the snapshot is cut short
%% and marked truncated.
-export([snapshot/0, entries/2]).

-define(LIMITS, #{max_entries => 2000, max_value => 65536, max_total => 1048576}).

snapshot() ->
    try ets:match_object(ac_tab, {{env, '_', '_'}, '_'}) of
        Rows -> entries(Rows, ?LIMITS)
    catch
        _:_ -> error
    end.

entries(Rows, #{max_entries := MaxN, max_value := MaxV, max_total := MaxT}) ->
    Named = lists:sort([{App, Key, Value} || {{env, App, Key}, Value} <- Rows,
                                            is_atom(App), is_atom(Key)]),
    take(Named, MaxN, MaxV, MaxT, []).

take([], _N, _MaxV, _Left, Acc) -> {lists:reverse(Acc), false};
take(_Rows, 0, _MaxV, _Left, Acc) -> {lists:reverse(Acc), true};
take([{App, Key, Value} | Rest], N, MaxV, Left, Acc) ->
    Base = #{app => atom_to_binary(App), key => atom_to_binary(Key)},
    case erlang:external_size({ok, Value}, [deterministic]) =< MaxV of
        false ->
            take(Rest, N - 1, MaxV, Left, [Base#{value => null, oversize => true} | Acc]);
        true ->
            Bin = term_to_binary({ok, Value}, [deterministic]),
            Enc = base64:encode(Bin, #{mode => urlsafe, padding => false}),
            case byte_size(Enc) =< Left of
                true ->
                    take(Rest, N - 1, MaxV, Left - byte_size(Enc), [Base#{value => Enc} | Acc]);
                false ->
                    {lists:reverse(Acc), true}
            end
    end.
