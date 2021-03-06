-module(run_common_test).
-export([ct/0, ct/1,
         ct_quick/0, ct_quick/1,
         ct_cover/0, ct_cover/1,
         cover_summary/0]).

-define(CT_DIR, filename:join([".", "tests"])).
-define(CT_REPORT, filename:join([".", "ct_report"])).
-define(CT_DEF_SPEC, './default.spec').

ct_config_file() ->
    {ok, CWD} = file:get_cwd(),
    filename:join([CWD, "test.config"]).

tests_to_run(TestSpec) ->
    TestSpecFile = atom_to_list(TestSpec),
    [
     {spec, TestSpecFile}
    ].


ct() ->
    ct([?CT_DEF_SPEC]).

ct([TestSpec]) ->
    run_test(tests_to_run(TestSpec)),
    init:stop(0).

ct_quick() ->
    ct_quick([?CT_DEF_SPEC]).

ct_quick([TestSpec]) ->
    run_quick_test(tests_to_run(TestSpec)),
    init:stop(0).

ct_cover() ->
    ct_cover([?CT_DEF_SPEC]).

ct_cover([TestSpec]) ->
    run_ct_cover(TestSpec),
    cover_summary(),
    init:stop(0).

save_count(Test, Configs) ->
    Repeat = case proplists:get_value(repeat, Test) of
        undefined -> 1;
        Other     -> Other
    end,
    Times = case length(Configs) of
        0 -> 1;
        N -> N
    end,
    file:write_file("/tmp/ct_count", integer_to_list(Repeat*Times)).

run_test(Test) ->
    {ok, Props} = file:consult(ct_config_file()),
    case proplists:lookup(ejabberd_configs, Props) of
        {ejabberd_configs, Configs} ->
            Length = length(Configs),
            Names = [Name || {Name,_} <- Configs],
            error_logger:info_msg("Starting test of ~p configurations: ~n~p~n",
                                  [Length, Names]),
            Zip = lists:zip(lists:seq(1, Length), Configs),
            [run_config_test(Config, Test, N, Length) || {N, Config} <- Zip],
            save_count(Test, Configs);
        _ ->
            run_quick_test(Test)
    end.

run_quick_test(Test) ->
    Result = ct:run_test(Test),
    case Result of
        {error, Reason} ->
            throw({ct_error, Reason});
        _ ->
            ok
    end,
    save_count(Test, []).

run_config_test({Name, Variables}, Test, N, Tests) ->
    Node = get_ejabberd_node(),
    {ok, Cwd} = call(Node, file, get_cwd, []),
    Cfg = filename:join([Cwd, "..", "..", "rel", "files", "ejabberd.cfg"]),
    Vars = filename:join([Cwd, "..", "..", "rel", "reltool_vars", "node1_vars.config"]),
    CfgFile = filename:join([Cwd, "etc", "ejabberd.cfg"]),
    {ok, Template} = call(Node, file, read_file, [Cfg]),
    {ok, Default} = call(Node, file, consult, [Vars]),
    NewVars = lists:foldl(fun({Var,Val}, Acc) ->
                    lists:keystore(Var, 1, Acc, {Var,Val})
            end, Default, Variables),
    LTemplate = binary_to_list(Template),
    NewCfgFile = mustache:render(LTemplate, dict:from_list(NewVars)),
    ok = call(Node, file, write_file, [CfgFile, NewCfgFile]),
    call(Node, application, stop, [ejabberd]),
    call(Node, application, start, [ejabberd]),
    error_logger:info_msg("Configuration ~p of ~p: ~p started.~n",
                          [N, Tests, Name]),
    Result = ct:run_test([{label, Name} | Test]),
    case Result of
        {error, Reason} ->
            throw({ct_error, Reason});
        _ ->
            ok
    end.

call(Node, M, F, A) ->
    rpc:call(Node, M, F, A).

run_ct_cover(TestSpec) ->
    prepare(),
    run_test(tests_to_run(TestSpec)),
    N = get_ejabberd_node(),
    Files = rpc:call(N, filelib, wildcard, ["/tmp/ejd_test_run_*.coverdata"]),
    [rpc:call(N, file, delete, [File]) || File <- Files],
    {MS,S,_} = now(),
    FileName = lists:flatten(io_lib:format("/tmp/ejd_test_run_~b~b.coverdata",[MS,S])),
    io:format("export current cover ~p~n", [cover_call(export, [FileName])]),
    io:format("test finished~n").

