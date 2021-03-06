-module(minidote_server).
-behavior(gen_server).


%% API
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2, code_change/3, read_objects/3, update_objects/3, stop/1, start_link/1]).

-export_type([key/0]).

-record(finish_update_objects, {from, new_crdt_state_map}).

-type key() :: {Key :: binary(), Type :: antidote_crdt:typ(), Bucket :: binary()}.
-type from() :: {pid(), Tag :: term()}.

-record(state, {
  crdt_states = #{} :: maps:map(minidote:key(), antidote_crdt:crdt()),
  vc = vectorclock:new() :: vectorclock:clock(),
  self :: node(),
  causal_broadcast :: pid(),
  waiting_requests = #{} :: maps:map(node(), priority_queue:pq({non_neg_integer(), from(), request()})),
  locks = #{} :: maps:map(key(), boolean()),
  locks_waiting = #{} :: maps:map(node(), queue:queue({from(), request()}))
}).

-record(downstream, {
  sender :: node(),
  new_vc :: vectorclock:vectorclock(),
  new_effects :: [{minidote:key(), [antidote_crdt:effect()]}]
}).

-record(read_objects, {
  keys :: [key()],
  clock :: vectorclock:vectorclock()
}).

-record(update_objects, {
  updates :: [{key(), Op :: atom(), Args :: any()}],
  clock :: vectorclock:vectorclock()
}).

-type request() :: #read_objects{} | #update_objects{}.
-type server() :: pid() | atom().

-spec start_link(atom()) -> {ok, server()} | ignore | {error, Error :: any()}.
start_link(ServerName) ->
  gen_server:start_link({local, ServerName}, ?MODULE, [], []).

stop(Pid) ->
  gen_server:stop(Pid).

-spec read_objects(server(), [key()], vectorclock:vectorclock()) ->
  {ok, [any()], vectorclock:vectorclock()}
  | {error, any()}.
