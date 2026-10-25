-module(beam_check_fixture).

-compile({no_inline, [do_reverse/1]}).

-export([capture/0, closure/0, local_capture/0, reverse/1]).

capture() ->
    fun lists:reverse/1.

closure() ->
    fun() -> lists:reverse([]) end.

%% Non-exported fun Mod:Fun/Arity capture (OTP 28 / Gleam 1.19 shape).
local_capture() ->
    fun ?MODULE:do_reverse/1.

reverse(List) ->
    do_reverse(List).

do_reverse(List) ->
    lists:reverse(List).
