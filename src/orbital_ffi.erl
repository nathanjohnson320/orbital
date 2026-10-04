-module(orbital_ffi).

-export([
    packbeam_create/3,
    packbeam_list/1,
    run_executable/3,
    find_executable/1,
    monitor/4,
    esp32_list_devices/0,
    esp32_select_port/1,
    esp32_select_device/1,
    esp32_erase_flash/1,
    esp32_read_flash/5,
    esp32_write_flash_data/3,
    esp32_write_flash_image/4,
    esp32_write_flash_parts/3,
    firmware_list_images/3,
    firmware_ensure/6,
    confirm/1
]).

packbeam_create(OutputPath, StartModule, Files) ->
    % The packbeam_api call expects its arguments to be Erlang charlists,
    % this is called from Gleam passing in Gleam strings (binaries).
    % So we need to massage those types into something that packbeam will
    % accept.
    CharOutputPath = unicode:characters_to_list(OutputPath),
    CharFiles = [unicode:characters_to_list(File) || File <- Files],
    Options = #{
        % This removes beam files that are not referenced
        prune => true,
        lib => false,
        start_module => binary_to_atom(StartModule),
        include_lines => true
    },
    try packbeam_api:create(CharOutputPath, CharFiles, Options) of
        ok -> {ok, nil};
        {error, eisdir} -> {error, {output_file_is_directory, OutputPath}};
        {error, _} -> {error, {cannot_find_entrypoint_module, StartModule}}
    catch
        _ -> {error, {cannot_find_entrypoint_module, StartModule}}
    end.

-spec packbeam_list(binary()) -> {ok,[binary()]} | {error, nil}.
packbeam_list(InputPath) ->
    ListInputPath = unsafe_characters_to_list(InputPath),
    try packbeam_api:list(ListInputPath) of
        Elements when is_list(Elements) ->
            Names = lists:map(fun(Element) ->
                Name = packbeam_api:get_element_name(Element),
                unsafe_characters_to_binary(Name)
            end, Elements),
            {ok, Names};
        _ -> {error, nil}
    catch
        _ -> {error, nil}
    end.

-spec run_executable(Name :: binary(), Directory :: binary(), Arguments :: list(binary())) -> {ok, integer()} | {error, nil}.
run_executable(Name, Directory, Arguments) ->
    try
        StringName = unsafe_characters_to_list(Name),
        Port = erlang:open_port({spawn_executable, StringName},
            [
                {args, Arguments},
                {cd, Directory},
                hide,
                exit_status,
                stderr_to_stdout,
                use_stdio
            ]
        ),
        ExitStatus = receive {Port, {exit_status, Code}} -> Code end,
        {ok, ExitStatus}
    catch
        error:_ -> {error, nil}
    end.

-spec find_executable(Name :: binary()) -> {ok, binary()} | {error, nil}.
find_executable(Name) ->
    case os:find_executable(unsafe_characters_to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, unsafe_characters_to_binary(Path)}
    end.

%% Shows the ESP32 console. The Python interpreter is taken from esptool's
%% shebang, because that environment has pyserial.
monitor(Port, Baud, Reset, Timeout) ->
    case interpreter() of
        {error, Reason} -> {error, Reason};
        {ok, Python} ->
            case priv_script(<<"monitor.py">>) of
                {error, Reason} -> {error, Reason};
                {ok, Script} ->
                    run_streaming(Python, [
                        "-u", Script, "--port", Port,
                        "--baud", integer_to_binary(Baud),
                        "--timeout", integer_to_binary(Timeout)
                        | reset_arg(Reset)
                    ])
            end
    end.

reset_arg(true) -> [];
reset_arg(false) -> ["--no-reset"].

%% --- ESP32 helpers (priv/esp32.py) -----------------------------------------
%%
%% Each helper returns {ok, JsonBinary} | {error, ReasonBinary}. Gleam decodes
%% the JSON so we do not have to mirror Gleam record tags here.

esp32_list_devices() ->
    run_esp32_json([<<"list-devices">>]).

esp32_select_port(Port) ->
    run_esp32_json([<<"select-port">>, <<"--port">>, Port]).

esp32_select_device(Port) ->
    run_esp32_json([<<"select-device">>, <<"--port">>, Port]).

esp32_erase_flash(Port) ->
    case run_esp32_collect([<<"erase-flash">>, <<"--port">>, Port]) of
        {ok, _Stdout} -> {ok, nil};
        {error, Reason} -> {error, Reason}
    end.

