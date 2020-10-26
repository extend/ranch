%% Copyright (c) 2020, Loïc Hoguin <essen@ninenines.eu>
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

-module(upgrade_SUITE).
-compile(export_all).
-compile(nowarn_export_all).

-import(ct_helper, [doc/1]).

%% ct.

all() ->
	ct_helper:all(?MODULE).

init_per_suite(Config) ->
	case os:type() of
		{win32, nt} ->
			{skip, "This test suite is not currently supported on Windows."};
		_ ->
			do_init_per_suite(Config)
	end.

do_init_per_suite(Config) ->
	%% Remove environment variables inherited from Erlang.mk.
	os:unsetenv("ERLANG_MK_TMP"),
	os:unsetenv("APPS_DIR"),
	os:unsetenv("DEPS_DIR"),
	os:unsetenv("ERL_LIBS"),
	os:unsetenv("CI_ERLANG_MK"),
	%% Ensure we are using the C locale for all os:cmd calls.
	os:putenv("LC_ALL", "C"),
	Config.

end_per_suite(_Config) ->
	ok.

%% Find GNU Make.

do_find_make_cmd() ->
	case os:getenv("MAKE") of
		false ->
			case os:find_executable("gmake") of
				false -> "make";
				Cmd   -> Cmd
			end;
		Cmd ->
			Cmd
	end.

%% Manipulate the release.

do_copy(TestApp0) ->
	TestApp = atom_to_list(TestApp0),
	{ok, CWD} = file:get_cwd(),
	_ = do_exec_log("cp -R " ++ CWD ++ "/../../test/upgrade_test_apps/" ++ TestApp ++ " " ++ CWD),
	Dir = CWD ++ "/" ++ TestApp,
	_ = do_exec_log("sed -i.bak s/\"include \\.\\.\\/\\.\\.\\/erlang.mk\"/\"include ..\\/..\\/..\\/erlang.mk\"/ " ++ Dir ++ "/Makefile"),
	ok.

do_remove(TestApp0) ->
	TestApp = atom_to_list(TestApp0),
	{ok, CWD} = file:get_cwd(),
	_ = do_exec_log("rm -rf " ++ CWD ++ "/" ++ TestApp),
	ok.

do_get_paths(TestApp0) ->
	TestApp = atom_to_list(TestApp0),
	{ok, CWD} = file:get_cwd(),
	Dir = CWD ++ "/" ++ TestApp,
	Rel = Dir ++ "/_rel/" ++ TestApp ++ "/bin/" ++ TestApp,
	Log = Dir ++ "/_rel/" ++ TestApp ++ "/log/erlang.log.1",
	{Dir, Rel, Log}.

do_compile_and_start(TestApp) ->
	Make = do_find_make_cmd(),
	{Dir, Rel, _} = do_get_paths(TestApp),
	_ = do_exec_log(Make ++ " -C " ++ Dir ++ " distclean"),
	%% TERM=dumb disables relx coloring.
	_ = do_exec_log(Make ++ " -C " ++ Dir ++ " TERM=dumb"),
	%% For some reason the release has TestAppStr.boot
	%% while the downgrade expects start.boot?
	TestAppStr = atom_to_list(TestApp),
	_ = do_exec_log("cp "
		++ Dir ++ "/_rel/" ++ TestAppStr
			++ "/releases/1/" ++ TestAppStr ++ ".boot "
		++ Dir ++ "/_rel/" ++ TestAppStr
			++ "/releases/1/start.boot"),
	_ = do_exec_log(Rel ++ " stop"),
	_ = do_exec_log(Rel ++ " start"),
	timer:sleep(2000),
	_ = do_exec_log(Rel ++ " eval 'application:info()'"),
	ok.

do_stop(TestApp) ->
	{Dir, Rel, Log} = do_get_paths(TestApp),
	_ = do_exec_log("sed -i.bak s/\"2\"/\"1\"/ " ++ Dir ++ "/relx.config"),
	_ = do_exec_log(Rel ++ " stop"),
	ct:log("~s~n", [element(2, file:read_file(Log))]).

%% When we are on a tag (git describe --exact-match succeeds),
%% we use the tag before that as a starting point. Otherwise
%% we use the most recent tag.
do_use_ranch_previous(TestApp) ->
	TagsOutput = do_exec_log("git tag | tr - \\~ | sort -V | tr \\~ -"),
	Tags = string:lexemes(TagsOutput, "\n"),
	DescribeOutput = do_exec_log("git describe --exact-match"),
	{CommitOrTag, Prev} = case DescribeOutput of
		"fatal: no tag exactly matches " ++ _ -> {commit, hd(lists:reverse(Tags))};
		_ -> {tag, hd(tl(lists:reverse(Tags)))}
	end,
	do_use_ranch_commit(TestApp, Prev),
	CommitOrTag.

