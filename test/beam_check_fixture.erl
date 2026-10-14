-module(beam_check_fixture).

-compile({no_inline, [do_reverse/1]}).

-export([closure/0, reverse/1]).

closure() ->
    fun() -> lists:reverse([]) end.

reverse(List) ->
    do_reverse(List).

do_reverse(List) ->
    lists:reverse(List).
