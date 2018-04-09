-module(wins_server).

-behaviour(gen_server).

-include("wins_global.hrl").
-include("lager.hrl").

-export([start_link/0]).
-export([log_win/2, log_imp/2, log_click/2, log_conversion/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	terminate/2, code_change/3]).

-record(state, {
	call_ref
}).

-record(brod_produce_reply, {
	call_ref,
	result
}).

%%%%%%%%%%%%%%%%%%%%%%
%%%    API CALLS   %%%
%%%%%%%%%%%%%%%%%%%%%%

start_link() ->
	?INFO("WINS: Started Wins Server client (Pid: ~p)", [self()]),
	gen_server:start_link(?MODULE, [], []).


log_win(WinNotification, Opts) ->
	case try_get_worker() of
		{ok, Worker} ->
			gen_server:call(Worker, {log_win, WinNotification, parse_opts(Opts)});
		E -> E
	end.

log_imp(Imp, Opts) ->
	case try_get_worker() of
		{ok, Worker} ->
			gen_server:call(Worker, {log_imp, Imp, parse_opts(Opts)});
		E -> E
	end.

log_click(Click, Opts) ->
	case try_get_worker() of
		{ok, Worker} ->
			gen_server:call(Worker, {log_click, Click, parse_opts(Opts)});
		E -> E
	end.

log_conversion(Conversion, Opts) ->
	%% TODO
	ok.

%%%%%%%%%%%%%%%%%%%%%%
%%%    CALLBACKS   %%%
%%%%%%%%%%%%%%%%%%%%%%

init([]) ->
	process_flag(trap_exit, true),
	?INFO("WINS SERVER: Win notifications service (pid: ~p) started.", [self()]),
	{ok, #state{}}.

handle_call({log_win, #win{
	bid_id = BidId, cmp = Cmp, crid = Crid, timestamp = TimeStamp, exchange = Exchange, win_price = WinPrice
}, Opts}, _From, State) ->
	Data = #{
		<<"timestamp">> => TimeStamp,            % time stamp (5 mins)
		<<"bid_id">> => BidId,                % id
		<<"cmp">> => Cmp,                        % campaign id
		<<"crid">> => Crid,                        % creative id
		<<"exchange">> => Exchange,                % exchange
		<<"win_price">> => WinPrice                % win price (CPI)
	},
	?INFO("WINS SERVER: Win -> [timestamp: ~p,  cmp: ~p,  crid: ~p,  win_price: $~p,  exchange: ~p,  bid_id: ~p",
		[TimeStamp, Cmp, Crid, WinPrice, Exchange, BidId]),
	log_internal(wins, Data, Opts),
	pooler:return_member(wins_pool, self()),
	{reply, {ok, successful}, State};

handle_call({log_imp, #imp{
	bid_id = BidId, cmp = Cmp, crid = Crid, timestamp = TimeStamp, exchange = Exchange
}, Opts}, _From, State) ->
	Data = #{
		<<"timestamp">> => TimeStamp,           % time stamp (5 mins)
		<<"bid_id">> => BidId,                    % id
		<<"cmp">> => Cmp,                       % campaign id
		<<"crid">> => Crid,                     % creative id
		<<"exchange">> => Exchange              % exchange
	},
	?INFO("WINS SERVER: Imp -> [timestamp: ~p,  cmp: ~p,  crid: ~p,  exchange: ~p,  bid_id: ~p",
		[TimeStamp, Cmp, Crid, Exchange, BidId]),
	log_internal(imps, Data, Opts),
	[{_, CreativeMap} | _] = ets:lookup(creatives, {Cmp, Crid}),
	Ad = case tk_maps:get([<<"class">>], CreativeMap) of
			 <<"html5">> ->
				 Html0 = tk_maps:get([<<"html">>], CreativeMap),
				 ClickTaq = Opts#opts.clicktag,
				 <<Html0/binary, "&ct=", ClickTaq/binary>>;
			 <<"banner">> ->
				 tk_maps:get([<<"path">>], CreativeMap);
			 _ ->
				 ?ERROR("WINS SERVER: Bad creative type [cmp: ~p,  crid: ~p]", [Cmp, Crid]),
				 ok
		 end,
	pooler:return_member(wins_pool, self()),
	{reply, {ok, Ad}, State};

handle_call({log_click, #click{
	bid_id = BidId, cmp = Cmp, crid = Crid, timestamp = TimeStamp, exchange = Exchange
}, Opts}, _From, State) ->
	Data = #{
		<<"timestamp">> => TimeStamp,           % time stamp (5 mins)
		<<"bid_id">> => BidId,                  % id
		<<"cmp">> => Cmp,                       % campaign id
		<<"crid">> => Crid,                     % creative id
		<<"exchange">> => Exchange              % exchange
	},
	?INFO("WINS SERVER: Click -> [timestamp: ~p,  cmp: ~p,  crid: ~p,  exchange: ~p,  bid_id: ~p",
		[TimeStamp, Cmp, Crid, Exchange, BidId]),
			log_internal(clicks, Data, Opts),
	[{_, CreativeMap} | _] = ets:lookup(creatives, {Cmp, Crid}),
	Redirect = tk_maps:get([<<"ctrurl">>], CreativeMap),
	pooler:return_member(wins_pool, self()),
	{reply, {ok, Redirect}, State};

handle_call(_Request, _From, State) ->
	{reply, ok, State}.

handle_cast(_Request, State) ->
	{noreply, State}.

handle_info(#brod_produce_reply{call_ref = _CallRef, result = brod_produce_req_acked}, State) ->
	{noreply, State};
handle_info({'EXIT', _, _}, State) ->
	{stop, shutdown, State}.

terminate(shutdown, _State) ->
	?ERROR("WINS SERVER: Win notifications service (pid: ~p) stopped.", [self()]),
	ok;
terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.


%%%%%%%%%%%%%%%%%%%%%%
%%%    INTERNAL    %%%
%%%%%%%%%%%%%%%%%%%%%%

try_get_worker() ->
	try_get_worker(3).
try_get_worker(0) ->
	{error, no_members_available};
try_get_worker(N) ->
	case pooler:take_member(wins_pool) of
		error_no_members ->
			?WARN("POOLER (~p): No members available! Retrying [1/3]... ", [wins_pool]),
			try_get_worker(N - 1);
		W ->
			{ok, W}
	end.


log_internal(_, _, #opts{test = true}) ->
	ok;
log_internal(Topic, Data, #opts{test = false}) ->
	TopicBin = atom_to_binary(Topic, latin1),
	statsderl:increment(<<TopicBin/binary, ".total">>, 1, 1.0),
	wins_db:insert(Topic, Data),
	rmq:publish(Topic, term_to_binary(Data)).


parse_opts([]) ->
	#opts{};
parse_opts(Opts) ->
	parse_opts(Opts, #opts{}).
parse_opts([], R) ->
	R;
parse_opts([{test, Test} | T], R) ->
	parse_opts(T ,R#opts{test = Test});
parse_opts([{clicktag, ClickTag} | T], R) ->
	parse_opts(T ,R#opts{clicktag = ClickTag}).