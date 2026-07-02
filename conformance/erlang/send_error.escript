#!/usr/bin/env escript
%%! -escript main send_error
%%
%% Conformance для Erlang. Официального Sentry SDK для Erlang нет
%% (ADR-0001), поэтому это тонкий HTTP-клиент на встроенных `httpc` + `json`
%% (OTP 27+): он собирает envelope и шлёт его по протоколу Sentry, зная
%% только DSN — ровно та «тонкая обёртка над HTTP», что заложена в ADR-0001.
%%
%% Запуск: SWATTER_DSN=... escript send_error.escript

main(_) ->
    Dsn = os:getenv("SWATTER_DSN"),
    case Dsn of
        false ->
            io:format(standard_error, "SWATTER_DSN is not set~n", []),
            halt(2);
        _ ->
            run(Dsn)
    end.

run(Dsn) ->
    {ok, _} = application:ensure_all_started(inets),
    {Scheme, Key, Host, Port, ProjectId} = parse_dsn(Dsn),

    EventId = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),

    Event = #{
        <<"event_id">> => EventId,
        <<"level">> => <<"error">>,
        <<"platform">> => <<"other">>,
        <<"release">> => <<"conformance@0.0.1">>,
        <<"environment">> => <<"conformance">>,
        <<"exception">> => #{
            <<"values">> => [#{
                <<"type">> => <<"badmatch">>,
                <<"value">> => <<"conformance: hello from erlang">>
            }]
        }
    },

    EventJson = iolist_to_binary(json:encode(Event)),
    Envelope = [
        json:encode(#{<<"event_id">> => EventId}), "\n",
        json:encode(#{<<"type">> => <<"event">>, <<"length">> => byte_size(EventJson)}), "\n",
        EventJson, "\n"
    ],

    Url = Scheme ++ "://" ++ Host ++ Port ++ "/api/" ++ ProjectId ++ "/envelope",
    Auth = "Sentry sentry_version=7, sentry_key=" ++ Key,

    Request = {Url, [{"X-Sentry-Auth", Auth}], "application/x-sentry-envelope", Envelope},
    case httpc:request(post, Request, [], []) of
        {ok, {{_, 200, _}, _, _}} ->
            io:format("event sent~n", []);
        Other ->
            io:format(standard_error, "send failed: ~p~n", [Other]),
            halt(1)
    end.

%% {scheme}://{public_key}@{host}[:{port}]/{project_id}
parse_dsn(Dsn) ->
    {Scheme, Rest0} = split_on(Dsn, "://"),
    {Key, Rest1} = split_on(Rest0, "@"),
    {HostPort, ProjectId} = split_on(Rest1, "/"),
    {Host, Port} =
        case string:split(HostPort, ":") of
            [H, P] -> {H, ":" ++ P};
            [H] -> {H, ""}
        end,
    {Scheme, Key, Host, Port, ProjectId}.

split_on(String, Sep) ->
    case string:split(String, Sep) of
        [A, B] -> {A, B};
        [A] -> {A, ""}
    end.
