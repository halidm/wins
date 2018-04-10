-module(wins_creatives).

-behaviour(gen_server).

-include("wins_global.hrl").
-include("lager.hrl").

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	terminate/2, code_change/3]).

-export([load_cmp_config/1]).


-record(state, {

}).


%%%%%%%%%%%%%%%%%%%%%%
%%%    API CALLS   %%%
%%%%%%%%%%%%%%%%%%%%%%


-spec(start_link() ->
	{ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
	gen_server:start_link(?MODULE, [], []).


%%
%% Takes config as Json, prints it on shell, extracts vital data
%% and writes it to creatives ets table, owned by wins_gs_creative
%%
-spec(load_cmp_config(CmpConfigJson :: string()) -> {ok, success}).
load_cmp_config(CmpConfigJson) ->
	CmpConfig = jsx:decode(CmpConfigJson, [return_maps]),
	get_and_save_creatives(CmpConfig),
	{ok, success}.



%%%%%%%%%%%%%%%%%%%%%%
%%%    CALLBACKS   %%%
%%%%%%%%%%%%%%%%%%%%%%

init([]) ->
	erlang:send_after(200, self(), {init}),
	{ok, #state{}}.


handle_call(_Request, _From, State) ->
	{reply, ok, State}.


handle_cast(_Request, State) ->
	{noreply, State}.


handle_info({init}, State) ->
	ets:new(creatives, [
		set,
		public,
		named_table,
		{read_concurrency, true}
	]),
	{noreply, State};
handle_info(_Info, State) ->
	{noreply, State}.


terminate(_Reason, _State) ->
	ok.


code_change(_OldVsn, State, _Extra) ->
	{ok, State}.



%%%%%%%%%%%%%%%%%%%%%%
%%%    INTERNAL    %%%
%%%%%%%%%%%%%%%%%%%%%%


%% @hidden
%% Takes creatives from Cmp config and inserts them into ets
%%
-spec(get_and_save_creatives(CmpConfig :: map()) -> ok).
get_and_save_creatives(CmpConfig) ->
	Cmp = tk_maps:get([<<"cmp">>], CmpConfig),
	CmpCtrUrl = tk_maps:get([<<"config">>, <<"config">>, <<"ctrurl">>], CmpConfig, undefined),
	CreativeList = tk_maps:get([<<"config">>, <<"creatives">>], CmpConfig, []),
	lists:foreach(
		fun(C) ->
			K = {Cmp, tk_maps:get([<<"crid">>], C)},
			V = #{
				<<"adm">> => tk_maps:get([<<"adm">>], C),
				<<"adm_iframe">> => tk_maps:get([<<"adm_iframe">>], C),
				<<"adm_url">> => tk_maps:get([<<"adm_url">>], C),
				<<"class">> => tk_maps:get([<<"class">>], C),
				<<"h">> => tk_maps:get([<<"h">>], C),
				<<"w">> => tk_maps:get([<<"w">>], C),
				<<"ctrurl">> => get_ctrurl(CmpCtrUrl, tk_maps:get([<<"ctrurl">>], C)),
				<<"path">> => tk_maps:get([<<"path">>], C),
				<<"html">> => tk_maps:get([<<"html">>], C)
			},
			ets:insert(creatives, {K, V})
		end
	, CreativeList),
	ok.


get_ctrurl(CmpCtrUrl, Default) when
	CmpCtrUrl == undefined orelse CmpCtrUrl == <<"">> orelse CmpCtrUrl == null ->
	Default;
get_ctrurl(CmpCtrUrl, _) ->
	CmpCtrUrl.