esp32_read_flash(Port, Address, Size, OutputPath, ResetAfter) ->
    ResetArgs = case ResetAfter of
        true -> [<<"--reset-after">>];
        false -> []
    end,
    run_esp32_json([
        <<"read-flash">>,
        <<"--port">>, Port,
        <<"--address">>, integer_to_binary(Address),
        <<"--size">>, integer_to_binary(Size),
        <<"--output">>, OutputPath
        | ResetArgs
    ]).

esp32_write_flash_data(Port, Address, FilePath) ->
    case run_esp32_collect([
        <<"write-flash-data">>,
        <<"--port">>, Port,
        <<"--address">>, integer_to_binary(Address),
        <<"--file">>, FilePath
    ]) of
        {ok, _Stdout} -> {ok, nil};
        {error, Reason} -> {error, Reason}
    end.

esp32_write_flash_image(Port, Baud, Address, FilePath) ->
    case run_esp32_collect([
        <<"write-flash-image">>,
        <<"--port">>, Port,
        <<"--baud">>, integer_to_binary(Baud),
        <<"--address">>, integer_to_binary(Address),
        <<"--file">>, FilePath
    ]) of
        {ok, _Stdout} -> {ok, nil};
        {error, Reason} -> {error, Reason}
    end.

%% Parts is a list of {Address :: integer(), FilePath :: binary()}.
esp32_write_flash_parts(Port, Baud, Parts) ->
    PartArgs = lists:append([
        [<<"--part">>, <<(integer_to_binary(Address))/binary, ":", FilePath/binary>>]
     || {Address, FilePath} <- Parts
    ]),
    case run_esp32_collect([
        <<"write-flash-parts">>,
        <<"--port">>, Port,
        <<"--baud">>, integer_to_binary(Baud)
        | PartArgs
    ]) of
        {ok, _Stdout} -> {ok, nil};
        {error, Reason} -> {error, Reason}
    end.

%% Chip may be <<>> meaning omitted; Repo may be <<>> meaning omitted.
firmware_list_images(Chip, Repo, ConnectedChips) ->
    Args = [<<"list-images">>]
        ++ case Chip of <<>> -> []; _ -> [<<"--chip">>, Chip] end
        ++ case Repo of <<>> -> []; _ -> [<<"--repo">>, Repo] end
        ++ case ConnectedChips of
            <<>> -> [];
            _ -> [<<"--connected-chips">>, ConnectedChips]
        end,
    case run_firmware_collect(Args) of
        {ok, Stdout} -> {ok, Stdout};
        {error, Reason} -> {error, Reason}
    end.

%% Mode is <<"release">> | <<"name">> | <<"path">>.
%% Optional binaries may be <<>> when omitted.
firmware_ensure(Mode, Chip, Version, Name, Path, Repo) ->
    Args = [
        <<"ensure">>, <<"--mode">>, Mode
        | optional_arg(<<"--chip">>, Chip)
        ++ optional_arg(<<"--version">>, Version)
        ++ optional_arg(<<"--name">>, Name)
        ++ optional_arg(<<"--path">>, Path)
        ++ optional_arg(<<"--repo">>, Repo)
    ],
    run_firmware_json(Args).

optional_arg(_Flag, <<>>) -> [];
optional_arg(Flag, Value) -> [Flag, Value].

confirm(Prompt) ->
    io:put_chars(Prompt),
    case io:get_line("") of
        eof -> false;
        {error, _} -> false;
        Line ->
            case string:trim(Line) of
                "Y" -> true;
                "y" -> true;
                _ -> false
            end
    end.

run_firmware_json(Args) ->
    case run_firmware_collect(Args) of
        {error, Reason} -> {error, Reason};
        {ok, Stdout} -> {ok, first_json_line(Stdout)}
    end.

run_firmware_collect(Args) ->
    case interpreter() of
        {error, Reason} -> {error, Reason};
        {ok, Python} ->
            case priv_script(<<"firmware.py">>) of
                {error, Reason} -> {error, Reason};
                {ok, Script} ->
                    collect_output(Python, [<<"-u">>, Script | Args])
            end
    end.

run_esp32_json(Args) ->
    case run_esp32_collect(Args) of
        {error, Reason} -> {error, Reason};
        {ok, Stdout} -> {ok, first_json_line(Stdout)}
    end.

run_esp32_collect(Args) ->
    case interpreter() of
        {error, Reason} -> {error, Reason};
        {ok, Python} ->
            case priv_script(<<"esp32.py">>) of
                {error, Reason} -> {error, Reason};
                {ok, Script} ->
                    collect_output(Python, [<<"-u">>, Script | Args])
            end
    end.

