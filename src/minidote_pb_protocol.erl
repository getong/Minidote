-module(minidote_pb_protocol).
% This module handles the protocol buffer protocol.
% It provides callbacks used by the ranch library.

-include_lib("antidote_pb_codec/include/antidote_pb.hrl").
-behaviour(ranch_protocol).

-export([start_link/4]).
-export([init/4]).

start_link(Ref, Socket, Transport, Opts) ->
  Pid = spawn_link(?MODULE, init, [Ref, Socket, Transport, Opts]),
  {ok, Pid}.

init(Ref, Socket, Transport, _Opts) ->
  ok = ranch:accept_ack(Ref),
  % Each message starts with 4 byte denoting the length of the
  % package. The setting {packet, 4} tells the socket library
  % to use this encoding (it is one of the builtin protocols of Erlang)
  ok = Transport:setopts(Socket, [{packet, 4}]),
  loop(Socket, Transport).

% Receive-Respond loop for handling connections:
loop(Socket, Transport) ->
  case Transport:recv(Socket, 0, 30000) of
    {ok, Data} ->
      handle(Socket, Transport, Data),
      loop(Socket, Transport);
    {error, closed} ->
      ok = Transport:close(Socket);
    {error, timeout} ->
      lager:info("Socket timed out~n"),
      ok = Transport:close(Socket);
    {error, Reason} ->
      lager:error("Socket error: ~p~n", [Reason]),
      ok = Transport:close(Socket)
  end.


% handles a single request
-spec handle(_Socket, _Transport, binary()) -> ok.
handle(Socket, Transport, Msg) ->
  % A message consists of an 8 bit message code and the actual protocol buffer message:
  <<MsgCode:8, ProtoBufMsg/bits>> = Msg,
  DecodedMessage = antidote_pb_codec:decode_message(antidote_pb_codec:decode_msg(MsgCode, ProtoBufMsg)),
  try
    Response = minidote_pb:process(DecodedMessage),
    PbResponse = antidote_pb_codec:encode_message(Response),
    PbMessage = antidote_pb_codec:encode_msg(PbResponse),
    ok = Transport:send(Socket, PbMessage)
  catch
    ExceptionType:Error ->
      % log errors and reply with error message:
      Stacktrace = erlang:get_stacktrace(),
      lager:error("Error ~p: ~p~nWhen handling request ~p~n~p~n", [ExceptionType, Error, DecodedMessage, Stacktrace]),
      % when formatting the error message, we use a maximum depth of 9001.
      % This should be big enough to include useful information, but avoids sending a lot of data
      MessageStr = erlang:iolist_to_binary(io_lib:format("~P: ~P~n~P", [ExceptionType, 9001, Error, 9001, Stacktrace, 9001])),
      Message = antidote_pb_codec:encode_msg(antidote_pb_codec:encode_message({error_response, {unknown, MessageStr}})),
      ok = Transport:send(Socket, Message),
      ok
  end.
