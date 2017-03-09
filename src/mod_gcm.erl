%% Google Cloud Messaging for Ejabberd
%% Created: 02/08/2015 by mrDoctorWho
%% License: MIT/X11

-module(mod_gcm).
-author("mrDoctorWho").

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").

-behaviour(gen_mod).

-record(gcm_users, {user, gcm_key, last_seen}).


-define(NS_GCM, "https://gcm-http.googleapis.com/gcm"). %% I hope Google doesn't mind.
-define(GCM_URL, ?NS_GCM ++ "/send").
-define(CONTENT_TYPE, "application/json").


-export([start/2, stop/1, message/3, iq/3]).

%% 114196@stackoverflow
-spec(url_encode(string()) -> string()).

escape_uri(S) when is_list(S) ->
    escape_uri(unicode:characters_to_binary(S));
escape_uri(<<C:8, Cs/binary>>) when C >= $a, C =< $z ->
    [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C >= $A, C =< $Z ->
    [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C >= $0, C =< $9 ->
    [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C == $. ->
    [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C == $- ->
    [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C == $_ ->
    [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) ->
    escape_byte(C) ++ escape_uri(Cs);
escape_uri(<<>>) ->
    "".

escape_byte(C) ->
    "%" ++ hex_octet(C).

hex_octet(N) when N =< 9 ->
    [$0 + N];
hex_octet(N) when N > 15 ->
    hex_octet(N bsr 4) ++ hex_octet(N band 15);
hex_octet(N) ->
    [N - 10 + $a].


url_encode(Data) ->
    url_encode(Data,"").

url_encode([],Acc) ->
    Acc;
url_encode([{Key,Value}|R],"") ->
    url_encode(R, escape_uri(Key) ++ "=" ++ escape_uri(Value));
url_encode([{Key,Value}|R],Acc) ->
    url_encode(R, Acc ++ "&" ++ escape_uri(Key) ++ "=" ++ escape_uri(Value)).


%% Send an HTTP request to Google APIs and handle the response
send(JSON, API_KEY) ->
	Header = [{"Authorization", url_encode([{"key", API_KEY}])}],
	Body = iolist_to_binary(mochijson2:encode(JSON)),
	ssl:start(),
	application:start(inets),
	{ok, RawResponse} = httpc:request(post, {?GCM_URL, Header, ?CONTENT_TYPE, Body}, [], []),
	%% {{"HTTP/1.1",200,"OK"} ..}
	{{_, SCode, Status}, ResponseBody} = {element(1, RawResponse), element(3, RawResponse)},
	%% TODO: Errors 5xx
	case catch SCode of
		200 -> ?DEBUG("mod_gcm: A message was sent: ~s", [Body]);
		401 -> ?ERROR_MSG("mod_gcm: ~s", [Status]);
		_ -> ?ERROR_MSG("mod_gcm: ~s", [ResponseBody])
	end.

%% TODO: Define some kind of a shaper to prevent floods and the GCM API to burn out :/
%% Or this could be the limits, like 10 messages/user, 10 messages/hour, etc
message(From, To, Packet) ->
	Type = fxml:get_tag_attr_s(<<"type">>, Packet),
	?INFO_MSG("Offline message ~s", [From]),
	case catch Type of 
		"normal" -> ok;
		_ ->
			%% Strings
			JFrom = jlib:jid_to_string(From#jid{user = From#jid.user, server = From#jid.server, resource = <<"">>}),
			JTo = jlib:jid_to_string(To#jid{user = To#jid.user, server = To#jid.server, resource = <<"">>}),
			ToUser = To#jid.user,
			ToServer = To#jid.server,

			Body = fxml:get_path_s(Packet, [{elem, <<"body">>}, cdata]),

			%% Checking subscription
			{Subscription, _Groups} = 
				ejabberd_hooks:run_fold(roster_get_jid_info, ToServer, {none, []}, [ToUser, ToServer, From]),
				case catch Body of
					<<>> -> ok; %% There is no body
					_ ->
						Result = mnesia:dirty_read(gcm_users, {ToUser, ToServer}),
						case catch Result of 
							[] -> ?DEBUG("mod_gcm: No such record found for ~s", [JTo]);
							[#gcm_users{gcm_key = API_KEY}] ->
								Args = {struct, [{to, API_KEY}, {priority, high}, {data, {struct, [{title, JFrom},{body, Body}]}}]},
								send(Args, ejabberd_config:get_global_option(gcm_api_key, fun(V) -> V end))
						end
					end;
				_ -> ok
	end.


iq(#jid{user = User, server = Server} = From, To, #iq{type = Type, sub_el = SubEl} = IQ) ->
	LUser = jlib:nodeprep(User),
	LServer = jlib:nameprep(Server),

	{MegaSecs, Secs, _MicroSecs} = now(),
	TimeStamp = MegaSecs * 1000000 + Secs,

	API_KEY = fxml:get_tag_cdata(fxml:get_subtag(SubEl, <<"key">>)),

	F = fun() -> mnesia:write(#gcm_users{user={LUser, LServer}, gcm_key=API_KEY, last_seen=TimeStamp}) end,

	case catch mnesia:dirty_read(gcm_users, {LUser, LServer}) of
		[] ->
			mnesia:transaction(F),
			?DEBUG("mod_gcm: New user registered ~s@~s", [LUser, LServer]);

		%% Record exists, the key is equal to the one we know
		[#gcm_users{user={LUser, LServer}, gcm_key=API_KEY}] ->
			mnesia:transaction(F),
			?DEBUG("mod_gcm: Updating last_seen for user ~s@~s", [LUser, LServer]);

		%% Record for this key was found, but for another key
		[#gcm_users{user={LUser, LServer}, gcm_key=_KEY}] ->
			mnesia:transaction(F),
			?DEBUG("mod_gcm: Updating gcm_key for user ~s@~s", [LUser, LServer])
		end,
	
	IQ#iq{type=result, sub_el=[]}. %% We don't need the result, but the handler have to send something.


start(Host, Opts) -> 
	mnesia:create_table(gcm_users, [{disc_copies, [node()]}, {attributes, record_info(fields, gcm_users)}]),
	case catch ejabberd_config:get_global_option(gcm_api_key, fun(V) -> V end) of
		undefined -> ?ERROR_MSG("There is no API_KEY set! The GCM module won't work without the KEY!", []);
		_ ->
			gen_iq_handler:add_iq_handler(ejabberd_local, Host, <<?NS_GCM>>, ?MODULE, iq, no_queue),
			ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, message, 49),
			?INFO_MSG("mod_gcm Has started successfully!", []),
			ok
		end.



stop(Host) -> ok.
