%% NIF loader + helpers for orbital/internal/monitor.
%% Prefers priv/orbital_serial.so, then priv/orbital_serial-<triple>.so.
-module(orbital_serial_ffi).

-export([
    list_ports/0,
    open/2,
    close/1,
    read/3,
    set_rts/2,
    set_dtr/2,
    write_stdout/1,
    os_family/0,
    monotonic_time_ms/0,
    sleep_ms/1,
    utf8_feed/2
]).

-on_load(init/0).

init() ->
    case try_load(nif_candidates()) of
        ok -> ok;
        {error, _} -> ok
    end.

try_load([]) ->
    {error, nif_not_found};
try_load([Path | Rest]) ->
    case erlang:load_nif(Path, 0) of
        ok -> ok;
        {error, _} -> try_load(Rest)
    end.

nif_candidates() ->
    Stems = ["orbital_serial", "orbital_serial-" ++ host_triple()],
    lists:flatmap(
        fun(Dir) -> [filename:join(Dir, Stem) || Stem <- Stems] end,
        priv_dirs()
    ).

priv_dirs() ->
    case code:which(?MODULE) of
        non_existing ->
            ["priv"];
        Beam ->
            Absolute = filename:absname(Beam),
            Build = lists:foldl(
                fun(_, Acc) -> filename:dirname(Acc) end,
                Absolute,
                lists:seq(1, 5)
            ),
            Root = filename:dirname(Build),
            unique([
                filename:join(Root, "priv"),
                filename:join([Build, "packages", "orbital", "priv"]),
                filename:join([filename:dirname(Absolute), "..", "priv"])
            ])
    end.

unique([]) -> [];
unique([H | T]) ->
    [H | unique([X || X <- T, X =/= H])].

host_triple() ->
    case {os:type(), cpu_family()} of
        {{unix, darwin}, aarch64} -> "aarch64-apple-darwin";
        {{unix, darwin}, x86_64} -> "x86_64-apple-darwin";
        {{unix, linux}, aarch64} -> "aarch64-unknown-linux-gnu";
        {{unix, linux}, x86_64} -> "x86_64-unknown-linux-gnu";
        {{win32, _}, _} -> "x86_64-pc-windows-gnu";
        _ -> "unknown"
    end.

cpu_family() ->
    case erlang:system_info(system_architecture) of
        "aarch64" ++ _ -> aarch64;
        "arm64" ++ _ -> aarch64;
        "x86_64" ++ _ -> x86_64;
        "amd64" ++ _ -> x86_64;
        _ -> x86_64
    end.

list_ports() -> list_ports_nif().
open(Name, Baud) -> open_nif(Name, Baud).
close(Ref) -> _ = close_nif(Ref), nil.
set_rts(Ref, Value) -> _ = set_rts_nif(Ref, Value), nil.
set_dtr(Ref, Value) -> _ = set_dtr_nif(Ref, Value), nil.

read(Ref, Max, TimeoutMs) ->
    case read_nif(Ref, Max, TimeoutMs) of
        {ok, empty} -> timed_out;
        {ok, Bin} when is_binary(Bin) -> {bytes, Bin};
        {error, disconnected} -> port_gone;
        {error, Reason} when is_binary(Reason) -> {failed, Reason};
        {error, Reason} ->
            {failed, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

nif_missing() ->
    Triple = list_to_binary(host_triple()),
    {error,
        <<"orbital_serial NIF not loaded for ", Triple/binary,
            ". Need priv/orbital_serial-", Triple/binary,
            ".so or run: make -C priv/native">>}.

list_ports_nif() -> nif_missing().
open_nif(_, _) -> nif_missing().
close_nif(_) -> nif_missing().
read_nif(_, _, _) -> nif_missing().
set_rts_nif(_, _) -> nif_missing().
set_dtr_nif(_, _) -> nif_missing().

write_stdout(Bin) when is_binary(Bin) ->
    io:put_chars(standard_io, Bin),
    nil;
write_stdout(Text) when is_list(Text) ->
    write_stdout(unicode:characters_to_binary(Text)).

os_family() ->
    case os:type() of
        {win32, _} -> <<"windows">>;
        {unix, darwin} -> <<"darwin">>;
        {unix, linux} -> <<"linux">>;
        _ -> <<"other">>
    end.

monotonic_time_ms() ->
    erlang:monotonic_time(millisecond).

sleep_ms(Ms) when is_integer(Ms), Ms >= 0 ->
    receive after Ms -> nil end.

utf8_feed(Pending, Data) when is_binary(Pending), is_binary(Data) ->
    utf8_loop(<<Pending/binary, Data/binary>>, <<>>).

utf8_loop(<<>>, Acc) ->
    {Acc, <<>>};
utf8_loop(Bin, Acc) ->
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Out when is_binary(Out) ->
            {<<Acc/binary, Out/binary>>, <<>>};
        {incomplete, Good, Rest} ->
            {<<Acc/binary, (as_bin(Good))/binary>>, Rest};
        {error, Good, <<_, Rest/binary>>} ->
            utf8_loop(Rest, <<Acc/binary, (as_bin(Good))/binary, 16#EF, 16#BF, 16#BD>>);
        {error, Good, <<>>} ->
            {<<Acc/binary, (as_bin(Good))/binary, 16#EF, 16#BF, 16#BD>>, <<>>}
    end.

as_bin(Bin) when is_binary(Bin) -> Bin;
as_bin(List) when is_list(List) -> unicode:characters_to_binary(List);
as_bin(_) -> <<>>.
