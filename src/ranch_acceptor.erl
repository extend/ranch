%% Copyright (c) 2011-2012, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

%% @private
-module(ranch_acceptor).

%% API.
-export([start_link/4]).

%% Internal.
-export([loop/3]).

%% API.

-spec start_link(any(), inet:socket(), module(), pid())
	-> {ok, pid()}.
start_link(Ref, LSocket, Transport, ConnsSup) ->
	Pid = spawn_link(?MODULE, loop, [LSocket, Transport, ConnsSup]),
	ok = ranch_server:add_acceptor(Ref, Pid),
	{ok, Pid}.

%% Internal.

-spec loop(inet:socket(), module(), pid()) -> no_return().
loop(LSocket, Transport, ConnsSup) ->
	_ = case Transport:accept(LSocket, infinity) of
		{ok, CSocket} ->
			Transport:controlling_process(CSocket, ConnsSup),
			%% This call will not return until process has been started
			%% AND we are below the maximum number of connections.
			ranch_conns_sup:start_protocol(ConnsSup, CSocket);
		%% We want to crash if the listening socket got closed.
		{error, Reason} when Reason =/= closed ->
			ok
	end,
	?MODULE:loop(LSocket, Transport, ConnsSup).
