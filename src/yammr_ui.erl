%% Web UI: server-rendered HTML (erlydtl) with htmx 4 for in-place updates.
%%
%% Two kinds of response come out of here:
%%   * a page      - full document, rendered from a template that extends layout.dtl
%%   * a fragment  - one region of the dashboard that htmx swaps in place
%% Both are plain HTML; the browser never sees JSON. Template variables must be
%% binaries (or maps/lists of binaries): erlydtl escapes every value on output.
%%
%% The Connect card's per-harness steps and snippets are templates too, one per
%% tab under priv/ui/templates/harness/; this module only knows the tab ids.
-module(yammr_ui).
-behaviour(cowboy_handler).

-export([routes/0, init/2]).

routes() ->
    [
        {"/", ?MODULE, login},
        {"/dashboard", ?MODULE, dashboard},
        {"/system", ?MODULE, system},
        %% fragments
        {"/dashboard/token", ?MODULE, token},
        {"/dashboard/connect/:harness", ?MODULE, connect},
        {"/system/models/:model/warm", ?MODULE, warm},
        %% htmx, stylesheet, fonts
        {"/ui/[...]", cowboy_static,
            {priv_dir, yammr, "ui/static", [{mimetypes, cow_mimetypes, all}]}}
    ].

init(Req0, login) ->
    {ok, login(Req0), login};
init(Req0, Page) ->
    Req =
        case yammr_session:current(Req0) of
            {ok, User} -> handle(Page, cowboy_req:method(Req0), User, Req0);
            none -> signed_out(Req0)
        end,
    {ok, Req, Page}.

login(Req) ->
    case yammr_session:current(Req) of
        {ok, _User} ->
            redirect(<<"/dashboard">>, Req);
        none ->
            Qs = maps:from_list(cowboy_req:parse_qs(Req)),
            render(
                login_dtl,
                #{
                    error => maps:is_key(<<"error">>, Qs),
                    expired => maps:is_key(<<"expired">>, Qs),
                    version => version()
                },
                Req
            )
    end.

