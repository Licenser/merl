%% ---------------------------------------------------------------------
%% @author Richard Carlsson <carlsson.richard@gmail.com>
%% @copyright 2010-2012 Richard Carlsson
%% @doc Metaprogramming in Erlang.

-module(merl).

-export([term/1, var/1]).

-export([quote/1, quote/2, quote_at/2, quote_at/3, subst/2, match/2]).

-export([init_module/1, module_forms/1, add_function/4, add_record/3,
         add_import/3, add_attribute/3, compile/1, compile/2,
         compile_and_load/1, compile_and_load/2]).

-include("../include/merl.hrl").

-export([parse_transform/2]).

%% TODO: simple text visualization of syntax trees, for debugging etc.
%% TODO: work in ideas from smerl to make an almost-drop-in replacement


%% ------------------------------------------------------------------------
%% Parse transform for turning strings to templates at compile-time

%% FIXME: this (and the matching) is not quite working

parse_transform(Forms, _Options) ->
    [P1] = ?Q(["merl:quote(_@text)"]),
    %erlang:display({pattern, template(P1)}),
    erl_syntax:revert_forms(
      erl_syntax_lib:map(fun (T) -> transform(T, P1) end,
                         erl_syntax:form_list(Forms))).

transform(T, P1) ->
    case match(P1, T) of
        {ok, [{_, Text}]} ->
            term(Text);
        error ->
            T
    end.

%% ------------------------------------------------------------------------
%% Utility functions for commonly needed things

%% TODO: setting line numbers

%% @doc Create a variable.
var(Name) ->
    erl_syntax:variable(Name).

%% @doc Create a syntax tree for a constant term.
term(Term) ->
    erl_syntax:abstract(Term).


%% ------------------------------------------------------------------------

%% @equiv compile(Code, [])
compile(Code) ->
    compile(Code, []).

%% @doc Compile a syntax tree or list of syntax trees representing a module
%% into a binary BEAM object.
%% @see compile_and_load/2
%% @see compile/1
compile(Code, Options) when not is_list(Code)->
    case erl_syntax:type(Code) of
        form_list -> compile(erl_syntax:form_list_elements(Code));
        _ -> compile([Code], Options)
    end;
compile(Code, Options0) when is_list(Options0) ->
    Forms = [erl_syntax:revert(F) || F <- Code],
    Options = [verbose, report_errors, report_warnings, binary | Options0],
    %% Note: modules compiled from forms will have a '.' as the last character
    %% in the string given by proplists:get_value(source,
    %% erlang:get_module_info(ModuleName, compile)).
    compile:noenv_forms(Forms, Options).


%% @equiv compile_and_load(Code, [])
compile_and_load(Code) ->
    compile_and_load(Code, []).

%% @doc Compile a syntax tree or list of syntax trees representing a module
%% and load the resulting module into memory.
%% @see compile/2
%% @see compile_and_load/1
compile_and_load(Code, Options) ->
    case compile(Code, Options) of
        {ok, ModuleName, Binary} ->
            code:load_binary(ModuleName, "", Binary),
            {ok, Binary};
        Other -> Other
    end.


%% ------------------------------------------------------------------------
%% Making it simple to build a module

-record(module, { name          :: atom()
                , exports=[]    :: [{atom(), integer()}]
                , imports=[]    :: [{atom(), [{atom(), integer()}]}]
                , records=[]    :: [{atom(), [{atom(), term()}]}]
                , attributes=[] :: [{atom(), [term()]}]
                , functions=[]  :: [{atom(), {[term()],[term()],[term()]}}]
                }).

%% TODO: init module from a list of forms (from various sources)

%% @doc Create a new module representation, using the given module name.
init_module(Name) when is_atom(Name) ->
    #module{name=Name}.

%% TODO: setting current file (between forms)

