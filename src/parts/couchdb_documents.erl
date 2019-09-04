-module(couchdb_documents).

-include("couchdb.hrl").
-include("../dev.hrl").

-export([
    save/2
    ,save/3
    ,save/4
]).


%% @reference CouchDB Docs 1.2.8
%% @doc save a document
%% @equiv save(Db, Doc, [])
save(Db, Doc) ->
    save(Db, Doc, []).

%% @doc save a *document
%% A document is a Json object like this one:
%%
%%      ```{[
%%          {<<"_id">>, <<"myid">>},
%%          {<<"title">>, <<"test">>}
%%      ]}'''
%%
%% Options are arguments passed to the request. This function return a
%% new document with last revision and a docid. If _id isn't specified in
%% document it will be created. Id is created by extracting an uuid from
%% the couchdb node.
%%
%% @spec save(Db::db(), Doc, Options::list()) -> {ok, Doc1}|{error, Error}
save(Db, Doc, Options) ->
    save(Db, Doc, [], Options).


%% @doc save a *document with all its attacjments
%% A document is a Json object like this one:
%%
%%      ```{[
%%          {<<"_id">>, <<"myid">>},
%%          {<<"title">>, <<"test">>}
%%      ]}'''
%%
%% Options are arguments passed to the request. This function return a
%% new document with last revision and a docid. If _id isn't specified in
%% document it will be created. Id is created by extracting an uuid from
%% the couchdb node.
%%
%% If the attachments is not empty, the doc will be sent as multipart.
%% Attachments are passed as a list of the following tuples:
%%
%% - `{Name :: binary(), Bin :: binary()}'
%% - `{Name :: binary(), Bin :: binary(), Encoding :: binary()}'
%% - `{ Name :: binary(), Bin :: binary(), Type :: binary(), Encoding :: binary()}'
%% - `{ Name :: binary(), {file, Path ::  string()}}'
%% - `{ Name :: binary(), {file, Path ::  string()}, Encoding :: binary()}'
%% - `{ Name :: binary(), Fun :: fun(), Length :: integer()}'
%% - `{ Name :: binary(), Fun :: fun(), Length :: integer(), Encoding :: binary()}'
%% - `{Name :: binary(), Fun :: fun(), Length :: integer(), Type :: binary(), Encoding :: binary()}'
%% - `{ Name :: binary(), {Fun :: fun(), Acc :: any()}, Length :: integer()}'
%% - `{ Name :: binary(), {Fun :: fun(), Acc :: any()}, Length :: integer(), Encoding :: binary()}'
%% - `{ Name :: binary(), {Fun :: fun(), Acc :: any()}, Length :: integer(), Type :: binary(), Encoding :: binary()}.'
%%
%% where `Type` is the content-type of the attachments (detected in other
%% case) and `Encoding` the encoding of the attachments:
%% `<<"identity">>' if normal or `<<"gzip">>' if the attachments is
%% gzipped.

-spec save(Db::db(), doc(), mp_attachments(), Options::list()) -> {ok, doc()} | {error, term()}.
save(#db{server=Server, options=Opts}=Db, #{}=Doc, Atts, Options) ->
    % DocId = case couchdb_util:get_value(<<"_id">>, Props) of
    %     undefined ->
    %         [Id] = get_uuid(Server),
    %         Id;
    %     DocId1 ->
    %         couchdb_util:encode_docid(DocId1)
    % end,

    % PREPARE DOC ID 
    DocId = case maps:get(<<"_id">>, Doc, nil) of        
        Id when is_binary(Id) -> couchdb_util:encode_docid(Id);        
        nil ->
            quickrand:seed ( ),
            list_to_binary ( uuid:uuid_to_string ( uuid:get_v4_urandom ( ) ) )
    end,
    
    Url = hackney_url:make_url(couchdb_httpc:server_url(Server), couchdb_httpc:doc_url(Db, DocId), Options),

    % case Atts of
    %     [] ->
    %         JsonDoc = couchdb_ejson:encode(Doc),
    %         Headers = [{<<"Content-Type">>, <<"application/json">>}],
    %         case couchdb_httpc:db_request(put, Url, Headers, JsonDoc, Opts,
    %                                 [200, 201, 202]) of
    %             {ok, _, _, Ref} ->
    %                 {JsonProp} = couchdb_httpc:json_body(Ref),
    %                 NewRev = couchdb_util:get_value(<<"rev">>, JsonProp),
    %                 NewDocId = couchdb_util:get_value(<<"id">>, JsonProp),
    %                 Doc1 = couchdb_doc:set_value(<<"_rev">>, NewRev,
    %                     couchdb_doc:set_value(<<"_id">>, NewDocId, Doc)),
    %                 {ok, Doc1};
    %             Error ->
    %                 Error
    %         end;
    %     _ ->
    %         Boundary = couchdb_uuids:random(),

    %         %% for now couchdb can't received chunked multipart stream
    %         %% so we have to calculate the content-length. It also means
    %         %% that we need to know the size of each attachments. (Which
    %         %% should be expected).
    %         {CLen, JsonDoc, Doc2} = couchdb_httpc:len_doc_to_mp_stream(Atts, Boundary, Doc),
    %         CType = <<"multipart/related; boundary=\"",
    %                   Boundary/binary, "\"" >>,

    %         Headers = [{<<"Content-Type">>, CType},
    %                    {<<"Content-Length">>, hackney_bstr:to_binary(CLen)}],

    %         case couchdb_httpc:request(put, Url, Headers, stream,
    %                                      Opts) of
    %             {ok, Ref} ->
    %                 couchdb_httpc:send_mp_doc(Atts, Ref, Boundary, JsonDoc, Doc2);
    %             Error ->
    %                 Error
    %         end
    % end

    % Send off single-part if no attachments or multipart if attachments.
    case Atts of
        [] -> send_document_singlepart(Db, Url, Doc);
        _ -> send_document_multipart(Db, Url, Doc, Atts)
    end.

%% @private
send_document_singlepart(#db{server=Server, options=Opts}=Db, Url, #{}=Doc) ->
    JsonDoc = couchdb_ejson:encode(Doc),
    Headers = [{<<"Content-Type">>, <<"application/json">>}],
    case couchdb_httpc:db_request(put, Url, Headers, JsonDoc, Opts, [200, 201, 202]) of
        {ok, _Res_code, _Headers, Ref} ->
            Res = couchdb_httpc:json_body(Ref),
            case maps:take(<<"ok">>, Res) of
                {true,  #{<<"id">> := _Id, <<"rev">> := _Rev}=ResWithoutOk} -> maps:merge(Doc, ResWithoutOk);
                _Other -> Res
            end;
        Error -> Error
    end.

%% @private
send_document_multipart(#db{server=Server, options=Opts}=Db, Url, #{}=Doc, Atts) -> 
   Boundary = couchdb_uuids:random(),

    %% for now couchdb can't received chunked multipart stream
    %% so we have to calculate the content-length. It also means
    %% that we need to know the size of each attachments. (Which
    %% should be expected).
    {CLen, JsonDoc, Doc2} = couchdb_httpc:len_doc_to_mp_stream(Atts, Boundary, Doc),
    CType = <<"multipart/related; boundary=\"", Boundary/binary, "\"" >>,

    Headers = [{<<"Content-Type">>, CType},
                {<<"Content-Length">>, hackney_bstr:to_binary(CLen)}],

    case couchdb_httpc:request(put, Url, Headers, stream, Opts) of
        {ok, Ref} ->
            couchdb_httpc:send_mp_doc(Atts, Ref, Boundary, JsonDoc, Doc2);
        Error ->
            Error
    end.