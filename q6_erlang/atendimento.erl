%% Questao 6 - Distribuicao de tarefas de atendimento
%%
%% Um coordenador distribui solicitacoes entre processos atendentes e
%% correlaciona as respostas (que chegam em qualquer ordem) pelo id da
%% solicitacao. Toda a comunicacao e feita com spawn, ! e receive.
-module(atendimento).
-export([main/0, main/1, teste/0, teste/1, atendente/3]).

-define(N_SOLICITACOES, 18).
-define(N_ATENDENTES, 4).
-define(ATRASO_MAX, 300). % ms, so simula o tempo da analise

%% ------------------------------------------------------------------
%% Execucao principal
%% ------------------------------------------------------------------
main() -> main([]).

main(_Args) ->
    Solicitacoes = gerar_solicitacoes(?N_SOLICITACOES),
    io:format("~p solicitacoes geradas, ~p atendentes~n~n",
              [length(Solicitacoes), ?N_ATENDENTES]),
    Resultado = executar(Solicitacoes, ?N_ATENDENTES, ?ATRASO_MAX, true),
    Ok = imprimir_resumo(Solicitacoes, Resultado),
    case Ok of
        true  -> halt(0);
        false -> halt(1)
    end.

%% Cria o coordenador e espera o relatorio final dele.
executar(Solicitacoes, NAtendentes, Atraso, Verbose) ->
    Main = self(),
    Coord = spawn(fun() -> coordenador(Main, Solicitacoes, NAtendentes, Atraso, Verbose) end),
    Ref = monitor(process, Coord),
    receive
        {relatorio, Coord, Resultado} ->
            %% espera o coordenador terminar de fato
            receive {'DOWN', Ref, process, Coord, normal} -> ok end,
            Resultado
    end.

%% ------------------------------------------------------------------
%% Dados
%% ------------------------------------------------------------------
categorias() -> [financeiro, tecnico, cadastro, cancelamento].

descricoes(financeiro)   -> ["cobranca em duplicidade", "segunda via de boleto", "estorno pendente"];
descricoes(tecnico)      -> ["sem acesso ao sistema", "erro ao gerar relatorio", "lentidao no app"];
descricoes(cadastro)     -> ["alterar endereco", "atualizar email", "corrigir CPF"];
descricoes(cancelamento) -> ["cancelar plano", "desistencia de compra", "encerrar conta"].

%% {Id, Categoria, Descricao}
gerar_solicitacoes(N) ->
    Cats = categorias(),
    [begin
         Cat = lists:nth((Id rem length(Cats)) + 1, Cats),
         Descs = descricoes(Cat),
         Desc = lists:nth((Id rem length(Descs)) + 1, Descs),
         {Id, Cat, Desc}
     end || Id <- lists:seq(1, N)].

%% Analise simulada: algumas solicitacoes sao resolvidas na hora, outras
%% precisam ser encaminhadas para outro setor. E deterministica para que o
%% resumo esperado possa ser calculado.
analisar({Id, Cat, _Desc}) ->
    case {Cat, Id rem 3} of
        {cancelamento, _} -> encaminhada;
        {tecnico, 0}      -> encaminhada;
        _                 -> resolvida
    end.

%% ------------------------------------------------------------------
%% Atendente
%% ------------------------------------------------------------------
%% Cada atendente avisa que esta livre e fica bloqueado no receive ate o
%% coordenador mandar uma tarefa ou a mensagem de encerramento.
atendente(AtId, Coord, Atraso) ->
    Coord ! {livre, self(), AtId},
    loop_atendente(AtId, Coord, Atraso, 0).

loop_atendente(AtId, Coord, Atraso, Feitas) ->
    receive
        {tarefa, Coord, {SolId, _Cat, _Desc} = Sol} ->
            timer:sleep(rand:uniform(Atraso)), % simula a analise
            Situacao = analisar(Sol),
            %% a resposta ja serve como aviso de que esta livre de novo
            Coord ! {resposta, self(), AtId, SolId, Situacao},
            loop_atendente(AtId, Coord, Atraso, Feitas + 1);
        {encerrar, Coord} ->
            Coord ! {encerrado, self(), AtId, Feitas}
            %% fim da funcao -> processo termina com motivo normal
    end.

%% ------------------------------------------------------------------
%% Coordenador
%% ------------------------------------------------------------------
-record(estado, {
          fila,          % solicitacoes ainda nao atribuidas
          atribuidas,    % SolId => AtId
          respostas,     % SolId => {AtId, Situacao}
          inesperadas,   % respostas duplicadas ou de id desconhecido
          solicitacoes,  % SolId => {Id, Cat, Desc}
          total,
          verbose}).