%% @doc Get the list of syntax tree forms for a module representation. This can
%% be passed to compile/2.
module_forms(#module{name=Name,
                     exports=Xs,
                     imports=Is,
                     records=Rs,
                     attributes=As,
                     functions=Fs})
  when is_atom(Name), Name =/= undefined ->
    [Module] = ?Q(["-module('@name')."], [{name,term(Name)}]),
    [Export] = ?Q(["-export(['@@_name'/1])."],
                  [{name, [erl_syntax:arity_qualifier(term(N), term(A))
                           || {N,A} <- ordsets:from_list(Xs)]}]),
    Imports = lists:concat([?Q(["-import('@module', ['@@_name'/1])."],
                               [{module,term(M)},
                                {name,[erl_syntax:arity_qualifier(term(N),
                                                                  term(A))
                                       || {N,A} <- ordsets:from_list(Ns)]}])
                            || {M, Ns} <- Is]),
    Records = lists:concat([?Q(["-record('@name',{'@@_fields'})."],
                               [{name,term(N)},
                                {fields,[erl_syntax:record_field(term(F),
                                                                 term(V))
                                         || {F,V} <- Es]}])
                            || {N,Es} <- lists:reverse(Rs)]),
    Attrs = lists:concat([?Q(["-'@name'('@term')."],
                             [{name,term(N)}, {term,term(T)}])
                          || {N,T} <- lists:reverse(As)]),
    [Module, Export | Imports ++ Records ++ Attrs ++ lists:reverse(Fs)].

%% @doc Add a function to a module representation.
add_function(Exported, Name, Clauses, #module{exports=Xs, functions=Fs}=M)
  when is_boolean(Exported), is_atom(Name), Clauses =/= [] ->
    Arity = length(erl_syntax:clause_patterns(hd(Clauses))),
    Xs1 = case Exported of
              true -> [{Name,Arity} | Xs];
              false -> Xs
          end,
    M#module{exports=Xs1,
             functions=[erl_syntax:function(term(Name), Clauses) | Fs]}.