read_objects(Server, Objects, Clock) ->
  gen_server:call(Server, #read_objects{keys = Objects, clock = Clock}).

-spec update_objects(server(), [{key(), Op :: atom(), Args :: any()}], vectorclock:vectorclock()) ->
  {ok, vectorclock:vectorclock()}
  | {error, any()}.
update_objects(Server, Updates, Clock) ->
  case Clock of ignore -> ok; X when is_map(X) -> ok; _ -> throw({not_a_valid_clock, Clock}) end,
  gen_server:call(Server, #update_objects{updates = Updates, clock = Clock}, 4000).





init(_Args) ->
  gen_server:cast(self(), init),
  LogServer = minidote_op_log,
  {ok, Broadcast} = minidote_logged_causal_broadcast:start_link(self(), LogServer),
  {ok, Self} = minidote_logged_causal_broadcast:this_node(Broadcast),
  CrdtStates = maps:new(),
  {ok, #state{causal_broadcast = Broadcast, self = Self, crdt_states = CrdtStates}}.

handle_call(#update_objects{} = Req, From, State) ->
  NewState = handle_update_objects(Req, From, State),
  {noreply, NewState};
handle_call(#read_objects{} = Req, From, State) ->
  NewState = handle_read_objects(Req, From, State),
  {noreply, NewState};
handle_call(Req={deliver, #downstream{sender = _Sender, new_vc = Vc, new_effects = Effects}}, From, State) ->
  %% receiving downstream effects from other servers
  %% apply the effects to the current state
  Objects = [Obj || {Obj, _} <- Effects],
  NewState = handle_request_wih_dependency_clock(Req, From, State, ignore, Objects, fun(State) ->
    deliver_downstream(State, Vc, Effects)
  end),
  check_waiting_requests(NewState),
  {noreply, NewState};
handle_call(_Request, _From, _State) ->
  erlang:error(not_implemented).

handle_cast(#finish_update_objects{from = From, new_crdt_state_map = NewCrdtStatesMap}, State) ->
  Self = State#state.self,
  NewVc = vectorclock:increment(State#state.vc, Self),
  Keys = maps:keys(NewCrdtStatesMap),
  NewState = State#state{
    vc          = NewVc,
    crdt_states = maps:merge(State#state.crdt_states, NewCrdtStatesMap),
    % release locks
    locks       = maps:without(Keys, State#state.locks)
  },
  gen_server:reply(From, {ok, NewVc}),
  check_locks_waiting(NewState, Keys),
  check_waiting_requests(NewState),
  {noreply, NewState};
handle_cast(init, State) ->
  {noreply, handle_recover(State)};
handle_cast(_Request, _State) ->
  erlang:error(not_implemented).


handle_info(Req={deliver, #downstream{sender = _Sender, new_vc = Vc, new_effects = Effects}}, State) ->
  handle_call(Req, undef, State);
handle_info({handle_waiting, P}, State) ->
  Waiting = maps:get(P, State#state.waiting_requests, priority_queue:new()),
  case priority_queue:out(Waiting) of
    {{value, {_V, From, Req}}, NewQ} ->
      Waiting2 = case priority_queue:is_empty(NewQ) of
        true ->
          maps:remove(P, State#state.waiting_requests);
        false ->
          maps:put(P, NewQ, State#state.waiting_requests)
      end,
      State2 = State#state{waiting_requests = Waiting2},
      handle_call(Req, From, State2);
    {empty, _} ->
      {noreply, State}
  end;
handle_info({handle_release_lock, Key}, State) ->
  case maps:get(Key, State#state.locks, false) of
    true ->
      % lock acquired by someone else
      {noreply, State};
    false ->
      Waiting = maps:get(Key, State#state.locks_waiting, priority_queue:new()),
      case queue:out(Waiting) of
        {{value, {From, Req}}, NewQ} ->
          Waiting2 = case queue:is_empty(NewQ) of
            true ->
              maps:remove(Key, State#state.locks_waiting);
            false ->
              maps:put(Key, NewQ, State#state.locks_waiting)
          end,
          State2 = State#state{locks_waiting = Waiting2},
          handle_call(Req, From, State2);
        {empty, _} ->
          {noreply, State}
      end
  end;
handle_info(log_recovery_done, State) ->
  {noreply, State};
handle_info(Request, _State) ->
  erlang:error({not_implemented, Request}).

deliver_downstream(State, Vc, Effects) ->
  NewVc = vectorclock:merge(State#state.vc, Vc),
  NewCrdtStatesMap = maps:from_list([apply_effects(State, Key, Effs) || {Key, Effs} <- Effects]),
  State#state{
    vc          = NewVc,
    crdt_states = maps:merge(State#state.crdt_states, NewCrdtStatesMap)
  }.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

terminate(_Reason, State) ->
  minidote_logged_causal_broadcast:stop(State#state.causal_broadcast),
  ok.

crdt_state(BoundObj, State) ->
  case maps:find(BoundObj, State#state.crdt_states) of
    {ok, S} ->
      S;
    error ->
      {_Key, CrdtType, _Bucket} = BoundObj,
      antidote_crdt:new(CrdtType)
  end.

apply_effects(State, BoundObj, Effects) ->
  {_Key, CrdtType, _Bucket} = BoundObj,
  CrdtState = crdt_state(BoundObj, State),
  NewCrdtState = lists:foldl(fun(Effect, S) ->
    {ok, S2} = antidote_crdt:update(CrdtType, Effect, S),
    S2
  end, CrdtState, Effects),
  {BoundObj, NewCrdtState}.


perform_updates(CrdtState, Updates) ->
  {S, Effs} = lists:foldl(fun({BoundObj, Op, Args}, {S, Effs}) ->
    {_Key, CrdtType, _Bucket} = BoundObj,
    true = antidote_crdt:is_type(CrdtType),
    Update = {Op, Args},
    {ok, Effect} = antidote_crdt:downstream(CrdtType, Update, S),
    {ok, NewCrdtState} = antidote_crdt:update(CrdtType, Effect, S),
    {NewCrdtState, [Effect | Effs]}
  end, {CrdtState, []}, Updates),
  {S, lists:reverse(Effs)}.

state_to_value({BoundObj, CrdtState}) ->
  {_Key, CrdtType, _Bucket} = BoundObj,
  Value = antidote_crdt:value(CrdtType, CrdtState),
  {BoundObj, Value}.

% checks if Clock <= State.vs
% if yes, calls handler
% if no, add the request to the waiting requests and calls it again later
handle_request_wih_dependency_clock(Req, From, State, Clock, KeysToLock, Handler) ->
  case Clock == ignore orelse vectorclock:leq_extra(Clock, State#state.vc) of
    true ->
      case lists:filter(fun(K) -> maps:get(K, State#state.locks, false) end, KeysToLock) of
        [Key | _] ->
          % add request to waiting requests of first key
          LocksWaiting = State#state.locks_waiting,
          KeyWaiting = maps:get(Key, LocksWaiting, queue:new()),
          KeyWaiting2 = queue:in({From, Req}, KeyWaiting),
          LocksWaiting2 = maps:put(Key, KeyWaiting2, LocksWaiting),
          State#state{locks_waiting = LocksWaiting2};
        [] ->
          % no current locks on used keys, can handle request directly
          Handler(State)
      end;
    {false, P, V} ->
      % add to pending
      WaitingRequests = State#state.waiting_requests,
      PWaiting = maps:get(P, WaitingRequests, priority_queue:new()),
      PWaiting2 = priority_queue:in({V, From, Req}, PWaiting),
      NewWaitingRequests = maps:put(P, PWaiting2, WaitingRequests),
      State#state{waiting_requests = NewWaitingRequests}
  end.

handle_read_objects(#read_objects{keys = Objects, clock = Clock} = Req, From, State1) ->
  handle_request_wih_dependency_clock(Req, From, State1, Clock, [], fun(State) ->
    CrdtStates = [{K, crdt_state(K, State)} || K <- Objects],
    Vc = State#state.vc,
    spawn_link(fun() ->
      Results = list_utils:pmap(fun state_to_value/1, CrdtStates),
      gen_server:reply(From, {ok, Results, Vc})
    end),
    State
  end).


handle_update_objects(#update_objects{updates = Updates, clock = Clock} = Req, From, State1) ->
  Objects = [O || {O, _, _} <- Updates],
  handle_request_wih_dependency_clock(Req, From, State1, Clock, Objects, fun(State) ->
    ThisServer = self(),
    CausalBroadcast = State#state.causal_broadcast,
    Self = State#state.self,
    UpdatesByKey = list_utils:group_by(fun({K, _, _}) -> K end, Updates),
    Keys = maps:keys(UpdatesByKey),
    UpdatesByKeyWithState = [{K, crdt_state(K, State), Upds} || {K, Upds} <- maps:to_list(UpdatesByKey)],
    % use concurrency below so the server is not blocked for the whole update
    % We use locks on keys to make it still safe
    spawn_link(fun() ->
      % calculate new crdt states
      EffectsAndStates = list_utils:pmap(fun({Key, S, Upds}) ->
        {Key, perform_updates(S, Upds)} end, UpdatesByKeyWithState),
      NewCrdtStates = [{K, S} || {K, {S, _}} <- EffectsAndStates],
      NewEffects = [{K, Effs} || {K, {_, Effs}} <- EffectsAndStates],
      NewCrdtStatesMap = maps:from_list(NewCrdtStates),
      % might not be the latest new VC because of concurrent processes, but good estimate
      NewVc = vectorclock:increment(State#state.vc, Self),
      minidote_logged_causal_broadcast:broadcast(CausalBroadcast, #downstream{sender = Self, new_vc = NewVc, new_effects = NewEffects}),
      gen_server:cast(ThisServer, #finish_update_objects{from = From, new_crdt_state_map = NewCrdtStatesMap})
    end),
    State#state{
      % acquire locks
      locks = maps:merge(State#state.locks, maps:from_list([{K, true} || K <- Keys]))
    }
  end).

% check processes waiting for a Clock
check_waiting_requests(State) ->
  maps:fold(fun(P, Queue, _) ->
    case priority_queue:peek(Queue) of
      {value, {V, _, _}} ->
        case vectorclock:get(State#state.vc, P) >= V of
          true ->
            self() ! {handle_waiting, P};
          false ->
            ok
        end;
      _ ->
        ok
    end
  end, ok, State#state.waiting_requests).

% check processes waiting for locks
check_locks_waiting(State, Keys) ->
  lists:foreach(fun(Key) ->
    case maps:is_key(Key, State#state.locks_waiting) of
      true ->
        self() ! {handle_release_lock, Key};
      false ->
        ok
    end
  end, Keys).

handle_recover(State) ->
  receive
    {deliver, #downstream{sender = _Sender, new_vc = Vc, new_effects = Effects}} ->
      State2 = deliver_downstream(State, Vc, Effects),
      handle_recover(State2);
    log_recovery_done ->
      State
  after 10000 ->
    throw(timeout_in_recovery)
  end.