first_json_line(Bin) ->
    case binary:split(Bin, <<"\n">>, [global, trim_all]) of
        [] -> <<>>;
        Lines ->
            %% Take the last non-empty line; esptool may print progress earlier.
            lists:last(Lines)
    end.

collect_output(Python, Args) ->
    Port = open_port({spawn_executable, Python}, [
        {args, [to_charlist(Arg) || Arg <- Args]},
        binary,
        exit_status,
        stderr_to_stdout,
        use_stdio
    ]),
    collect_loop(Port, []).

collect_loop(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_loop(Port, [Data | Acc]);
        {Port, {exit_status, 0}} ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, _}} ->
            Output = iolist_to_binary(lists:reverse(Acc)),
            Reason = case string:trim(Output) of
                <<>> -> <<"ESP32 helper failed.">>;
                Trimmed -> Trimmed
            end,
            {error, Reason}
    end.

run_streaming(Python, Args) ->
    Port = open_port({spawn_executable, Python}, [
        {args, [to_charlist(Arg) || Arg <- Args]},
        binary,
        exit_status,
        stderr_to_stdout,
        use_stdio
    ]),
    monitor_loop(Port).

monitor_loop(Port) ->
    receive
        {Port, {data, Data}} ->
            io:put_chars(Data),
            monitor_loop(Port);
        {Port, {exit_status, 0}} ->
            {ok, nil};
        {Port, {exit_status, _}} ->
            {error, <<>>}
    end.

to_charlist(Value) when is_binary(Value) -> binary_to_list(Value);
to_charlist(Value) when is_list(Value) -> Value.

interpreter() ->
    case os:find_executable("esptool") of
        false -> python3();
        Esptool ->
            case shebang(Esptool) of
                {ok, Program} -> {ok, Program};
                error -> python3()
            end
    end.

python3() ->
    case os:find_executable("python3") of
        false -> {error, <<"Cannot find esptool or python3.">>};
        Python -> {ok, Python}
    end.

shebang(Path) ->
    case file:open(Path, [read, binary]) of
        {ok, File} ->
            Line = io:get_line(File, ""),
            ok = file:close(File),
            parse_shebang(Line);
        {error, _} -> error
    end.

parse_shebang(<<"#!", Rest/binary>>) ->
    Line = string:trim(first_line(Rest)),
    case string:split(Line, " ", all) of
        [<<"/usr/bin/env">>, Program | _] ->
            case os:find_executable(binary_to_list(Program)) of
                false -> error;
                Found -> {ok, Found}
            end;
        [Program | _] -> {ok, binary_to_list(Program)};
        _ -> error
    end;
parse_shebang(_) -> error.

first_line(Bin) ->
    case binary:split(Bin, <<"\n">>) of
        [Line | _] -> Line;
        _ -> Bin
    end.

%% Scripts live in this package. `gleam run` from the orbital repo finds them
%% at the project root; a dependent project finds copies under build/packages.
priv_script(Name) ->
    case code:which(orbital_ffi) of
        non_existing ->
            {error, <<"Cannot find priv/", Name/binary, ".">>};
        Beam ->
            Absolute = filename:absname(Beam),
            Build = lists:foldl(
                fun(_, Path) -> filename:dirname(Path) end,
                Absolute,
                lists:seq(1, 5)
            ),
            Root = filename:dirname(Build),
            first_regular([
                filename:join(Root, filename:join("priv", binary_to_list(Name))),
                filename:join([Build, "packages", "orbital", "priv", binary_to_list(Name)])
            ], Name)
    end.

first_regular([], Name) ->
    {error, <<"Cannot find priv/", Name/binary, ".">>};
first_regular([Path | Rest], Name) ->
    case filelib:is_regular(Path) of
        true -> {ok, Path};
        false -> first_regular(Rest, Name)
    end.

-spec unsafe_characters_to_list(Name :: binary()) -> string().
unsafe_characters_to_list(Name) ->
    case unicode:characters_to_list(Name) of
        Result when is_list(Result) -> Result;
        Error -> throw({unsafe_characters_to_list, Error})
    end.

-spec unsafe_characters_to_binary(Name :: string()) -> binary().
unsafe_characters_to_binary(Name) ->
    case unicode:characters_to_binary(Name) of
        Result when is_binary(Result) -> Result;
        Error -> throw({unsafe_characters_to_binary, Error})
    end.
