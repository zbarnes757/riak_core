%% -------------------------------------------------------------------
%%
%% Copyright (c) 2017 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%%% @doc
%%%      The `riak_core_info_service' is a way for dependencies of
%%%      `riak_core' to be registered to receive messages from
%%%      `riak_core' without a cyclic dependency graph.
%%%
%%%      == Callbacks ==
%%%      The dependency needs to know to which pid it should send
%%%      requests for `riak_core' data. The pid will be sent to the
%%%      `Registration' callback.
%%%
%%%      The `Provider' callback is a function inside `riak_core' that returns
%%%      information that the dependency needs.
%%%
%%%      The `Handler' callback is a function in the dependency that
%%%      expects the reply from the `Provider'.
%%%
%%%      === Handler Parameters ===
%%%      The arguments to `Handler' will be, in order:
%%%      <ol><li>Each item, if any, provided in the list in the 3rd element of the registration tuple</li>
%%%      <li>The result from `Provider' wrapped in a 3-tuple:
%%%        <ol><li>The result</li>
%%%            <li>The list of parameters passed to `Provider' via the invoke message</li>
%%%            <li>The opaque `HandlerContext' (see {@section Request Message})</li>
%%%        </ol></li></ol>
%%%
%%%
%%%      See {@link callback()}.
%%%
%%%      == Request Message ==
%%%
%%%      To ask the `info_service' process to call the `Provider'
%%%      function, the dependency <b>must</b> send Erlang messages
%%%      (rather than invoke API functions) to the info service
%%%      process (registered previously via the `Registration'
%%%      callback) of the following form:
%%%
%%%        `{invoke, ProviderParameters::[term()], HandlerContext::term()}'
%%%
%%%      The `HandlerContext' is a request identifier ignored by
%%%      `riak_core', to be returned to the caller.
%%%
%%%      == History ==
%%%      The information service originates from a need in `eleveldb' to retrieve
%%%      bucket properties.
%%%
%%%      For that particular problem the callbacks would look like this:
%%%  ```
%%%  Registration = {eleveldb, set_metadata_pid, []}
%%%  Provider = {riak_core_bucket, get_bucket, []}
%%%  Handler = {eleveldb, handle_metadata_response, []}
%%%  '''
%%%
%%%      And `handle_metadata_response/1' would look like this,
%%%      assuming `Key' was sent with the original invocation message
%%%      as the 3rd element of the tuple:
%%%  ```
%%%  handle_metadata_response({Props, _ProviderParams, Key}) ->
%%%      property_cache(Key, Props).
%%%
%%%  set_metadata_pid(_Pid) ->
%%%      erlang:nif_error({error, not_loaded}).
%%%  '''
%%%
%%%      == Error Handling ==
%%%
%%%      If any callback generates an exception, the response from
%%%      `catch' will be logged and (where relevant) communicated to
%%%      the caller.
%%%
%%%      If the registration or response handler callback defined by
%%%      the consumer returns anything other than `ok', the service
%%%      process will terminate.

-module(riak_core_info_service).

-export([start_service/4]).


-type callback() :: {module(), FunName::atom(),InitialArgs::[term()]} | undefined.

%% @type callback(). Any arguments provided during registration of
%% `Handler' will be sent as the first parameters when the callback is
%% invoked; the result of the `Provider' callback will be wrapped in a
%% tuple as the last parameter. See {@section Handler Parameters}

-export_type([callback/0]).

-spec start_service(Registration::callback(), Shutdown::callback(), Provider::callback(), Handler::callback()) ->
                           ok |
                           {error, term()}.

start_service(Registration, Shutdown, Provider, Handler) ->
    riak_core_info_service_sup:start_service(Registration, Shutdown, Provider, Handler).

-ifdef(TEST).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").

-define(NODE_NAME, a_node).
-define(REG(Key), {?MODULE, register, [self(), Key]}).
-define(SHUT(Key), {?MODULE, shutdown, [self(), Key]}).
-define(HANDLER(Key), {?MODULE, response, [self(), Key]}).

-define(GET_RING, {riak_core_ring, fresh, [64, ?NODE_NAME]}).
-define(CRASH, {?MODULE, crashme, []}).

crashme(_) ->
    exit(for_testing).

sup_wrapper() ->
    {ok, Sup} = riak_core_info_service_sup:start_link(),
    receive
        sup_kill ->
            exit(Sup, kill)
    end.

wait_for_no_sup(_Regname, 0) ->
    throw(supervisor_did_not_die);
wait_for_no_sup(Regname, Count) ->
    case whereis(Regname) of
        undefined ->
            ok;
        _ ->
            timer:sleep(50),
            wait_for_no_sup(Regname, Count-1)
    end.

wait_for_sup(_Regname, 0) ->
    throw(no_supervisor);
wait_for_sup(Regname, Count) ->
    case whereis(Regname) of
        undefined ->
            timer:sleep(50),
            wait_for_sup(Regname, Count-1);
        _ ->
            ok
    end.

setup() ->
    wait_for_no_sup(riak_core_info_service_sup, 5),
    Pid = spawn(fun sup_wrapper/0),
    wait_for_sup(riak_core_info_service_sup, 5),
    Pid.

teardown(Pid) ->
    Pid ! sup_kill.

exception_test() ->
    Sup = setup(),
    Key = 'exception_test',
    Context = '_waydownwego',

    {ok, Pid0} = riak_core_info_service:start_service(?REG(Key), ?SHUT(Key), ?GET_RING, ?CRASH),

    Pid = receive
              {register, {Key, SvcPid}} ->
                  SvcPid;
              Msg0 ->
                  io:format(user, "Unknown msg: ~p~n", [Msg0]),
                  throw(unexpected_msg)
          after 1000 ->
                  throw(timeout)
          end,

    ?assert(is_process_alive(Pid)),
    ?assertEqual(Pid0, Pid),
    Pid ! {invoke, [], Context},

    Result = receive
                 {shutdown, {Key, Pid}} ->
                     shutdown;
                 Msg1 ->
                     io:format(user, "Unknown msg expecting shutdown: ~p~n", [Msg1]),
                     element(1, Msg1)
             after 1000 ->
                     throw(timeout)
             end,


    %% Yes, if the ring structure changes again, this first assertion will fail
    ?assertEqual(shutdown, Result),
    teardown(Sup),
    ok.

receive_ring_test() ->
    Sup = setup(),
    Key = 'test_receive_ring',
    Context = '_mesojedi',

    {ok, Pid0} = riak_core_info_service:start_service(?REG(Key), ?SHUT(Key), ?GET_RING, ?HANDLER(Key)),

    Pid = receive
              {register, {Key, SvcPid}} ->
                  SvcPid;
              Msg0 ->
                  io:format(user, "Unknown msg: ~p~n", [Msg0]),
                  throw(unexpected_msg)
          after 1000 ->
                  throw(timeout)
          end,

    ?assert(is_process_alive(Pid)),
    ?assertEqual(Pid0, Pid),
    Pid ! {invoke, [], Context},

    Ring = receive
               {response, {Key, {Context, MyRing}}} ->
                   MyRing;
              Msg1 ->
                  io:format(user, "Unknown msg expecting ring: ~p~n", [Msg1]),
                  throw(unexpected_msg)
           after 1000 ->
                  throw(timeout)
           end,

    %% Yes, if the ring structure changes again, this first assertion will fail
    ?assertEqual(chstate_v2, element(1, Ring)),
    ?assertEqual(?NODE_NAME, element(2, Ring)),
    teardown(Sup),
    ok.


response(Pid, Key1, {Result, [], Context}) ->
    Pid ! {response, {Key1, {Context, Result}}},
    ok.

register(Pid, Key, SvcPid) ->
    Pid ! {register, {Key, SvcPid}},
    ok.

shutdown(Pid, Key, SvcPid) ->
    Pid ! {shutdown, {Key, SvcPid}},
    ok.

-endif.