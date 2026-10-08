%% NIF loader + helpers for orbital/internal/esp32 flash/device I/O.
%% Prefers priv/orbital_esp.so, then priv/orbital_esp-<triple>.so.
-module(orbital_esp_ffi).

-export([
    list_devices/0,
    select_port/1,
    select_device/1,
    erase_flash/1,
    read_flash/5,
    write_flash_data/3,
    write_flash_image/4,
    write_flash_parts/3
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
    Stems = ["orbital_esp", "orbital_esp-" ++ host_triple()],
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

os_family() ->
    case os:type() of
        {win32, _} -> <<"windows">>;
        {unix, darwin} -> <<"darwin">>;
        {unix, linux} -> <<"linux">>;
        _ -> <<"other">>
    end.

nif_missing() ->
    Triple = list_to_binary(host_triple()),
    {error,
        <<"orbital_esp NIF not loaded for ", Triple/binary,
            ". Need priv/orbital_esp-", Triple/binary,
            ".so or run: make -C priv/native">>}.

list_devices() -> list_devices_nif(os_family()).
select_port(Port) -> select_port_nif(Port, os_family()).
select_device(Port) -> select_device_nif(Port, os_family()).
erase_flash(Port) -> erase_flash_nif(Port).
read_flash(Port, Address, Size, Output, ResetAfter) ->
    read_flash_nif(Port, Address, Size, Output, ResetAfter).
write_flash_data(Port, Address, FilePath) ->
    write_flash_data_nif(Port, Address, FilePath).
write_flash_image(Port, Baud, Address, FilePath) ->
    write_flash_image_nif(Port, Baud, Address, FilePath).
write_flash_parts(Port, Baud, Parts) ->
    write_flash_parts_nif(Port, Baud, Parts).

list_devices_nif(_) -> nif_missing().
select_port_nif(_, _) -> nif_missing().
select_device_nif(_, _) -> nif_missing().
erase_flash_nif(_) -> nif_missing().
read_flash_nif(_, _, _, _, _) -> nif_missing().
write_flash_data_nif(_, _, _) -> nif_missing().
write_flash_image_nif(_, _, _, _) -> nif_missing().
write_flash_parts_nif(_, _, _) -> nif_missing().
