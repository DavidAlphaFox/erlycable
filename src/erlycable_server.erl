-module(erlycable_server).
-author(palkan).
-behaviour(deliverly_handler).
-include_lib("deliverly/include/deliverly.hrl").
-include_lib("erlycable/include/erlycable.hrl").
-include_lib("erlycable/include/log.hrl").
-include_lib("erlycable/include/priv.hrl").
-include_lib("erlycable/include/anycable_pb.hrl").
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%% Deverly Handler callbacks.
-export([authorize/2, handle_message/2, handle_client_message/2, client_disconnected/1]).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([broadcast/1, broadcast/2, handle_command/3]).

-record(state, {
  clients = #{} ::map(),
  streams = #{} ::map(),
  stream_ids = #{} ::map()
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_) ->
  {ok, #state{}}.

authorize(#de_client{socket = Socket} = Client, _) ->
  case erlycable_rpc:connect(<<"">>, []) of
    {ok, #'ConnectionResponse'{
      status = 'SUCCESS',
      identifiers = Identifiers,
      transmissions = Transmissions
      }
    } -> 
         gen_server:call(?SERVER, {join, Socket}),
         transmit(Client, Transmissions),
         {ok, Client#de_client{data = #{ id => Identifiers }}};
    _ -> {error, auth_error}
  end.

handle_message(_,_) -> ok.

handle_client_message(Client, Msg) -> 
  handle_command(Client, json_encoder:decode(Client, Msg), Msg).

handle_command(#de_client{data = #{ id := Identifiers }} = Client, #{ <<"command">> := <<"subscribe">>, <<"identifier">> := Channel }, Msg) ->
  case erlycable_rpc:subscribe(Identifiers, Channel, <<"">>) of
    {ok, Reply} -> handle_reply(Client, Channel, Reply);
    Else -> Else
  end;

handle_command(#de_client{data = #{ id := Identifiers }} = Client, #{ <<"command">> := <<"unsubscribe">>, <<"identifier">> := Channel }, Msg) ->
  case erlycable_rpc:unsubscribe(Identifiers, Channel) of
    {ok, Reply} -> handle_reply(Client, Channel, Reply);
    Else -> Else
  end;

handle_command(#de_client{data = #{ id := Identifiers }} = Client, #{ <<"command">> := <<"message">>, <<"identifier">> := Channel, <<"data">> := Data}, Msg) ->
  case erlycable_rpc:perform(Identifiers, Channel, Data) of
    {ok, Reply} -> handle_reply(Client, Channel, Reply);
    Else -> Else
  end;

handle_command(_, Data, _) ->
  ?E({unknown_command, Data}),
  ok.

client_disconnected(#de_client{socket = Socket}) ->
  gen_server:cast(?SERVER, {leave, Socket}),
  ok.

%% @doc
%% Broadcast message to all clients (e.g. ping).
%% @end
-spec broadcast(Message::binary()) -> ok.
broadcast(Message) -> 
  gen_server:cast(?SERVER, {broadcast, Message}),
  ok.

%% @doc
%% Broadcast message to specified stream.
%% @end
-spec broadcast(Stream::binary(), Message::binary()) -> ok.
broadcast(Stream, Message) -> 
  gen_server:cast(?SERVER, {broadcast, Stream, Message}),
  ok.

handle_call({join, Socket}, _From, #state{clients = Clients} = State) ->
  {reply, ok, State#state{ clients = Clients#{ Socket => #{ streams => [] } }}};

handle_call({subscribe, Socket, Channel, Stream}, _From, #state{streams = Streams, clients = Clients, stream_ids = StreamIds} = State) ->
  ?I({subscribe, Stream}),
  case maps:get(Socket, Clients, undefined) of
    undefined -> {reply, ok, State};
    #{ streams := ClientStreams } ->
      NewStreams = add_client_to_stream(Streams, Socket, Stream),
      {reply, ok, State#state{
        clients = Clients#{ Socket => #{ streams => [Stream|ClientStreams] }},
        streams = NewStreams,
        stream_ids = add_stream_identifier(StreamIds, Stream, Channel)}
      }
  end;

handle_call({unsubscribe, Socket}, _From, #state{streams = Streams, clients = Clients} = State) ->
  case maps:get(Socket, Clients, undefined) of
    undefined -> {reply, ok, State};
    #{ streams := ClientStreams } ->
      NewStreams = remove_client_from_streams(Streams, Socket, [ClientStreams]),
      {reply, ok, State#state{
        clients = Clients#{ Socket => #{ streams => [] }},
        streams = NewStreams}
      }
  end;

handle_call(_Request, _From, State) ->
  {reply, unknown, State}.

handle_cast({leave, Socket}, #state{clients = Clients, streams = Streams} = State) ->
  case maps:get(Socket, Clients, undefined) of
    undefined -> {noreply, State};
    #{ streams := ClientStreams } ->
      NewStreams = remove_client_from_streams(Streams, Socket, ClientStreams),
      {noreply, #state{clients = maps:remove(Socket, Clients), streams = NewStreams}}
  end;

handle_cast({broadcast, Msg}, #state{clients = Clients} = State) ->
  [Socket ! {handle_message, {text, Msg}} || Socket <- maps:keys(Clients)],
  {noreply, State};

handle_cast({broadcast, Stream, Msg}, #state{streams = Streams, stream_ids = StreamIds} = State) ->
  case maps:get(Stream, Streams, undefined) of
    undefined -> {noreply, State};
    Clients -> 
      Channel = maps:get(Stream, StreamIds),
      ChannelMsg = jsx:encode(#{ identifier => Channel, message => jsx:decode(Msg) }),
      [Socket ! {handle_message, {text, ChannelMsg}} || Socket <- maps:keys(Clients)],
      {noreply, State}
  end;

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
-spec transmit(Client::client(), Transmissions::list()) -> ok.
transmit(#de_client{socket = Socket}, Transmissions) ->
  [Socket ! {handle_message, {text, Msg}} || Msg <- Transmissions],
  ok.

-spec handle_reply(Client::client(), Channel::binary(), Reply::#'CommandResponse'{}) -> ok | {error, Reason::atom()}.
handle_reply(Client, Channel, #'CommandResponse'{status = 'ERROR'}) -> ok;

handle_reply(Client, Channel, #'CommandResponse'{disconnect = true}) ->
  de_client:close(Client),
  ok;

handle_reply(Client, Channel, #'CommandResponse'{stop_streams = StopStreams, streams = Streams, transmissions = Transmissions}) ->
  ?I({reply, Streams, StopStreams, Transmissions}),
  case handle_streams(Client, Channel, StopStreams, Streams) of
    ok -> transmit(Client, Transmissions),
          ok;
    Else -> Else
  end.

-spec handle_streams(Client::client(), Channel::binary(), StopStreams::boolean() | undefined, Streams::list()) -> ok | {error, Reason::atom()}.
handle_streams(#de_client{socket = Socket} = Client, Channel, true, Streams) ->
  gen_server:call(?SERVER, {unsubscribe, Socket}),
  handle_streams(Client, Channel, false, Streams);

handle_streams(_, _, _, []) -> ok;

handle_streams(#de_client{socket = Socket} = Client, Channel, _, [Stream|Streams]) ->
  gen_server:call(?SERVER, {subscribe, Socket, Channel, Stream}),
  handle_streams(Client, Channel, false, Streams).

-spec remove_client_from_streams(Streams::map(), Socket::pid(), ClientStreams::list()) -> NewStreams::map().
remove_client_from_streams(Streams, Socket, []) -> Streams;

remove_client_from_streams(Streams, Socket, [Stream|ClientStreams]) -> 
  case maps:get(Stream, Streams, undefined) of
    undefined -> remove_client_from_streams(Streams, Socket, ClientStreams);
    Clients -> remove_client_from_streams(Streams#{ Stream => maps:remove(Socket, Clients) }, Socket, ClientStreams)
  end.

-spec add_client_to_stream(Streams::map(), Socket::pid(), Stream::binary()) -> NewStreams::map().
add_client_to_stream(Streams, Socket, Stream) -> 
  Clients = maps:get(Stream, Streams, #{}),
  Streams#{ Stream => Clients#{ Socket => 1 } }.

-spec add_stream_identifier(StreamIds::map(), Stream::binary(), Id::binary()) -> NewStreamIds::map().
add_stream_identifier(StreamIds, Stream, Id) ->
  maps:put(Stream, Id, StreamIds).

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

-define(Pid(Id), list_to_pid("<0.0."++integer_to_list(Id)++">")).

remove_client_from_streams_test() ->
  Socket = ?Pid(1),
  Socket2 = ?Pid(2),
  Streams = #{ <<"a">> => #{ Socket => 1 }, <<"b">> => #{ Socket2 => 1, Socket => 1}, <<"c">> => #{ Socket2 => 1 } },
  ?assertEqual(
    #{ <<"a">> => #{}, <<"b">> => #{ Socket2 => 1 }, <<"c">> => #{ Socket2 => 1 } },
    remove_client_from_streams(Streams, Socket, [<<"a">>, <<"b">>])
  ).

add_client_to_stream_test() ->
  Socket = ?Pid(1),
  Socket2 = ?Pid(2),
  Streams = #{ <<"b">> => #{ Socket2 => 1 } },
  ?assertEqual(
    #{ <<"a">> => #{ Socket => 1 }, <<"b">> => #{ Socket2 => 1 } },
    add_client_to_stream(Streams, Socket, <<"a">>)
  ),
  ?assertEqual(
    #{ <<"b">> => #{ Socket2 => 1, Socket => 1 } },
    add_client_to_stream(Streams, Socket, <<"b">>)
  ).

-endif.