%% Replace the current Ranch commit with the one given as argument.
do_use_ranch_commit(TestApp, Commit) ->
	{Dir, _, _} = do_get_paths(TestApp),
	_ = do_exec_log(
		"sed -i.bak s/\"dep_ranch_commit = .*\"/\"dep_ranch_commit = "
		++ Commit ++ "\"/ " ++ Dir ++ "/Makefile"
	),
	ok.

%% Remove Ranch and rebuild, this time generating a relup.
do_build_relup(TestApp, CommitOrTag) ->
	Make = do_find_make_cmd(),
	{Dir, _, _} = do_get_paths(TestApp),
	_ = do_exec_log("rm -rf " ++ Dir ++ "/deps/ranch/*"),
	_ = do_exec_log("sed -i.bak s/\"1\"/\"2\"/ " ++ Dir ++ "/relx.config"),
	%% We need Ranch to be fetched first in order to copy the current appup
	%% and optionally update its version when we are not on a tag.
	_ = do_exec_log("cp -R "
		++ Dir ++ "/../../../Makefile "
		++ Dir ++ "/../../../erlang.mk "
		++ Dir ++ "/../../../src "
		++ Dir ++ "/deps/ranch/"),
	_ = do_exec_log(Make ++ " -C " ++ Dir ++ " deps"),
	_ = case CommitOrTag of
		tag -> ok;
		commit ->
			%% Force the rebuild of Ranch.
			_ = do_exec_log(Make ++ " -C " ++ Dir ++ "/deps/ranch clean"),
			%% Update the Ranch version so that the upgrade can be applied.
			ProjectVersion = do_exec_log("grep \"PROJECT_VERSION = \" " ++ Dir ++ "/deps/ranch/Makefile"),
			["PROJECT_VERSION = " ++ Vsn0|_] = string:lexemes(ProjectVersion, "\n"),
			[A, B|Tail] = string:lexemes(Vsn0, "."),
			Vsn = binary_to_list(iolist_to_binary([A, $., B, ".9", lists:join($., Tail)])),
			ct:log("Changing Ranch version from ~s to ~s~n", [Vsn0, Vsn]),
			_ = do_exec_log(
				"sed -i.bak s/\"PROJECT_VERSION = .*\"/\"PROJECT_VERSION = " ++ Vsn ++ "\"/ "
					++ Dir ++ "/deps/ranch/Makefile"
			),
			%% The version in the appup must be the same as PROJECT_VERSION.
			_ = do_exec_log(
				"sed -i.bak s/\"" ++ Vsn0 ++ "\"/\"" ++ Vsn ++ "\"/ "
					++ Dir ++ "/deps/ranch/src/ranch.appup"
			)
	end,
	_ = do_exec_log(Make ++ " -C " ++ Dir ++ " relup"),
	ok.

%% Copy the tarball in the correct location and upgrade.
do_upgrade(TestApp) ->
	TestAppStr = atom_to_list(TestApp),
	{Dir, Rel, _} = do_get_paths(TestApp),
	_ = do_exec_log("cp "
		++ Dir ++ "/_rel/" ++ TestAppStr
			++ "/" ++ TestAppStr ++ "-2.tar.gz "
		++ Dir ++ "/_rel/" ++ TestAppStr
			++ "/releases/2/" ++ TestAppStr ++ ".tar.gz"),
	_ = do_exec_log(Rel ++ " upgrade \"2\""),
	_ = do_exec_log(Rel ++ " eval 'application:info()'"),
	ok.

do_downgrade(TestApp) ->
	{_, Rel, _} = do_get_paths(TestApp),
	_ = do_exec_log(Rel ++ " downgrade \"1\""),
	_ = do_exec_log(Rel ++ " eval 'application:info()'"),
	ok.

%% Tests.

keep_connections(_) ->
	doc("Ensure that connections survive upgrading and downgrading."),
	do_upgrade_downgrade_test(keep_connections, tcp_echo).

metrics(_) ->
	doc("Ensure that metrics are created on upgrade and destroyed on downgrade."),
	do_upgrade_downgrade_test(metrics, tcp_echo).

connection_alarms(_) ->
	doc("Ensure that connection count alarms work after upgrading."),
	do_upgrade_downgrade_test(connection_alarms, tcp_echo).

