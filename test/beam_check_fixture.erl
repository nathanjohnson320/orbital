-module(beam_check_fixture).

-compile({no_inline, [do_reverse/1]}).

-export([capture/0, closure/0, reverse/1]).

capture() ->
    fun lists:reverse/1.

closure() ->
    fun() -> lists:reverse([]) end.

reverse(List) ->
    do_reverse(List).

do_reverse(List) ->
    lists:reverse(List).