cover_summary() ->
    prepare(),
    Files = rpc:call(get_ejabberd_node(), filelib, wildcard, ["/tmp/ejd_test_run_*.coverdata"]),
    lists:foreach(fun(F) ->
                          io:format("import ~p cover ~p~n", [F, cover_call(import, [F])])
                  end,
                  Files),
    analyze(summary),
    io:format("summary completed~n"),
    init:stop(0).

prepare() ->
    cover_call(start),
    Compiled = cover_call(compile_beam_directory,["lib/ejabberd-2.1.8/ebin"]),
    rpc:call(get_ejabberd_node(), application, stop, [ejabberd]),
    StartStatus = rpc:call(get_ejabberd_node(), application, start, [ejabberd, permanent]),
    io:format("start ~p~n", [StartStatus]),
    io:format("Compiled modules ~p~n", [Compiled]).
    %%timer:sleep(10000).

analyze(Node) ->
    Modules = cover_call(modules),
    io:format("node ~s~n", [Node]),
    FilePath = case {Node, file:read_file(?CT_REPORT++"/index.html")} of
        {summary, {ok, IndexFileData}} ->
            R = re:replace(IndexFileData, "<a href=\"all_runs.html\">ALL RUNS</a>", "& <a href=\"cover.html\" style=\"margin-right:5px\">COVER</a>"),
            file:write_file(?CT_REPORT++"/index.html", R),
            ?CT_REPORT++"/cover.html";
        _ -> skip
    end,
    CoverageDir = filename:dirname(FilePath)++"/coverage",
    rpc:call(get_ejabberd_node(), file, make_dir, ["/tmp/coverage"]),
    {ok, File} = file:open(FilePath, [write]),
    file:write(File, "<html>\n<head></head>\n<body bgcolor=\"white\" text=\"black\" link=\"blue\" vlink=\"purple\" alink=\"red\">\n"),
    file:write(File, "<h1>Coverage for application 'esl-ejabberd'</h1>\n"),
    file:write(File, "<table border=3 cellpadding=5>\n"),
    file:write(File, "<tr><th>Module</th><th>Covered (%)</th><th>Covered (Lines)</th><th>Not covered (Lines)</th><th>Total (Lines)</th></tr>"),
    Fun = fun(Module, {CAcc, NCAcc}) ->
                  FileName = lists:flatten(io_lib:format("~s.COVER.html",[Module])),
                  FilePathC = filename:join(["/tmp/coverage", FileName]),
                  io:format("Analysing module ~s~n", [Module]),
                  cover_call(analyse_to_file, [Module, FilePathC, [html]]),
                  {ok, {Module, {C, NC}}} = cover_call(analyse, [Module, module]),
                  file:write(File, row(atom_to_list(Module), C, NC, percent(C,NC),"coverage/"++FileName)),
                  {CAcc + C, NCAcc + NC}
          end,
    io:format("coverage analyzing~n"),
    {CSum, NCSum} = lists:foldl(Fun, {0, 0}, Modules),
    os:cmd("cp -R /tmp/coverage "++CoverageDir),
    file:write(File, row("Summary", CSum, NCSum, percent(CSum, NCSum), "#")),
    file:close(File).

cover_call(Function) ->
    cover_call(Function, []).

cover_call(Function, Args) ->
    rpc:call(get_ejabberd_node(), cover, Function, Args).

get_ejabberd_node() ->
    {ok, Props} = file:consult(ct_config_file()),
    {ejabberd_node, Node} = proplists:lookup(ejabberd_node, Props),
    Node.

percent(0, _) -> 0;
percent(C, NC) when C /= 0; NC /= 0 -> round(C / (NC+C) * 100);
percent(_, _)                       -> 100.

row(Row, C, NC, Percent, Path) ->
    [
        "<tr>",
        "<td><a href='", Path, "'>", Row, "</a></td>",
        "<td>", integer_to_list(Percent), "%</td>",
        "<td>", integer_to_list(C), "</td>",
        "<td>", integer_to_list(NC), "</td>",
        "<td>", integer_to_list(C+NC), "</td>",
        "</tr>\n"
    ].