coordenador(Main, Solicitacoes, NAtendentes, Atraso, Verbose) ->
    Self = self(),
    Atendentes = [begin
                      Pid = spawn(?MODULE, atendente, [AtId, Self, Atraso]),
                      Ref = monitor(process, Pid),
                      {Pid, AtId, Ref}
                  end || AtId <- lists:seq(1, NAtendentes)],
    E0 = #estado{fila = Solicitacoes,
                 atribuidas = #{},
                 respostas = #{},
                 inesperadas = [],
                 solicitacoes = maps:from_list([{Id, S} || {Id, _, _} = S <- Solicitacoes]),
                 total = length(Solicitacoes),
                 verbose = Verbose},
    E = distribuir(E0),
    log(Verbose, "~n[Coordenador] ~p respostas recebidas, encerrando atendentes~n",
        [maps:size(E#estado.respostas)]),
    Encerramentos = encerrar(Atendentes, Verbose),
    Main ! {relatorio, Self, {E#estado.atribuidas, E#estado.respostas,
                              E#estado.inesperadas, Encerramentos}}.

%% Laco principal: termina quando todas as solicitacoes tiverem resposta.
distribuir(#estado{respostas = R, total = T} = E) when map_size(R) =:= T ->
    E;
distribuir(E) ->
    receive
        {livre, Pid, AtId} ->
            distribuir(atribuir(Pid, AtId, E));
        {resposta, Pid, AtId, SolId, Situacao} ->
            E1 = registrar(AtId, SolId, Situacao, E),
            distribuir(atribuir(Pid, AtId, E1));
        {'DOWN', _Ref, process, _Pid, Motivo} ->
            %% um atendente morreu antes do fim: nao da pra continuar com seguranca
            erlang:error({atendente_caiu, Motivo})
    end.

%% Entrega a proxima solicitacao da fila ao atendente livre (se houver).
atribuir(_Pid, _AtId, #estado{fila = []} = E) ->
    E;
atribuir(Pid, AtId, #estado{fila = [{SolId, Cat, Desc} = Sol | Resto]} = E) ->
    log(E#estado.verbose, "[Coordenador] solicitacao ~2w (~p: ~s) -> atendente ~p~n",
        [SolId, Cat, Desc, AtId]),
    Pid ! {tarefa, self(), Sol},
    E#estado{fila = Resto, atribuidas = maps:put(SolId, AtId, E#estado.atribuidas)}.

%% A resposta e correlacionada pelo id, nao pela ordem de envio.
registrar(AtId, SolId, Situacao, E) ->
    #estado{atribuidas = A, respostas = R} = E,
    Esperado = maps:get(SolId, A, undefined),
    case {Esperado, maps:is_key(SolId, R)} of
        {AtId, false} ->
            log(E#estado.verbose, "[Coordenador] resposta da solicitacao ~2w (atendente ~p): ~p~n",
                [SolId, AtId, Situacao]),
            E#estado{respostas = maps:put(SolId, {AtId, Situacao}, R)};
        _ ->
            log(E#estado.verbose, "[Coordenador] resposta INESPERADA ~p de ~p~n", [SolId, AtId]),
            E#estado{inesperadas = [{SolId, AtId} | E#estado.inesperadas]}
    end.

%% Manda encerrar para todos e espera a confirmacao e o 'DOWN' de cada um,
%% assim o coordenador so termina depois que todos os atendentes terminaram.
encerrar(Atendentes, Verbose) ->
    [Pid ! {encerrar, self()} || {Pid, _, _} <- Atendentes],
    [receive
         {encerrado, Pid, AtId, Feitas} ->
             receive
                 {'DOWN', Ref, process, Pid, Motivo} ->
                     log(Verbose, "[Atendente ~p] encerrado (~p atendimentos, motivo ~p)~n",
                         [AtId, Feitas, Motivo]),
                     {AtId, Feitas, Motivo}
             end
     end || {Pid, AtId, Ref} <- Atendentes].

log(true, Fmt, Args) -> io:format(Fmt, Args);
log(false, _, _) -> ok.

%% ------------------------------------------------------------------
%% Resumo e verificacao
%% ------------------------------------------------------------------
resumo_por_categoria(Solicitacoes, Respostas) ->
    lists:foldl(
      fun({Id, Cat, _}, Acc) ->
              {Tot, Res, Enc} = maps:get(Cat, Acc, {0, 0, 0}),
              case maps:get(Id, Respostas, undefined) of
                  {_, resolvida}   -> Acc#{Cat => {Tot + 1, Res + 1, Enc}};
                  {_, encaminhada} -> Acc#{Cat => {Tot + 1, Res, Enc + 1}};
                  undefined        -> Acc
              end
      end, #{}, Solicitacoes).

resumo_esperado(Solicitacoes) ->
    resumo_por_categoria(Solicitacoes,
                         maps:from_list([{Id, {0, analisar(S)}} || {Id, _, _} = S <- Solicitacoes])).

verificar(Solicitacoes, {Atribuidas, Respostas, Inesperadas, Encerramentos}, NAtendentes) ->
    Ids = [Id || {Id, _, _} <- Solicitacoes],
    Faltando = [Id || Id <- Ids, not maps:is_key(Id, Respostas)],
    AtendenteCerto = lists:all(fun(Id) ->
                                       {AtId, _} = maps:get(Id, Respostas, {none, x}),
                                       maps:get(Id, Atribuidas, undefined) =:= AtId
                               end, Ids),
    TodosNormais = length(Encerramentos) =:= NAtendentes andalso
        lists:all(fun({_, _, M}) -> M =:= normal end, Encerramentos),
    SomaFeitas = lists:sum([F || {_, F, _} <- Encerramentos]),
    #{faltando => Faltando,
      inesperadas => Inesperadas,
      atendente_certo => AtendenteCerto,
      todos_encerrados => TodosNormais,
      soma_atendimentos => SomaFeitas,
      resumo_ok => resumo_por_categoria(Solicitacoes, Respostas) =:= resumo_esperado(Solicitacoes),
      ok => Faltando =:= [] andalso Inesperadas =:= [] andalso AtendenteCerto
          andalso TodosNormais andalso SomaFeitas =:= length(Ids)
          andalso maps:size(Atribuidas) =:= length(Ids)
          andalso resumo_por_categoria(Solicitacoes, Respostas) =:= resumo_esperado(Solicitacoes)}.

imprimir_resumo(Solicitacoes, {_Atribuidas, Respostas, _, _} = Resultado) ->
    Obtido = resumo_por_categoria(Solicitacoes, Respostas),
    Esperado = resumo_esperado(Solicitacoes),
    io:format("~n=========== RESUMO POR CATEGORIA ===========~n"),
    io:format("~-13s ~6s ~10s ~12s   ~s~n", ["categoria", "total", "resolvidas", "encaminhadas", "esperado"]),
    lists:foreach(
      fun(Cat) ->
              {T, R, En} = maps:get(Cat, Obtido, {0, 0, 0}),
              {ET, ER, EE} = maps:get(Cat, Esperado, {0, 0, 0}),
              io:format("~-13s ~6w ~10w ~12w   (~w/~w/~w)~n", [Cat, T, R, En, ET, ER, EE])
      end, categorias()),
    io:format("~nPor atendente:~n"),
    PorAtendente = maps:fold(fun(Id, {AtId, _}, Acc) ->
                                     maps:update_with(AtId, fun(L) -> [Id | L] end, [Id], Acc)
                             end, #{}, Respostas),
    [io:format("  atendente ~p: ~w~n", [AtId, lists:sort(L)])
     || {AtId, L} <- lists:sort(maps:to_list(PorAtendente))],
    V = verificar(Solicitacoes, Resultado, ?N_ATENDENTES),
    io:format("~nRespostas recebidas: ~p (esperado ~p)~n", [maps:size(Respostas), length(Solicitacoes)]),
    io:format("Faltando: ~w  Duplicadas/inesperadas: ~w~n",
              [maps:get(faltando, V), maps:get(inesperadas, V)]),
    io:format("Resposta veio do atendente que recebeu a tarefa: ~p~n", [maps:get(atendente_certo, V)]),
    io:format("Atendentes encerrados normalmente: ~p (soma de atendimentos ~p)~n",
              [maps:get(todos_encerrados, V), maps:get(soma_atendimentos, V)]),
    case maps:get(ok, V) of
        true  -> io:format("OK: cada solicitacao atribuida a um atendente e respondida uma vez~n");
        false -> io:format("ERRO: resultado diferente do esperado~n")
    end,
    maps:get(ok, V).

%% ------------------------------------------------------------------
%% Teste: repete a execucao varias vezes com tamanhos diferentes
%% ------------------------------------------------------------------
teste() -> teste(30).

teste(Rodadas) ->
    Casos = [{N, A} || N <- [15, 40], A <- [1, 3, 8]],
    Falhas = [{R, N, A} || R <- lists:seq(1, Rodadas), {N, A} <- Casos,
                           not rodada_ok(N, A)],
    io:format("~p execucoes, falhas: ~w~n", [Rodadas * length(Casos), Falhas]),
    case Falhas of
        [] -> io:format("TESTES OK~n"), halt(0);
        _  -> halt(1)
    end.

rodada_ok(N, A) ->
    Antes = erlang:system_info(process_count),
    Sols = gerar_solicitacoes(N),
    Res = executar(Sols, A, 5, false),
    V = verificar(Sols, Res, A),
    %% nenhum processo do coordenador/atendentes pode ter sobrado
    maps:get(ok, V) andalso erlang:system_info(process_count) =:= Antes.