%% No session. A full-page request goes to the login page; an htmx request
%% gets HX-Redirect so the whole tab navigates instead of swapping a fragment.
signed_out(Req) ->
    case cowboy_req:header(<<"hx-request">>, Req) of
        <<"true">> -> cowboy_req:reply(401, #{<<"hx-redirect">> => <<"/?expired=1">>}, Req);
        _ -> redirect(<<"/">>, Req)
    end.

handle(dashboard, <<"GET">>, User, Req) ->
    Vars = lists:foldl(fun maps:merge/2, page(dashboard, User), [
        token_vars(User),
        connect_vars(<<"curl">>, Req),
        #{usage => usage(User)}
    ]),
    render(dashboard_dtl, Vars, Req);
handle(system, <<"GET">>, User, Req) ->
    Vars = (page(system, User))#{usage => usage(User), models => models()},
    render(system_dtl, Vars, Req);
%% --- fragments -------------------------------------------------------------

%% Token panel: POST mints (response shows the secret once), DELETE revokes.
handle(token, <<"POST">>, #{email := Email} = User, Req) ->
    {ok, Secret, _Info} = yammr_tokens:mint(Email),
    render(token_panel_dtl, (token_vars(User))#{secret => Secret}, Req);
handle(token, <<"DELETE">>, #{email := Email} = User, Req) ->
    ok = yammr_tokens:revoke(Email),
    render(token_panel_dtl, token_vars(User), Req);
%% Warm-up request: mock. Re-renders the row as "warming"; nothing is scheduled.
handle(warm, <<"POST">>, _User, Req) ->
    Id = cowboy_req:binding(model, Req),
    case lists:search(fun(#{id := I}) -> I =:= Id end, models()) of
        {value, Model} -> render(model_row_dtl, #{m => Model#{status => <<"warming">>}}, Req);
        false -> cowboy_req:reply(404, Req)
    end;
%% Connect card: one tab's worth of instructions.
handle(connect, <<"GET">>, _User, Req) ->
    Harness = cowboy_req:binding(harness, Req),
    case lists:keymember(Harness, 1, harnesses()) of
        true -> render(connect_dtl, connect_vars(Harness, Req), Req);
        false -> cowboy_req:reply(404, Req)
    end;
handle(_Page, _Method, _User, Req) ->
    cowboy_req:reply(405, Req).

%% What every signed-in page gets; `active` highlights the sidebar entry.
page(Active, User) ->
    #{active => atom_to_binary(Active), user => User, version => version()}.

token_vars(#{email := Email}) ->
    case yammr_tokens:lookup(Email) of
        {ok, #{prefix := Prefix, created := Created}} ->
            #{token => #{prefix => Prefix, created => rfc3339(Created)}};
        none ->
            #{}
    end.

%% Connect card showing one harness's tab. The steps and snippet come from
%% harness/<id>.dtl via connect.dtl; we only supply what they interpolate.
connect_vars(Active, Req) ->
    #{
        harness => Active,
        base_url => base_url(Req),
        model => <<"qwen3.8-27b">>,
        tabs => [#{id => Id, label => Label} || {Id, Label} <- harnesses()]
    }.

%% Tabs on the Connect card, in order: {id, label}. Adding one means a new
%% priv/ui/templates/harness/<id>.dtl and a branch in connect.dtl.
%% curl is the real one; the rest are mocked up.
harnesses() ->
    [
        {<<"curl">>, <<"curl">>},
        {<<"python">>, <<"Python">>},
        {<<"opencode">>, <<"OpenCode">>},
        {<<"codex">>, <<"Codex CLI">>},
        {<<"cursor">>, <<"Cursor">>}
    ].

%% --- mock data -------------------------------------------------------------
%% Replace these with calls into the relay once metering / model state exist.

%% Single-stat usage figures for the signed-in user.
usage(_User) ->
    Models = models(),
    Ready = length([M || #{status := <<"ready">>} = M <- Models]),
    #{
        tokens => <<"1,284,301">>,
        requests => <<"212">>,
        period => <<"this month">>,
        ready => integer_to_binary(Ready),
        total => integer_to_binary(length(Models))
    }.

%% Models the relay knows about. status is one of ready | cold | warming.
models() ->
    [
        #{
            id => <<"llama-3.3-70b-instruct">>,
            name => <<"Llama 3.3 70B Instruct">>,
            kind => <<"chat">>,
            context => <<"128k">>,
            status => <<"ready">>
        },
        #{
            id => <<"qwen2.5-coder-32b">>,
            name => <<"Qwen2.5 Coder 32B">>,
            kind => <<"chat">>,
            context => <<"32k">>,
            status => <<"ready">>
        },
        #{
            id => <<"deepseek-r1-distill-32b">>,
            name => <<"DeepSeek R1 Distill 32B">>,
            kind => <<"chat">>,
            context => <<"64k">>,
            status => <<"cold">>
        },
        #{
            id => <<"mistral-small-24b">>,
            name => <<"Mistral Small 24B">>,
            kind => <<"chat">>,
            context => <<"32k">>,
            status => <<"cold">>
        },
        #{
            id => <<"nomic-embed-text-v1.5">>,
            name => <<"nomic-embed-text v1.5">>,
            kind => <<"embeddings">>,
            context => <<"8k">>,
            status => <<"ready">>
        }
    ].

%% Scheme://host[:port]/v1 as the browser reached us.
base_url(Req) ->
    iolist_to_binary(
        cowboy_req:uri(Req, #{path => <<"/v1">>, qs => undefined, fragment => undefined})
    ).

rfc3339(Seconds) ->
    list_to_binary(calendar:system_time_to_rfc3339(Seconds, [{unit, second}, {offset, "Z"}])).

version() ->
    {ok, Vsn} = application:get_key(yammr, vsn),
    list_to_binary(Vsn).

redirect(Location, Req) ->
    cowboy_req:reply(302, #{<<"location">> => Location}, Req).

render(Template, Vars, Req) ->
    {ok, Html} = Template:render(Vars),
    cowboy_req:reply(200, #{<<"content-type">> => <<"text/html; charset=utf-8">>}, Html, Req).