%% @doc Add an import declaration to a module representation.
add_import(From, Names, #module{imports=Is}=M)
  when is_atom(From), is_list(Names) ->
    M#module{imports=[{From, Names} | Is]}.

%% @doc Add a record declaration to a module representation.
add_record(Name, Fs, #module{records=Rs}=M) when is_atom(Name) ->
    M#module{records=[{Name, Fs} | Rs]}.

%% @doc Add a "wild" attribute, such as `-compile(Opts)' to a module
%% representation. Note that such attributes can only have a single argument.
add_attribute(Name, Term, #module{attributes=As}=M) when is_atom(Name) ->
    M#module{attributes=[{Name, Term} | As]}.


%% ------------------------------------------------------------------------
%% The quoting functions always return a list of one or more elements.

%% TODO: setting source line statically vs. dynamically (Erlang vs. DSL source)
%% TODO: only take lists of lines, or plain lines as well? splitting?

%% @spec quote(TextLines::[iolist()]) -> [term()]
%% @doc Parse lines of text and substitute meta-variables from environment.
quote(TextLines) ->
    quote_at(1, TextLines).

%% @spec quote_at(StartPos::position(), TextLines::[iolist()]) -> [term()]
%% @type position() :: integer() | {Line::integer(), Col::integer()}
%% @see quote/1
quote_at({Line, Col}, TextLines)
  when is_integer(Line), is_integer(Col), Line > 0, Col > 0 ->
    quote_at_1(Line, Col, TextLines);
quote_at(StartPos, TextLines) when is_integer(StartPos), StartPos > 0 ->
    quote_at_1(StartPos, undefined, TextLines).

quote_at_1(StartLine, StartCol, TextLines) ->
    %% be backwards compatible as far as R12, ignoring any starting column
    StartPos = case erlang:system_info(version) of
                   "5.6" ++ _ -> StartLine;
                   "5.7" ++ _ -> StartLine;
                   "5.8" ++ _ -> StartLine;
                   _ when StartCol =:= undefined -> StartLine;
                   _ -> {StartLine, StartCol}
               end,
    {ok, Ts, _} = erl_scan:string(flatten_lines(TextLines), StartPos),
    parse_1(Ts).

%% @spec quote(TextLines::[iolist()],
%%             Env::[{Key::atom(),term()}]) -> [term()]
%% @doc Parse lines of text and substitute meta-variables from environment.
quote(TextLines, Env) ->
    quote_at(1, TextLines, Env).

%% @spec quote_at(StartLine::integer(), TextLines::[iolist()],
%%                Env::[{Key::atom(),term()}]) -> [term()]
%% @see quote/2
quote_at(StartLineNo, Text, Env) ->
    lists:flatten([subst(T, Env) || T <- quote_at(StartLineNo, Text)]).

flatten_lines(TextLines) ->
    lists:foldr(fun(S, T) ->
                        binary_to_list(iolist_to_binary(S)) ++ [$\n | T]
                end,
                "",
                TextLines).

%% ------------------------------------------------------------------------
%% Parsing code fragments

parse_1(Ts) ->
    %% if dot tokens are present, it is assumed that the text represents
    %% complete forms, not dot-terminated expressions or similar
    case split_forms(Ts) of
        {ok, Fs} -> parse_forms(Fs);
        error ->
            parse_2(Ts)
    end.

split_forms(Ts) ->
    split_forms(Ts, [], []).

split_forms([{dot,_}=T|Ts], Fs, As) ->
    split_forms(Ts, [lists:reverse(As, [T]) | Fs], []);
split_forms([T|Ts], Fs, As) ->
    split_forms(Ts, Fs, [T|As]);
split_forms([], Fs, []) ->
    {ok, lists:reverse(Fs)};
split_forms([], [], _) ->
    error;  % no dot tokens found - not representing form(s)
split_forms([], _, [T|_]) ->
    fail("incomplete form after ~p", [T]).

parse_forms([Ts | Tss]) ->
    case erl_parse:parse_form(Ts) of
        {ok, Form} -> [Form | parse_forms(Tss)];
        {error, {_L,M,Reason}} ->
            fail(M:format_error(Reason))
    end;
parse_forms([]) ->
    [].

parse_2(Ts) ->
    %% one or more comma-separated expressions?
    %% (recall that Ts has no dot tokens if we get to this stage)
    case erl_parse:parse_exprs(Ts ++ [{dot,0}]) of
        {ok, Exprs} -> Exprs;
        {error, E} ->
            parse_3(Ts ++ [{'end',0}, {dot,0}], [E])
    end.

parse_3(Ts, Es) ->
    %% try-clause or clauses?
    case erl_parse:parse_exprs([{'try',0}, {atom,0,true}, {'catch',0} | Ts]) of
        {ok, [{'try',_,_,_,_,_}=X]} ->
            %% get the right kind of qualifiers in the clause patterns
            erl_syntax:try_expr_handlers(X);
        {error, E} ->
            parse_4(Ts, [E|Es])
    end.

parse_4(Ts, Es) ->
    %% fun-clause or clauses? (`(a)' is also a pattern, but `(a,b)' isn't,
    %% so fun-clauses must be tried before normal case-clauses
    case erl_parse:parse_exprs([{'fun',0} | Ts]) of
        {ok, [{'fun',_,{clauses,Cs}}]} -> Cs;
        {error, E} ->
            parse_5(Ts, [E|Es])
    end.

parse_5(Ts, Es) ->
    %% case-clause or clauses?
    case erl_parse:parse_exprs([{'case',0}, {atom,0,true}, {'of',0} | Ts]) of
        {ok, [{'case',_,_,Cs}]} -> Cs;
        {error, E} ->
            case lists:last(lists:sort([E|Es])) of
                {L, M, R} when is_atom(M), is_integer(L), L > 0 ->
                    fail("~w: ~s", [L, M:format_error(R)]);
                {{L,C}, M, R} when is_atom(M), is_integer(L), is_integer(C),
                                   L > 0, C > 0 ->
                    fail("~w:~w: ~s", [L,C,M:format_error(R)]);
                {_, M, R} when is_atom(M) ->
                    fail(M:format_error(R));
                R ->
                    fail("unknown parse error: ~p", [R])
            end
    end.

%% ------------------------------------------------------------------------

%% @doc Check for metavariables. These are atoms starting with `@',
%% variables starting with `_@', or integers starting with `990'. After
%% that, one or more `@' or `0' characters may be used to indicate "lifting"
%% of the variable one or more levels, and after that, a `_' or `9'
%% character indicates a group metavariable rather than a node metavariable.
metavariable(Node) ->
    case erl_syntax:type(Node) of
        atom ->
            case erl_syntax:atom_name(Node) of
                "@" ++ Cs when Cs =/= [] -> {true,Cs};
                _ -> false
            end;
        variable ->
            case erl_syntax:variable_literal(Node) of
                "_@" ++ Cs when Cs =/= [] -> {true,Cs};
                _ -> false
            end;
        integer ->
            case integer_to_list(erl_syntax:integer_value(Node)) of
                "990" ++ Cs when Cs =/= [] -> {true,Cs};
                _ -> false
            end;
        _ -> false
    end.

%% @doc Make a template tree, where leaves are normal syntax trees (generally
%% atomic), and inner nodes are tuples {node,Type,Attrs,Groups} where Groups
%% are lists of lists of nodes. Metavariables are 1-tuples {Name}, where Name
%% is an atom, and can exist both on the group level and the node level.
template(Tree) ->
    case template_1(Tree) of
        {Kind,Name} when Kind =:= lift ; Kind =:= group ->
            fail("bad metavariable: '~s'", [Name]);
        Other -> Other
    end.

template_1(Tree) ->
    case erl_syntax:subtrees(Tree) of
        [] ->
            case metavariable(Tree) of
                {true,"@"++Cs} when Cs =/= [] -> {lift,Cs};
                {true,"0"++Cs} when Cs =/= [] -> {lift,Cs};
                {true,"_"++Cs} when Cs =/= [] -> {group,Cs};
                {true,"9"++Cs} when Cs =/= [] -> {group,Cs};
                {true,Cs} -> {tag(Cs)};
                false -> Tree
            end;
        Gs ->
            Gs1 = [case [template_1(T) || T <- G] of
                       [{group,Name}] -> {tag(Name)};
                       G1 -> check_group(G1), G1
                   end
                   || G <- Gs],
            case lift(Gs1) of
                {true,"@"++Cs} when Cs =/= [] -> {lift,Cs};
                {true,"0"++Cs} when Cs =/= [] -> {lift,Cs};
                {true,"_"++Cs} when Cs =/= [] -> {group,Cs};
                {true,"9"++Cs} when Cs =/= [] -> {group,Cs};
                {true,Cs} -> {tag(Cs)};
                _ ->
                    {node, erl_syntax:type(Tree),
                     erl_syntax:get_attrs(Tree), Gs1}
            end
    end.

tag(Name) ->
    try list_to_integer(Name)
    catch
        error:badarg ->
            list_to_atom(Name)
    end.

lift(Gs) ->
    case [Name || {lift,Name} <- lists:concat([G || G <- Gs, is_list(G)])] of
        [] ->
            false;
        [Name] ->
            {true, Name};
        Names ->
            fail("clashing metavariables: ~w", [Names])
    end.

check_group(G) ->
    case [Name || {group,Name} <- G] of
        [] -> ok;
        Names ->
            fail("misplaced group metavariable: ~w", [Names])
    end.

%% @doc Revert a template tree to a normal syntax tree. Any remaining
%% metavariables are turned into @-prefixed atoms.
tree({node, Type, Attrs, Groups}) ->
    Gs = [case G of
              {Var} when is_atom(Var) ->
                  [erl_syntax:atom("@_"++atom_to_list(Var))];
              _ ->
                  [tree(T) || T <- G]
          end
          || G <- Groups],
    erl_syntax:set_attrs(erl_syntax:make_tree(Type, Gs), Attrs);
tree({Var}) when is_atom(Var) ->
    erl_syntax:atom("@"++atom_to_list(Var));
tree(Leaf) ->
    Leaf.  % any syntax tree, not necessarily atomic (due to substitutions)

%% @doc Substitute metavariables, both on group and node level.
subst(Tree, Env) ->
    tree(subst_1(template(Tree), Env)).

subst_1({node, Type, Attrs, Groups}, Env) ->
    Gs1 = [case G of
               {Name} ->
                   case lists:keyfind(Name, 1, Env) of
                       {Name, G1} when is_list(G1) ->
                           G1;
                       {Name, _} ->
                           fail("value of group metavariable "
                                "must be a list: '~s'", [Name]);
                       false -> {Name}
                   end;
               _ ->
                   lists:flatten([subst_1(T, Env) || T <- G])
           end
           || G <- Groups],
    {node, Type, Attrs, Gs1};
subst_1({Name}, Env) ->
    case lists:keyfind(Name, 1, Env) of
        {Name, NodeOrNodes} -> NodeOrNodes;
        false -> {Name}
    end;
subst_1(Leaf, _Env) ->
    Leaf.

%% Matches a pattern tree against a ground tree (or patterns against ground
%% trees) returning an environment mapping variable names to subtrees
match(Patterns, Trees) when is_list(Patterns), is_list(Trees) ->
    lists:foldr(fun ({P, T}, Env) -> match(P, T) ++ Env end,
                [], lists:zip(Patterns, Trees));
match(Pattern, Tree) ->
    try {ok, match_1(template(Pattern), template(Tree))}
    catch
        error -> error
    end.

match_1({node, Type, _, Gs1}, {node, Type, _, Gs2}) ->
    lists:foldr(fun ({_, {Name}}, _Env) ->
                        fail("metavariable in match source: '~s'", [Name]);
                    ({{Name}, G}, Env) ->
                        [{Name, G}] ++ Env;
                    ({G1, G2}, Env) ->
                        lists:foldr(fun ({T1, T2}, E) ->
                                            match_1(T1, T2) ++ E
                                    end,
                                    [],
                                    zip_match(G1, G2)) ++ Env
                end,
                [],
                zip_match(Gs1, Gs2));
match_1(_, {Name}) ->
    fail("metavariable in match source: '~s'", [Name]);
match_1({Name}, T) ->
    [{Name, tree(T)}];
match_1({node,_,_,_}, _) ->
    throw(error);  % not a match (non-leaf vs leaf), caught above
match_1(_,{node,_,_,_}) ->
    throw(error);  % not a match (leaf vs. non-leaf), caught above
match_1(L1, L2) ->
    %% we need to create a normal form of the leaves in order to compare
    %% them, so we have to reset the attributes of both leaf nodes
    A = erl_syntax:get_attrs(erl_syntax:nil()),
    %% all leaf nodes should be revertible (I think) - this will create a
    %% unique normal form that can be compared
    N1 = erl_syntax:revert(erl_syntax:set_attrs(L1, A)),
    N2 = erl_syntax:revert(erl_syntax:set_attrs(L2, A)),
    case N1 =:= N2 of
        true -> [];
        false -> throw(error)  % not a match, caught above
    end.

zip_match(Xs, Ys) ->
    %% turn zip length mismatch into a thrown error
    try lists:zip(Xs, Ys)
    catch
        error:function_clause -> throw(error)  % caught above
    end.

%% ------------------------------------------------------------------------
%% Internal utility functions

fail(Text) ->
    fail(Text, []).

fail(Fs, As) ->
    throw({error, lists:flatten(io_lib:format(Fs, As))}).
