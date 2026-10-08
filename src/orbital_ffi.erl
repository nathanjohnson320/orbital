-module(orbital_ffi).

-export([
    packbeam_create/3,
    packbeam_list/1,
    run_executable/3,
    run_streaming_executable/3,
    find_executable/1,
    run_named_executable/2,
    confirm/1,
    zip_list/1,
    zip_get/2,
    uf2create/4,
    os_family/0,
    wildcard/1
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

%% Like run_executable/3, but streams stdout/stderr to the console as it arrives
%% (used for `orbital flash wasm` under Node).
-spec run_streaming_executable(
    Name :: binary(),
    Directory :: binary(),
    Arguments :: list(binary())
) -> {ok, integer()} | {error, nil}.
run_streaming_executable(Name, Directory, Arguments) ->
    try
        StringName = unsafe_characters_to_list(Name),
        Port = erlang:open_port({spawn_executable, StringName},
            [
                {args, [to_charlist(Arg) || Arg <- Arguments]},
                {cd, unsafe_characters_to_list(Directory)},
                binary,
                exit_status,
                stderr_to_stdout,
                use_stdio
            ]
        ),
        streaming_loop(Port)
    catch
        error:_ -> {error, nil}
    end.

streaming_loop(Port) ->
    receive
        {Port, {data, Data}} ->
            io:put_chars(Data),
            streaming_loop(Port);
        {Port, {exit_status, Code}} ->
            {ok, Code}
    end.

-spec find_executable(Name :: binary()) -> {ok, binary()} | {error, nil}.
find_executable(Name) ->
    case os:find_executable(unsafe_characters_to_list(Name)) of
        false -> {error, nil};
        Path -> {ok, unsafe_characters_to_binary(Path)}
    end.

%% Run an executable by PATH name or absolute path (used for picotool).
-spec run_named_executable(Name :: binary(), Arguments :: list(binary())) ->
    {ok, integer()} | {error, nil}.
run_named_executable(Name, Arguments) ->
    case find_executable(Name) of
        {ok, Path} -> run_executable(Path, <<".">>, Arguments);
        {error, nil} ->
            %% Absolute / relative path not necessarily on PATH.
            case filelib:is_regular(unsafe_characters_to_list(Name)) of
                true -> run_executable(Name, <<".">>, Arguments);
                false -> {error, nil}
            end
    end.

%% Create a UF2 from an AVM via uf2tool (same dependency ExAtomVM uses).
-spec uf2create(
    OutputPath :: binary(),
    Family :: binary(),
    StartAddr :: integer(),
    ImagePath :: binary()
) -> {ok, nil} | {error, binary()}.
uf2create(OutputPath, Family, StartAddr, ImagePath) ->
    case family_atom(Family) of
        error -> {error, <<"unsupported family_id">>};
        Fam ->
            try uf2tool:uf2create(
                    unicode:characters_to_list(OutputPath),
                    Fam,
                    StartAddr,
                    unicode:characters_to_list(ImagePath)
                )
            of
                ok -> {ok, nil}
            catch
                error:Reason -> {error, format_reason(Reason)};
                throw:Reason -> {error, format_reason(Reason)};
                exit:Reason -> {error, format_reason(Reason)}
            end
    end.

family_atom(<<"rp2040">>) -> rp2040;
family_atom(<<"rp2350_riscv">>) -> rp2350_riscv;
family_atom(<<"rp2350_arm_s">>) -> rp2350_arm_s;
family_atom(<<"rp2350_arm_ns">>) -> rp2350_arm_ns;
family_atom(<<"absolute">>) -> absolute;
family_atom(<<"data">>) -> data;
family_atom(<<"universal">>) -> universal;
family_atom(_) -> error.

format_reason(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).

-spec os_family() -> binary().
os_family() ->
    case os:type() of
        {_, linux} -> <<"linux">>;
        {_, darwin} -> <<"darwin">>;
        _ -> <<"other">>
    end.

-spec wildcard(Pattern :: binary()) -> list(binary()).
wildcard(Pattern) ->
    [
        unsafe_characters_to_binary(Path)
     || Path <- filelib:wildcard(unsafe_characters_to_list(Pattern))
    ].

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

%% List member names inside a zip (OTP zip, memory mode).

zip_list(ZipPath) ->
    case zip:zip_open(unsafe_characters_to_list(ZipPath), [memory]) of
        {ok, Handle} ->
            try zip:zip_list_dir(Handle) of
                {ok, Entries} ->
                    Names = [unsafe_characters_to_binary(Name)
                             || {zip_file, Name, _Info, _Comment, _Offset, _CompSize} <- Entries],
                    {ok, Names};
                {error, Reason} ->
                    {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
            after
                zip:zip_close(Handle)
            end;
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

%% Read one zip member into a binary.

zip_get(ZipPath, Member) ->
    case zip:zip_open(unsafe_characters_to_list(ZipPath), [memory]) of
        {ok, Handle} ->
            try zip:zip_get(unsafe_characters_to_list(Member), Handle) of
                {ok, {_Name, Bin}} when is_binary(Bin) -> {ok, Bin};
                {error, Reason} ->
                    {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
            after
                zip:zip_close(Handle)
            end;
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
    end.

to_charlist(Value) when is_binary(Value) -> binary_to_list(Value);
to_charlist(Value) when is_list(Value) -> Value.

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
