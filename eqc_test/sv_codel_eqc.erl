-module(sv_codel_eqc).

-compile([export_all]).

-include_lib("eqc/include/eqc.hrl").

-record(model,
    { t = 30000, st }).

g_sv_codel_args() ->
    ?LET(T, choose(5, 50),
       [T, choose(T, 200)]).

g_cmd_advance_time(M) ->
    {call, ?MODULE, advance_time, [M, g_time_advance()]}.

g_time_advance() ->
    choose(1, 1000).
   

g_model(0) ->
	oneof([{call, ?MODULE, new, g_sv_codel_args()}]);
g_model(N) ->
	frequency([
		{1, g_model(0)},
		{N,
		 ?LAZY(?LETSHRINK([M], [g_model(N-1)],
		     g_cmd_advance_time(M)))},
		{N,
		 ?LAZY(?LETSHRINK([M], [g_model(N-1)],
		     {call, ?MODULE, enqueue, [M]}))},
		{N,
		 ?LAZY(?LETSHRINK([M], [g_model(N-1)],
		     {call, ?MODULE, dequeue, [M]}))}]).

g_model() ->
    ?SIZED(Size, g_model(Size)).

%% Properties
%% ----------------------------------------------

%% Verify that the queue runs if we blindly execute it
xprop_termination() ->
    ?FORALL(M, g_model(),
    	begin
    		_R = eval(M),
    		cleanup(M),
    		true
    	end).

%% Various observations on a CoDel queue
prop_observations() ->
    ?FORALL(M, g_model(),
	begin
            #model { t = T, st = ST} = Res = eval(M),
            R = sv_codel:dequeue({T+1, erlang:unique_integer()}, ST),
            cleanup(Res),
            case R of
                {empty, _Dropped, EmptyState} ->
                    verify_empty(EmptyState);
                {drop, [_Pkt], _CoDelState} ->
                    classify(true, start_drop, true);
                {_Pkt, [_ | _], CoDelState} ->
                    verify_dropped(CoDelState);
                {_Pkt, _Dropped, _SomeState} ->
                    classify(true, dequeue, true)
             end
        	end).


verify_dropped(_CoDelState) ->
    %% We dropped packets, our state must be dropping
    classify(true, dropped, true).

verify_empty(EmptyState) ->
    %% Empty queues are never dropping and they reset first-above-time
    PL = sv_codel:qstate(EmptyState),
    classify(true, empty_queue,
        case proplists:get_value(dropping, PL) of
            false ->
                case proplists:get_value(first_above_time, PL) of
                   0 -> true;
                   K -> {error, {fat_not_zero, K, PL}}
                 end;
            true ->
                {error, {empty_and_dropping, PL}}
        end).

%% Operations
%% ----------------------------------------------

cleanup(#model { st = ST }) ->
    sv_codel:delete(ST).

new(Target, Interval) ->
	#model { t = 0, st = sv_codel:init(Target, Interval) }.

advance_time(#model { t = T } = State, K) ->
    State#model { t = T + K  }.

enqueue(#model { t = T, st = ST } = State) ->
    TS = {T, erlang:unique_integer()},
    State#model { t = T+1, st = sv_codel:enqueue({pkt, TS}, TS, ST) }.
	
dequeue(#model { t = T, st = ST } = State) ->
    TS = {T, erlang:unique_integer()},
    ST2 =
    	case sv_codel:dequeue(TS, ST) of
    	    {_, _, S} -> S
    	end,
    State#model { t = T+1, st = ST2 }.
