-module(snatch_fun_test).
-compile([warnings_as_errors]).

-export([
    check/1,
    check/2,
    check/3,
    run/1
]).

-export([send/2]).

-define(DEFAULT_TIMEOUT, 120). % seconds
-define(DEFAULT_VERBOSE, false).

-define(DEFAULT_TIMES, 1).
-define(DEFAULT_STEP_TIMEOUT, 1000). % ms

-define(TEST_PROCESS, test_proc).
-define(TIMEOUT_RECEIVE_ALL, 500). % ms

-include_lib("fast_xml/include/fxml.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("snatch/include/snatch.hrl").

-record(functional, {
    steps = [] :: [term()],
    config :: [proplists:property()]
}).

-record(step, {
    name :: binary(),
    timeout = ?DEFAULT_STEP_TIMEOUT :: pos_integer(),
    actions
}).

check(Tests) ->
    check(Tests, ?DEFAULT_TIMEOUT, ?DEFAULT_VERBOSE).

check(Tests, Timeout) ->
    check(Tests, Timeout, ?DEFAULT_VERBOSE).

check(Tests, Timeout, Verbose) ->
    {timeout, Timeout,
        {setup,
            fun() -> start_suite(Verbose) end,
            fun(_) -> stop_suite() end,
            [ run(Test) || Test <- Tests ]
        }
    }.

send(PingResponse, _JID) ->
    ?TEST_PROCESS ! {send, PingResponse},
    ok.

start_suite(_Verbose) ->
    {ok, _PID} = net_kernel:start([snatch@localhost, shortnames]),
    application:start(fast_xml),
    timer:sleep(1000),
    ok.

stop_suite() ->
    %% FIXME: the fast_xml system is not possible to be stopped or
    %%        restarted that's the reason because the start is not
    %%        controlled and in this part fast_xml is not stopped.
    ok = net_kernel:stop(),
    ok.

run(Test) ->
    {" ** TEST => " ++ Test, {spawn, {setup,
        fun() -> parse_file(Test) end,
        fun(Functional) ->
            run_start(Functional) ++
            run_steps(Functional) ++
            run_stop(Functional)
        end
    }}}.

get_cfg(Name, Config) ->
    proplists:get_value(Name, Config, undefined).

run_start(#functional{config = Config}) ->
    [{"start",
        fun() ->
            true = register(?TEST_PROCESS, self()),
            case get_cfg(snatch, Config) of
                {router, ModuleBin} ->
                    Module = binary_to_atom(ModuleBin, utf8),
                    {ok, _PID} = snatch:start_link(?MODULE, Module);
                {module, ModuleBin, Args} ->
                    Module = binary_to_atom(ModuleBin, utf8),
                    {ok, _PID} = snatch:start_link(?MODULE, Module, Args)
            end
        end}].

run_steps(#functional{steps = Steps}) ->
    lists:map(fun run_step/1, Steps).

run_stop(#functional{}) ->
    [{"stop",
        fun() ->
            snatch:stop(),
            true = unregister(?TEST_PROCESS)
        end}].

run_step(#step{name = Name, actions = Actions}) ->
    [{Name, fun() ->
        lists:foldl(fun run_action/2, {[], [], #{}}, Actions)
      end}].

run_action({vars, VarsMap}, {ExpectedStanzas, ReceivedStanzas, Map}) ->
    NewMap = maps:merge(Map, VarsMap),
    {ExpectedStanzas, ReceivedStanzas, NewMap};

run_action({send_via, xml, Stanzas}, {ExpectedStanzas, ReceivedStanzas, Map}) ->
    {ProcessedStanzas, NewMap} = lists:foldl(fun process_xml_action/2,
                                             {[], Map}, Stanzas),
    lists:foreach(fun(Stanza) ->
        From = snatch_xml:get_attr(<<"from">>, Stanza),
        To = snatch_xml:get_attr(<<"to">>, Stanza),
        Via = #via{jid = From, exchange = To, claws = ?MODULE},
        snatch:received(Stanza, Via)
    end, ProcessedStanzas),
    {ExpectedStanzas, ReceivedStanzas, NewMap};

run_action({send_via, Type, Text}, {ExpectedStanzas, ReceivedStanzas, Map})
        when Type =:= json orelse
             Type =:= raw ->
    ProcessedText = process_text_action(Text, Map),
    Via = #via{claws = ?MODULE},
    snatch:received(ProcessedText, Via),
    {ExpectedStanzas, ReceivedStanzas, Map};

run_action({send, xml, Stanzas}, {ExpectedStanzas, ReceivedStanzas, Map}) ->
    {ProcessedStanzas, NewMap} = lists:foldl(fun process_xml_action/2,
                                             {[], Map}, Stanzas),
    lists:foreach(fun snatch:received/1, ProcessedStanzas),
    {ExpectedStanzas, ReceivedStanzas, NewMap};

run_action({send, Type, Text}, {ExpectedStanzas, ReceivedStanzas, Map})
        when Type =:= json orelse
             Type =:= raw ->
    ProcessedText = process_text_action(Text, Map),
    snatch:received(ProcessedText),
    {ExpectedStanzas, ReceivedStanzas, Map};

run_action({expected, xml, Stanzas}, {ExpectedStanzas, OldRecvStanzas, Map}) ->
    ReceivedStanzas = receive_stanzas([]),
    NewMap = check_stanzas(ReceivedStanzas, Stanzas, Map),
    NewExpectedStanzas = ExpectedStanzas ++ Stanzas,
    NewReceivedStanzas = OldRecvStanzas ++ ReceivedStanzas,
    {NewExpectedStanzas, NewReceivedStanzas, NewMap};

run_action({expected, Type, Text}, {ExpectedStanzas, OldRecvStanzas, Map})
        when Type =:= json orelse
             Type =:= raw ->
    ReceivedRaw = receive_raw([]),
    NewMap = check_stanzas(ReceivedRaw, [Text], Map),
    NewExpectedStanzas = ExpectedStanzas ++ [Text],
    NewReceivedStanzas = OldRecvStanzas ++ ReceivedRaw,
    {NewExpectedStanzas, NewReceivedStanzas, NewMap};

run_action({check, {M, F}}, {ExpectedStanzas, ReceivedStanzas, Map}) ->
    ok = apply(M, F, [ExpectedStanzas, ReceivedStanzas, Map]),
    {ExpectedStanzas, ReceivedStanzas, Map}.

process_xml_action(#xmlel{attrs = Attrs, children = Children} = El,
                   {ProcessedStanzas, Map}) ->
    ProcessedAttrs = lists:map(fun
        ({AttrKey, <<"{{",_/binary>> = Value}) ->
            RE = <<"^\\{\\{([^}]+)\\}\\}$">>,
            Opts = [global, {capture, all, binary}],
            case re:run(Value, RE, Opts) of
                {match, [[Value, Key]]} ->
                    case maps:get(Key, Map, undefined) of
                        undefined ->
                            XMLStanza = fxml:element_to_binary(El),
                            ?debugFmt("~n~n-----------~n"
                                      "missing key: ~s~n"
                                      "~nStanza => ~s~n"
                                      "~nMap => ~p~n-----------~n",
                                      [Key, XMLStanza, Map]),
                            erlang:halt(1);
                        AttrVal ->
                            {AttrKey, AttrVal}
                    end;
                nomatch -> {AttrKey, Value}
            end;
        (Attr) -> Attr
    end, Attrs),
    ProcessedChildren = lists:map(fun
        ({xmlcdata, CData}) ->
            RE = <<"\\{\\{([^}]+)\\}\\}">>,
            Opts = [global, {capture, all, binary}],
            case re:run(CData, RE, Opts) of
                {match, [[CData|Keys]]} ->
                    {xmlcdata, lists:foldl(fun(Key, CD) ->
                        Val = maps:get(Key, Map),
                        ReplaceKey = <<"\\{\\{", Key/binary, "\\}\\}">>,
                        re:replace(CD, ReplaceKey, Val, [global])
                    end, CData, Keys)};
                nomatch ->
                    {xmlcdata, CData}
            end;
        (#xmlel{} = Child) ->
            hd(element(1, process_xml_action(Child, {[], Map})))
    end, Children),
    Stanza = El#xmlel{attrs = ProcessedAttrs, children = ProcessedChildren},
    {ProcessedStanzas ++ [Stanza], Map}.

process_text_action(CData, Map) ->
    RE = <<"<%([^%]+[^>])%>">>,
    RunOpts = [global, {capture, all, binary}],
    case re:run(CData, RE, RunOpts) of
        {match, Keys} ->
            lists:foldl(fun([ReplaceKey, Key], CD) ->
                Val = maps:get(Key, Map),
                RepOpts = [global],
                iolist_to_binary(re:replace(CD, ReplaceKey, Val, RepOpts))
            end, CData, Keys);
        nomatch ->
            CData
    end.

check_stanzas([], [], Map) ->
    Map;
check_stanzas([], ExpectedStanzas, Map) ->
    XMLStanza = lists:foldl(fun
        (ExpectedText, Text) when is_binary(ExpectedText) ->
            <<Text/binary, ExpectedText/binary, "\n">>;
        (ExpectedStanza, Text) ->
            <<Text/binary, (fxml:element_to_binary(ExpectedStanza))/binary, "\n">>
    end, <<>>, ExpectedStanzas),
    ?debugFmt("~n~n-----------~nMissing stanza(s):~n~s~n"
              "~nMap => ~p~n-----------~n",
              [XMLStanza, Map]),
    erlang:halt(1);
check_stanzas([RecvStanza|ReceivedStanzas], ExpectedStanzas, Map) ->
    ExpectedStanza = lists:foldl(fun
        (ExpectedStanza, false) ->
            case check_stanza(RecvStanza, ExpectedStanza) of
                true -> ExpectedStanza;
                false -> false
            end;
        (_, ExpectedStanza) ->
            ExpectedStanza
    end, false, ExpectedStanzas),
    case ExpectedStanza of
        false when is_binary(RecvStanza) ->
            ?debugFmt("~n~n-----------~nUnexpected text:~n~s~n"
                      "~nMap => ~p~n-----------~n",
                      [RecvStanza, Map]),
            erlang:halt(1);
        false ->
            XMLStanza = fxml:element_to_binary(RecvStanza),
            ?debugFmt("~n~n-----------~nUnexpected stanza:~n~s~n"
                      "~nMap => ~p~n-----------~n",
                      [XMLStanza, Map]),
            erlang:halt(1);
        ExpectedStanza ->
            ok
    end,
    NewExpectedStanzas = ExpectedStanzas -- [ExpectedStanza],
    NewMap = lists:foldl(fun
        ({value, Key, Value}, M) ->
            case maps:get(Key, M, undefined) of
                undefined ->
                    M#{Key => Value};
                OldValue when OldValue =:= Value ->
                    M;
                OldValue ->
                    XMLStanza1 = fxml:element_to_binary(RecvStanza),
                    XMLStanza2 = fxml:element_to_binary(ExpectedStanza),
                    ?debugFmt("~n~n-----------~nAttribute not valid:~n"
                              "~s [~s] not [~s] in:~n~s~n"
                              "~nreceived:~n~s~n"
                              "~nMap => ~p~n-----------~n",
                              [Key, OldValue, Value, XMLStanza2,
                               XMLStanza1, M]),
                    erlang:halt(1)
            end
    end, Map, receive_updates([])),
    check_stanzas(ReceivedStanzas, NewExpectedStanzas, NewMap).

check_stanza(El, El) -> true;
check_stanza({xmlcdata, CData}, {xmlcdata, CData}) -> true;
check_stanza(#xmlel{name = Name} = El1, #xmlel{name = Name} = El2) ->
    case check_attrs(lists:sort(El1#xmlel.attrs),
                     lists:sort(El2#xmlel.attrs)) of
        true when length(El1#xmlel.children) =:= length(El2#xmlel.children) ->
            Els = lists:zip(lists:sort(El1#xmlel.children),
                            lists:sort(El2#xmlel.children)),
            lists:all(fun({E1, E2}) -> check_stanza(E1, E2) end, Els);
        _ ->
            false
    end;
check_stanza({xmlcdata, CData1}, {xmlcdata, <<"{{", _/binary>> = CData2}) ->
    RE = <<"^\\{\\{([^}]+)\\}\\}$">>,
    Opts = [global, {capture, all, binary}],
    {match, [[CData2, Var]]} = re:run(CData2, RE, Opts),
    self() ! {value, Var, CData1},
    true;
check_stanza(_, _) ->
    false.

check_attrs(Attrs, Attrs) -> true;
check_attrs([Attr|Attrs1], [Attr|Attrs2]) ->
    check_attrs(Attrs1, Attrs2);
check_attrs([{Key, Val1}|Attrs1], [{Key, <<"{{",_/binary>> = Val2}|Attrs2]) ->
    RE = <<"^\\{\\{([^}]+)\\}\\}$">>,
    Opts = [global, {capture, all, binary}],
    {match, [[Val2, Var]]} = re:run(Val2, RE, Opts),
    self() ! {value, Var, Val1},
    check_attrs(Attrs1, Attrs2);
check_attrs(_A1, _A2) ->
    false.

receive_updates(Updates) ->
    receive
        {value, _, _} = Value -> receive_updates([Value|Updates])
    after ?TIMEOUT_RECEIVE_ALL ->
        Updates
    end.

receive_raw(ReceivedRaw) ->
    receive
        {send, Raw} ->
            receive_raw([Raw|ReceivedRaw])
    after ?TIMEOUT_RECEIVE_ALL ->
        ReceivedRaw
    end.

receive_stanzas(ReceivedStanzas) ->
    receive
        {send, XMLStanza} ->
            Stanza = fxml_stream:parse_element(XMLStanza),
            receive_stanzas([Stanza|ReceivedStanzas])
    after ?TIMEOUT_RECEIVE_ALL ->
        ReceivedStanzas
    end.

parse_file(Test) ->
    {ok, BaseDir} = file:get_cwd(),
    File = BaseDir ++ "/test/functional/" ++ Test ++ ".xml",
    {ok, XML} = file:read_file(File),
    Parsed = case fxml_stream:parse_element(XML) of
        #xmlel{} = P ->
            P;
        Error ->
            ?debugFmt("~n~n---------------~n~s~n~p~n~n", [File, Error]),
            erlang:halt(2)
    end,
    Cleaned = snatch_xml:clean_spaces(Parsed),
    lists:foldl(fun(XmlEl, #functional{steps = Steps} = F) ->
        case parse(XmlEl) of
            [#step{}|_] = NewSteps ->
                F#functional{steps = Steps ++ NewSteps};
            [{_, _}|_] = Config ->
                F#functional{config = Config};
            [] -> F
        end
    end, #functional{}, Cleaned#xmlel.children).

parse(#xmlel{name = <<"config">>, children = Configs}) ->
    lists:flatmap(fun
        (#xmlel{name = <<"snatch">>,
                attrs = [{<<"module">>, Name}],
                children = Children}) ->
            Args = lists:map(fun(#xmlel{name = <<"arg">>} = XmlEl) ->
                #xmlel{attrs = [{<<"key">>, Key}|Type],
                       children = [{xmlcdata, BinValue}]} = XmlEl,
                Value = case proplists:get_value(<<"type">>, Type, undefined) of
                    <<"atom">> -> binary_to_atom(BinValue, utf8);
                    <<"int">> -> binary_to_integer(BinValue);
                    <<"float">> -> binary_to_float(BinValue);
                    <<"string">> -> binary_to_list(BinValue);
                    _ -> BinValue
                end,
                {binary_to_atom(Key, utf8), Value}
            end, Children),
            [{snatch, {module, Name, Args}}];
        (#xmlel{name = <<"snatch">>, attrs = [{<<"router">>, Name}]}) ->
            [{snatch, {router, Name}}]
    end, Configs);

parse(#xmlel{name = <<"steps">>, children = Steps}) ->
    lists:map(fun parse_step/1, Steps).


parse_step(#xmlel{children = Actions} = Step) ->
    Timeout = snatch_xml:get_attr_int(<<"timeout">>, Step, ?DEFAULT_STEP_TIMEOUT),
    #step{name = snatch_xml:get_attr(<<"name">>, Step, <<"noname">>),
          timeout = Timeout,
          actions = lists:map(fun parse_action/1, Actions)}.

parse_action(#xmlel{name = <<"vars">>, children = Vars}) ->
    Map = lists:foldl(fun
        (#xmlel{name = <<"value">>, attrs = [{<<"key">>, Key}]} = El, M) ->
            M#{ Key => snatch_xml:get_cdata(El) };
        (#xmlel{name = Name}, M) when Name =/= <<"value">> ->
            M
    end, #{}, Vars),
    {vars, Map};

parse_action(#xmlel{name = <<"send">>, children = Send} = Tag) ->
    Type = case snatch_xml:get_attr_atom(<<"via">>, Tag, false) of
        true -> send_via;
        false -> send
    end,
    case snatch_xml:get_attr_atom(<<"type">>, Tag, xml) of
        xml ->
            {Type, xml, Send};
        json ->
            CData = snatch_xml:get_cdata(Tag),
            {Type, json, CData};
        raw ->
            CData = snatch_xml:get_cdata(Tag),
            {Type, raw, CData}
    end;

parse_action(#xmlel{name = <<"expected">>, children = Expected} = Tag) ->
    case snatch_xml:get_attr_atom(<<"type">>, Tag, xml) of
        xml ->
            {expected, xml, Expected};
        json ->
            CData = snatch_xml:get_cdata(Tag),
            {expected, json, CData};
        raw ->
            CData = snatch_xml:get_cdata(Tag),
            {expected, raw, CData}
    end;

parse_action(#xmlel{name = <<"check">>} = Check) ->
    M = snatch_xml:get_attr_atom(<<"module">>, Check),
    F = snatch_xml:get_attr_atom(<<"function">>, Check),
    {check, {M, F}}.