do_upgrade_downgrade_test(Test, App) ->
	try
		%% Copy the example.
		do_copy(App),
		{ok, Config0} = do_init(Test, App),
		%% Build and start the example release using the previous Ranch version.
		CommitOrTag = do_use_ranch_previous(App),
		do_compile_and_start(App),
		%% Update Ranch to master then build a release upgrade.
		do_build_relup(App, CommitOrTag),
		%% Perform the upgrade.
		{ok, Config1} = do_before_upgrade(Test, App, Config0),
		do_upgrade(App),
		{ok, Config2} = do_after_upgrade(Test, App, Config1),
		%% Perform the downgrade.
		{ok, Config3} = do_before_downgrade(Test, App, Config2),
		do_downgrade(App),
		{ok, Config4} = do_after_downgrade(Test, App, Config3),
		ok = do_cleanup(Test, App, Config4),
		ok
	after
		do_stop(App),
		do_remove(App)
	end.

%% @todo upgrade_ranch_max_conn

do_init(_Test, tcp_echo) ->
	{ok, #{port => 5555}};
do_init(_Test, _App) ->
	{ok, #{}}.

do_before_upgrade(keep_connections, _App, Config0) ->
	Port = maps:get(port, Config0),
	%% Establish a connection and check that it works.
	{ok, S} = gen_tcp:connect("localhost", Port, [{active, false}, binary]),
	ok = gen_tcp:send(S, "Hello!"),
	{ok, <<"Hello!">>} = gen_tcp:recv(S, 0, 1000),
	Config1 = maps:update_with(clients, fun (Old) -> [S|Old] end, [S], Config0),
	{ok, Config1};
do_before_upgrade(metrics, App, Config) ->
	AppStr = atom_to_list(App),
	{_, Rel, _} = do_get_paths(App),
	%% Ensure that the metrics key is not present in the ranch:info output.
	"false\n" = do_exec_log(Rel ++ " eval "
		"'maps:is_key(metrics, ranch:info(" ++ AppStr ++ "))'"),
	{ok, Config};
do_before_upgrade(connection_alarms, App, Config) ->
	AppStr = atom_to_list(App),
	{_, Rel, _} = do_get_paths(App),
	%% Ensure that connection alarms cannot be created in the old release.
	"{error,{bad_option,alarms}}\n" = do_exec_log(Rel ++ " eval "
		"'ranch:set_transport_options(" ++ AppStr ++ ", "
		"#{alarms => #{test => {num_connections, #{treshold => 1, "
		"cooldown => 0, callback => fun (_, _, _, _) -> ok end}}}})'"),
	{ok, Config};
do_before_upgrade(_Test, _App, Config) ->
	{ok, Config}.

do_after_upgrade(keep_connections, _App, Config) ->
	Port = maps:get(port, Config),
	Clients = maps:get(clients, Config),
	%% Ensure that connections established before upgrading still work.
	ok = lists:foreach(
		fun (S) ->
			ok = gen_tcp:send(S, "Hello!"),
			{ok, <<"Hello!">>} = gen_tcp:recv(S, 0, 1000)
		end,
		Clients
	),
	%% Check that new connections are still accepted.
	{ok, S} = gen_tcp:connect("localhost", Port, [{active, false}, binary]),
	ok = gen_tcp:send(S, "Hello!"),
	{ok, <<"Hello!">>} = gen_tcp:recv(S, 0, 1000),
	ok = gen_tcp:close(S),
	{ok, Config};
do_after_upgrade(metrics, App, Config) ->
	AppStr = atom_to_list(App),
	Port = maps:get(port, Config),
	{_, Rel, _} = do_get_paths(App),
	%% Ensure that the metrics key is present in the ranch:info output.
	"true\n" = do_exec_log(Rel ++ " eval "
		"'maps:is_key(metrics, ranch:info(" ++ AppStr ++ "))'"),
	%% Ensure that no accepts have been counted yet.
	"0\n" = do_exec_log(Rel ++ " eval "
		"'lists:sum([N || {{conns_sup, _, accept}, N} <- "
		"maps:to_list(maps:get(metrics, ranch:info(" ++ AppStr ++ ")))])'"),
	%% Ensure that no terminates have been counted yet.
	"0\n" = do_exec_log(Rel ++ " eval "
		"'lists:sum([N || {{conns_sup, _, terminate}, N} <- "
		"maps:to_list(maps:get(metrics, ranch:info(" ++ AppStr ++ ")))])'"),
	%% Establish a new connection.
	{ok, S} = gen_tcp:connect("localhost", Port, [{active, false}, binary]),
	ok = gen_tcp:send(S, "Hello!"),
	{ok, <<"Hello!">>} = gen_tcp:recv(S, 0, 1000),
	%% Ensure that the accept has been counted.
	"1\n" = do_exec_log(Rel ++ " eval "
		"'lists:sum([N || {{conns_sup, _, accept}, N} <- "
		"maps:to_list(maps:get(metrics, ranch:info(" ++ AppStr ++ ")))])'"),
	%% Close the socket, ensure that the termination has been counted.
	ok = gen_tcp:close(S),
	"1\n" = do_exec_log(Rel ++ " eval "
		"'lists:sum([N || {{conns_sup, _, terminate}, N} <- "
		"maps:to_list(maps:get(metrics, ranch:info(" ++ AppStr ++ ")))])'"),
	{ok, Config};
do_after_upgrade(connection_alarms, App, Config) ->
	AppStr = atom_to_list(App),
	{_, Rel, _} = do_get_paths(App),
	Port = maps:get(port, Config),
	%% Configure a connection count alarm, to be fired with every new connection.
	"ok\n" = do_exec_log(Rel ++ " eval "
		"'ranch:set_transport_options(" ++ AppStr ++ ", "
		"#{alarms => #{test => {num_connections, #{treshold => 1, "
		"cooldown => 0, callback => fun (Ref, _, _, _) -> persistent_term:put({connection_alarms, Ref}, persistent_term:get({connection_alarms, Ref}, 0)+1) end}}}})'"),
	%% Establish 1 connection, ensure that it raised an alarm.
	{ok, S1} = gen_tcp:connect("localhost", Port, [{active, false}, binary]),
	"1\n" = do_exec_log(Rel ++ " eval 'persistent_term:get({connection_alarms, " ++ AppStr ++ "})'"),
	%% Establish one more connection, ensure that is raised another alarm.
	{ok, S2} = gen_tcp:connect("localhost", Port, [{active, false}, binary]),
	"2\n" = do_exec_log(Rel ++ " eval 'persistent_term:get({connection_alarms, " ++ AppStr ++ "})'"),
%%	"true\n" = do_exec_log(Rel ++ " eval 'persistent_term:erase({connection_alarms, " ++ AppStr ++ "})'"),
	ok = gen_tcp:close(S1),
	ok = gen_tcp:close(S2),
	{ok, Config};
do_after_upgrade(_Test, _App, Config) ->
	{ok, Config}.

do_before_downgrade(connection_alarms, App, Config) ->
	AppStr = atom_to_list(App),
	{_, Rel, _} = do_get_paths(App),
	"true\n" = do_exec_log(Rel ++ " eval 'persistent_term:erase({connection_alarms, " ++ AppStr ++ "})'"),
	{ok, Config};
do_before_downgrade(_Test, _App, Config) ->
	{ok, Config}.

do_after_downgrade(keep_connections, _App, Config) ->
	Port = maps:get(port, Config),
	Clients = maps:get(clients, Config),
	%% Ensure that connections established before downgrading still work.
	ok = lists:foreach(
		fun (S) ->
			ok = gen_tcp:send(S, "Hello!"),
			{ok, <<"Hello!">>} = gen_tcp:recv(S, 0, 1000)
		end,
		Clients
	),
	%% Check that new connections are still accepted.
	{ok, S} = gen_tcp:connect("localhost", Port, [{active, false}, binary]),
	ok = gen_tcp:send(S, "Hello!"),
	{ok, <<"Hello!">>} = gen_tcp:recv(S, 0, 1000),
	ok = gen_tcp:close(S),
	{ok, Config};
do_after_downgrade(metrics, App, Config) ->
	AppStr = atom_to_list(App),
	{_, Rel, _} = do_get_paths(App),
	%% Ensure that the metrics key is not present any more.
	"false\n" = do_exec_log(Rel ++ " eval "
		"'maps:is_key(metrics, ranch:info(" ++ AppStr ++ "))'"),
	{ok, Config};
do_after_downgrade(connection_alarms, App, Config) ->
	AppStr = atom_to_list(App),
	{_, Rel, _} = do_get_paths(App),
	"{error,{bad_option,alarms}}\n" = do_exec_log(Rel ++ " eval "
		"'ranch:set_transport_options(" ++ AppStr ++ ", "
		"#{alarms => #{test => {num_connections, #{treshold => 1, "
		"cooldown => 0, callback => fun (_, _, _, _) -> ok end}}}})'"),
	{ok, Config};
do_after_downgrade(_Test, _App, Config) ->
	{ok, Config}.

do_cleanup(keep_connections, _App, Config) ->
	[ok = gen_tcp:close(S) || S <- maps:get(clients, Config)],
	ok;
do_cleanup(metrics, _App, _Config) ->
	ok;
do_cleanup(_Test, _App, _Config) ->
	ok.

do_exec_log(Cmd) ->
	ct:log("Command: ~s~n", [Cmd]),
	Out=os:cmd(Cmd),
	ct:log("Output:~n~n~s~n", [Out]),
	Out.
