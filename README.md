# Lista 3 – Modelos de Programação Concorrente

Repositório para hospedar a atividade de Programação Concorrente (CIN0145).

## Questões escolhidas

| Assunto | Questão | Pasta |
|---|---|---|
| Go | **Questão 1** – Processamento de pedidos em uma loja virtual | `q1_go/` |
| Erlang | **Questão 6** – Distribuição de tarefas de atendimento | `q6_erlang/` |
| Linda + Python | **Questão 7** – Fila compartilhada de chamados de suporte | `q7_linda/` |

## Código-fonte
Estrutura

```
├── q1_go
│   ├── go.mod
│   ├── main.go            # parâmetros, impressão do resumo e verificação
│   ├── pedidos.go         # geração dos pedidos, trabalhadores e coordenador
│   ├── pedidos_test.go    # testes (go test -race)
│   └── Makefile
├── q6_erlang
│   ├── atendimento.erl    # coordenador, atendentes, resumo e testes
│   └── Makefile
├── q7_linda
│   ├── chamados.py        # servidor do espaço de tuplas, coordenador e atendentes
│   ├── test_chamados.py   # repete a execução várias vezes e confere tudo
│   ├── requirements.txt
│   └── Makefile
└── README.md
```

As três soluções são independentes e rodam separadas, cada uma dentro da sua pasta.

## Instalação, compilação e execução

### Q1 – Go

Precisa do Go 1.22 ou mais novo (testado com go1.22.2), sem dependências externas.

``` bash
cd q1_go
make run      # go run .
make test     # go test -race -count=1 -v ./...
```
Dá pra mudar os parâmetros:
``` bash
go run . -pedidos 40 -trabalhadores 6 -atraso 50
```

### Q6 – Erlang

Precisa do Erlang/OTP (testado com o OTP 27). No Ubuntu: `sudo apt install erlang`.

``` bash
cd q6_erlang
make run      # erlc atendimento.erl && erl -noshell -s atendimento main
make test     # erl -noshell -s atendimento teste
```
Sem Erlang instalado, dá pra usar a imagem oficial no Docker:
``` bash
make docker-run
make docker-test
```

### Q7 – Linda com Python

Precisa do Python 3 (testado com o 3.12.3). O Makefile cria um venv e instala a biblioteca:

``` bash
cd q7_linda
make install  # python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
make run      # .venv/bin/python chamados.py
make test     # .venv/bin/python test_chamados.py
```
Ou instalando na mão:
``` bash
pip install pylinda==0.1.4
python3 chamados.py --chamados 15 --atendentes 3 --atraso 0.4
```
O programa sobe o próprio servidor do espaço de tuplas na porta 21643 (dá pra trocar com `--porta`). O servidor da pylinda imprime cada operação recebida, e essa saída vai para `linda_server.log`.

---

## Questão 1 – Pedidos da loja virtual (Go)

### Arquitetura

```
             canalPedidos                 canalResultados
  main  ───► (chan Pedido) ───► trabalhador 1 ─┐
                             ├─► trabalhador 2 ─┼──► (chan Resultado) ───► coordenador ───► fim (chan Resumo) ───► main
                             ├─► trabalhador 3 ─┤
                             └─► trabalhador 4 ─┘
```

- **main** (`Processar`): gera os 25 pedidos (id, quantidade, valor unitário em centavos), cria as goroutines e manda os pedidos pelo canal `canalPedidos`.
- **trabalhadores** (4 por padrão, o enunciado pede no mínimo 3): fazem `for p := range pedidos`, validam o pedido (quantidade > 0 e valor unitário >= 0), calculam `quantidade * valor` e mandam um `Resultado{PedidoID, Trabalhador, Valido, Total, Motivo}` pelo `canalResultados`. Tem um `time.Sleep` aleatório de até 100 ms só pra simular o processamento.
- **coordenador**: única goroutine que mexe no resumo. Faz `range` em `canalResultados`, guarda cada resultado num `map[int]Resultado` indexado pelo id do pedido e conta válidos, inválidos e o valor total dos válidos.

Os pedidos são gerados de forma determinística, e alguns são inválidos de propósito: os de id múltiplo de 7 ou 11 têm quantidade 0 ou negativa, e os múltiplos de 9 têm valor negativo. Assim o resultado esperado é sempre o mesmo, e a função `Esperado` calcula esse resultado de forma sequencial pra comparar com o concorrente.

Os valores ficam em centavos (`int`) pra não ter erro de arredondamento de float na soma.

### Comunicação e sincronização

- `canalPedidos` e `canalResultados` são canais sem buffer. A distribuição sai de graça: o pedido vai para o trabalhador que estiver livre para receber, e um pedido lido do canal sai dele, então dois trabalhadores nunca pegam o mesmo.
- O resumo só é acessado pela goroutine coordenadora, então não tem região crítica nem mutex. A sincronização toda é feita pelos canais.
- `sync.WaitGroup` conta os trabalhadores vivos.
- O canal `fim` devolve o resumo do coordenador para o main.

### Resultados e encerramento

A ordem de fechamento é o que garante que nenhum resultado se perde:

```go
for _, p := range pedidos {
    canalPedidos <- p
}
close(canalPedidos)     // 1. sem mais pedidos: cada trabalhador sai do range quando o canal esvazia

wg.Wait()               // 2. todos os trabalhadores já mandaram o último resultado
close(canalResultados)  // 3. ninguém mais escreve: o coordenador sai do range

return <-fim            // 4. o coordenador manda o resumo e termina
```

Como os canais não têm buffer, o `wg.Done()` de um trabalhador só acontece depois que o coordenador já recebeu todos os resultados dele. Então quando o `wg.Wait()` retorna, todos os resultados já foram recebidos e dá pra fechar `canalResultados` sem perder nada. A ordem em que os trabalhadores terminam não importa, porque o coordenador associa cada resultado ao `PedidoID`.

No final o coordenador confere se veio algum id repetido (`Duplicados`) e se faltou algum pedido (`Faltando`).

### Exemplo de execução

Esperado: 25 pedidos, 18 válidos, 7 inválidos (ids 7, 9, 11, 14, 18, 21, 22) e R$ 1861,37 de total.

```
25 pedidos gerados, 4 trabalhadores

[Trabalhador 4] processando pedido 1
[Trabalhador 3] processando pedido 4
[Trabalhador 2] processando pedido 3
[Trabalhador 1] processando pedido 2
[Trabalhador 1] processando pedido 5
[Coordenador] pedido  2 (trabalhador 1): valido, total R$ 73,56
[Trabalhador 4] processando pedido 6
[Coordenador] pedido  1 (trabalhador 4): valido, total R$ 34,42
[Trabalhador 1] processando pedido 7
[Coordenador] pedido  5 (trabalhador 1): valido, total R$ 46,45
...
[Coordenador] pedido  7 (trabalhador 1): INVALIDO, quantidade nao positiva
[Trabalhador 3] processando pedido 13
[Coordenador] pedido 11 (trabalhador 3): INVALIDO, quantidade nao positiva
[Trabalhador 2] processando pedido 14
[Coordenador] pedido  9 (trabalhador 2): INVALIDO, valor unitario negativo
...
[Trabalhador 4] canal de pedidos fechado, encerrando
[Coordenador] pedido 23 (trabalhador 4): valido, total R$ 112,12
[Trabalhador 2] canal de pedidos fechado, encerrando
[Coordenador] pedido 20 (trabalhador 2): valido, total R$ 56,10
[Trabalhador 3] canal de pedidos fechado, encerrando
[Coordenador] pedido 22 (trabalhador 3): INVALIDO, quantidade nao positiva
[Trabalhador 1] canal de pedidos fechado, encerrando
[Coordenador] pedido 25 (trabalhador 1): valido, total R$ 42,65

=========== RESUMO ===========
Pedidos processados: 25 (esperado 25)
Pedidos validos:     18 (esperado 18)
Pedidos invalidos:   7 (esperado 7)
Valor total validos: R$ 1861,37 (esperado R$ 1861,37)
Duplicados: []  Faltando: []
OK: todos os pedidos processados exatamente uma vez
```
A ordem das linhas muda a cada execução, mas o resumo é sempre o mesmo.

### Testes

`make test` roda `go test -race`, ou seja, com o detector de condição de corrida ligado:

- **TestProcessarIgualSequencial**: 50 rodadas, de 20 a 69 pedidos, com 1, 3 e 8 trabalhadores (150 execuções). Em cada uma compara os totais com o cálculo sequencial, confere que não tem duplicado nem faltando e que cada resultado está associado ao id certo.
- **TestSemGoroutinesVazando**: conta as goroutines antes e depois de `Processar` pra garantir que nenhum trabalhador nem o coordenador ficou vivo.

```
=== RUN   TestProcessarIgualSequencial
--- PASS: TestProcessarIgualSequencial (3.34s)
=== RUN   TestSemGoroutinesVazando
--- PASS: TestSemGoroutinesVazando (0.01s)
PASS
ok  	lista3/q1_go	4.355s
```

---

## Questão 6 – Distribuição de tarefas de atendimento (Erlang)

### Arquitetura

```
 main ──spawn──► coordenador ──spawn──► atendente 1..4
   ▲                 │   ▲
   │                 │   │ {livre, Pid, AtId}
   │                 │   │ {resposta, Pid, AtId, SolId, Situacao}
   │                 │   │ {encerrado, Pid, AtId, Feitos}
   │                 ▼   │
   │       {tarefa, Coord, Sol} / {encerrar, Coord}
   │
   └── {relatorio, Coord, Resultado}
```

- **main**: cria o coordenador com `spawn`, monitora ele e fica no `receive` esperando o relatório.
- **coordenador**: gera 18 solicitações `{Id, Categoria, Descricao}` (o mínimo pedido é 15) em 4 categorias (financeiro, técnico, cadastro, cancelamento), cria 4 atendentes com `spawn` e `monitor` e distribui o trabalho.
- **atendente**: avisa que está livre, espera uma tarefa no `receive`, faz uma análise simulada (`timer:sleep` aleatório de até 300 ms + uma regra determinística que decide entre `resolvida` e `encaminhada`) e responde ao coordenador com o id da solicitação e o seu próprio id.

A distribuição é por demanda: o coordenador só manda uma solicitação para um atendente quando recebe dele `{livre, ...}` ou uma `{resposta, ...}`, porque a resposta já serve de aviso de que ele ficou livre de novo. Assim quem é mais rápido atende mais, e cada atendente tem no máximo uma tarefa por vez.

### Comunicação e sincronização

Só mensagens (`!` e `receive`), sem nenhuma memória compartilhada. O estado do coordenador fica em um record passado de uma chamada recursiva para a outra:

```erlang
-record(estado, {
          fila,          % solicitacoes ainda nao atribuidas
          atribuidas,    % SolId => AtId
          respostas,     % SolId => {AtId, Situacao}
          inesperadas,   % respostas duplicadas ou de id desconhecido
          ...}).
```

Toda mensagem carrega o pid de quem mandou (`{tarefa, Coord, Sol}`, `{resposta, Pid, AtId, SolId, Situacao}`), e o atendente só aceita tarefa que venha do seu coordenador (o `Coord` já está ligado no padrão do `receive`).

A correlação das respostas é pelo `SolId` e não pela ordem. Quando chega uma resposta, o coordenador confere em `atribuidas` se aquela solicitação foi mesmo para aquele atendente e em `respostas` se ela ainda não tinha sido respondida. Se alguma das duas falhar, a resposta vai para `inesperadas` e não é contada.

O coordenador também recebe `'DOWN'` dos monitores: se um atendente morrer no meio, ele para com erro em vez de ficar esperando para sempre uma resposta que não vai chegar.

### Resultados e encerramento

O laço `distribuir/1` termina pelo guard `map_size(Respostas) =:= Total`, ou seja, quando chegaram as 18 respostas. Depois disso:

1. O coordenador manda `{encerrar, self()}` para **todos** os atendentes.
2. Cada atendente responde `{encerrado, self(), AtId, Feitos}` e a função dele termina, ou seja, o processo sai com motivo `normal`.
3. Para cada atendente, o coordenador espera o `encerrado` **e** o `{'DOWN', Ref, process, Pid, normal}` do monitor. Assim ele tem certeza de que o processo morreu mesmo.
4. Só então ele manda o relatório para o main e termina. O main também espera o `'DOWN'` do coordenador antes de imprimir.

O resumo por categoria (total, resolvidas, encaminhadas) é montado a partir do mapa de respostas e comparado com o resumo esperado, calculado aplicando `analisar/1` em sequência.

### Exemplo de execução

Esperado: 18 respostas. financeiro 4/4/0, técnico 5/4/1, cadastro 5/5/0, cancelamento 4/0/4 (total/resolvidas/encaminhadas), e soma dos atendimentos igual a 18.

```
18 solicitacoes geradas, 4 atendentes

[Coordenador] solicitacao  1 (tecnico: erro ao gerar relatorio) -> atendente 1
[Coordenador] solicitacao  2 (cadastro: corrigir CPF) -> atendente 2
[Coordenador] solicitacao  3 (cancelamento: cancelar plano) -> atendente 3
[Coordenador] solicitacao  4 (financeiro: segunda via de boleto) -> atendente 4
[Coordenador] resposta da solicitacao  4 (atendente 4): resolvida
[Coordenador] solicitacao  5 (tecnico: lentidao no app) -> atendente 4
[Coordenador] resposta da solicitacao  5 (atendente 4): resolvida
[Coordenador] solicitacao  6 (cadastro: alterar endereco) -> atendente 4
[Coordenador] resposta da solicitacao  2 (atendente 2): resolvida
[Coordenador] solicitacao  7 (cancelamento: desistencia de compra) -> atendente 2
[Coordenador] resposta da solicitacao  3 (atendente 3): encaminhada
[Coordenador] solicitacao  8 (financeiro: estorno pendente) -> atendente 3
[Coordenador] resposta da solicitacao  1 (atendente 1): resolvida
...
[Coordenador] resposta da solicitacao 12 (atendente 4): resolvida
[Coordenador] resposta da solicitacao 15 (atendente 2): encaminhada
[Coordenador] resposta da solicitacao 18 (atendente 3): resolvida
[Coordenador] resposta da solicitacao 16 (atendente 1): resolvida

[Coordenador] 18 respostas recebidas, encerrando atendentes
[Atendente 1] encerrado (3 atendimentos, motivo normal)
[Atendente 2] encerrado (4 atendimentos, motivo normal)
[Atendente 3] encerrado (6 atendimentos, motivo normal)
[Atendente 4] encerrado (5 atendimentos, motivo normal)

=========== RESUMO POR CATEGORIA ===========
categoria      total resolvidas encaminhadas   esperado
financeiro         4          4            0   (4/4/0)
tecnico            5          4            1   (5/4/1)
cadastro           5          5            0   (5/5/0)
cancelamento       4          0            4   (4/0/4)

Por atendente:
  atendente 1: [1,9,16]
  atendente 2: [2,7,14,15]
  atendente 3: [3,8,11,13,17,18]
  atendente 4: [4,5,6,10,12]

Respostas recebidas: 18 (esperado 18)
Faltando: []  Duplicadas/inesperadas: []
Resposta veio do atendente que recebeu a tarefa: true
Atendentes encerrados normalmente: true (soma de atendimentos 18)
OK: cada solicitacao atribuida a um atendente e respondida uma vez
```
Dá pra ver que as respostas chegam fora de ordem (a 4 chega antes da 1) e que a divisão entre os atendentes muda de uma execução para outra.

### Testes

`make test` (ou `make docker-test`) chama `atendimento:teste/0`, que roda 30 rodadas de 6 combinações (15 e 40 solicitações × 1, 3 e 8 atendentes), 180 execuções no total. Em cada uma ele confere:

- se toda solicitação teve exatamente uma resposta (nada em `faltando` nem em `inesperadas`);
- se a resposta veio do atendente para quem a solicitação foi atribuída;
- se a soma dos atendimentos informados pelos atendentes é igual ao número de solicitações;
- se o resumo por categoria é igual ao esperado;
- se todos os atendentes saíram com motivo `normal`;
- se o `erlang:system_info(process_count)` no final é igual ao do começo, ou seja, se não sobrou nenhum processo.

```
180 execucoes, falhas: []
TESTES OK
```

---

## Questão 7 – Fila compartilhada de chamados (Linda com Python)

### Biblioteca

- **pylinda 0.1.4** (PyPI: `pip install pylinda==0.1.4`), licença MIT.
- É um espaço de tuplas cliente/servidor: `pylinda.server(PORT)` roda um servidor TCP com `select` que guarda as tuplas, e cada processo abre sua conexão com `pylinda.client`. Os campos formais (curingas) são objetos `pylinda.Any(tipo)`, que casam com qualquer valor daquele tipo.

Correspondência com as primitivas do Linda (encapsulada na classe `EspacoDeTuplas` de `chamados.py`):

| Linda | pylinda | Comportamento |
|---|---|---|
| `out(t)` | `client.post(t)` | publica a tupla, não bloqueia |
| `in(t)` | `client.in_b(t)` | retira uma tupla que case com o padrão, **bloqueia** até existir |
| `rd(t)` | `client.rd_b(t)` | lê sem remover, **bloqueia** até existir |
| `inp(t)` | `client.in_n(t)` | retira sem bloquear (devolve `False` se não tiver) |
| `rdp(t)` | `client.rd_n(t)` | lê sem bloquear (devolve `False` se não tiver) |

O bloqueio é de verdade: quando não existe tupla que case, o servidor guarda o pedido numa lista de espera e não responde, e o cliente fica parado no `recv()` do socket. Só responde quando chega um `out` que case. Não tem nenhum laço consultando o espaço.

### Cuidados com a biblioteca

A pylinda é pequena e tem alguns problemas, então a solução contorna eles sem mudar a semântica:

1. **`rd` bloqueado consome a tupla.** Se um `rd_b` fica esperando e depois chega o `out` correspondente, o servidor entrega a tupla para quem estava esperando e não guarda ela no espaço, ou seja, o `rd` vira um `in`. Pra isso não acontecer, o coordenador publica as tuplas de configuração e faz um `rd` de cada uma **antes** de criar os atendentes. Como `out` e `rd` vão pela mesma conexão TCP, o servidor processa na ordem, e quando o `rd` volta a tupla já está guardada. Daí em diante os `rd` dos atendentes sempre acham a configuração na hora e nunca caem nesse caso. No final o programa confere com `rdp` que as 5 configurações continuam lá.
2. **`auto_connect` responde com a porta errada** (8048), então a conexão é feita direto com `client.attach("127.0.0.1", porta)`.
3. **Lentidão por Nagle.** A biblioteca manda cabeçalho e payload em dois `send()`, e cada operação ficava ~80 ms mais lenta por causa do Nagle + ACK atrasado do TCP. A solução liga `TCP_NODELAY` no socket do cliente e, numa subclasse do servidor, antes de cada `reply`. É só desempenho, o protocolo não muda.
4. O servidor fica preso no laço de serviço dentro do construtor. A subclasse `Servidor` sobrescreve `setup()` pra marcar um `multiprocessing.Event` assim que o socket está escutando, e o coordenador espera esse evento antes de conectar (nada de `sleep`).

### Arquitetura

Processos reais (`multiprocessing.Process`), cada um com sua conexão própria com o espaço:

- **servidor**: o espaço de tuplas (pylinda).
- **coordenador** (processo principal): publica a configuração e os chamados, reúne as resoluções, publica os términos e faz as verificações.
- **3 atendentes**: retiram chamados, consultam a configuração e publicam a resolução.

Tuplas usadas:

| Tupla | Quem publica | Como é usada |
|---|---|---|
| `("config", categoria, prioridade, prazo_h)` | coordenador | persistente, os atendentes só fazem `rd` |
| `("chamado", id, categoria, descricao)` | coordenador | tarefa, retirada com `in` |
| `("chamado", 0, "FIM", "")` | coordenador | término, mesmo padrão da tarefa |
| `("resolucao", id, atendente, categoria, prioridade, prazo)` | atendente | o coordenador retira com `in` |
| `("encerrado", atendente, qtd)` | atendente | o coordenador retira com `in` |

São 5 categorias com configuração: rede (alta, 4h), hardware (média, 24h), software (média, 12h), acesso (alta, 2h) e impressora (baixa, 48h).

Laço do atendente:
```python
while True:
    _, cid, cat, desc = ts.in_(("chamado", INT, STR, STR))   # in: qualquer chamado
    if cid == ID_FIM:
        break
    _, _, prioridade, prazo = ts.rd(("config", cat, STR, INT)) # rd: config da categoria
    time.sleep(random.uniform(0, atraso))                       # simula o atendimento
    ts.out(("resolucao", cid, nome, cat, prioridade, prazo))   # out: resolução
ts.out(("encerrado", nome, feitos))
```

### Comunicação e sincronização

- O espaço de tuplas é o único meio de comunicação entre os processos. Ninguém conhece ninguém: o coordenador não sabe qual atendente vai pegar cada chamado, e os atendentes não sabem quantos colegas existem.
- **Exclusão mútua na retirada:** o servidor processa uma operação por vez, e o `in` remove a tupla na mesma operação em que ela é encontrada. Então dois atendentes nunca recebem o mesmo chamado.
- **Configuração persistente:** como os atendentes só usam `rd` em `("config", ...)`, ela nunca sai do espaço e continua disponível para todos.
- Atendente sem chamado fica bloqueado no `in`, e o coordenador fica bloqueado no `in` da resolução enquanto ela não chega.

### Resultados e encerramento

1. O coordenador faz 15 `in(("resolucao", INT, STR, STR, STR, INT))` e guarda tudo num dicionário pelo id do chamado. Se chegar um id repetido, ele vai para `duplicadas`.
2. Depois disso ele monta a lista de **pendentes** (chamados sem resolução) e confere com `inp` se sobrou algum chamado no espaço.
3. Só **depois das 15 resoluções** ele publica uma tupla `("chamado", 0, "FIM", "")` por atendente. Ela casa com o mesmo padrão `("chamado", INT, STR, STR)` que os atendentes usam pra retirar trabalho, então cada atendente acorda do `in`, vê o id 0 e sai do laço. Como os términos só entram no espaço depois que todos os chamados foram resolvidos, nenhum atendente para com chamado sobrando.
4. Cada atendente publica `("encerrado", nome, qtd)` e termina. O coordenador faz um `in` para cada um e depois `join()` nos processos.
5. Por último ele confere com `rdp` que a configuração continua no espaço e com `inp` que não sobrou resolução nem término esquecido, manda o comando de shutdown para o servidor e faz `join()` nele também.

### Exemplo de execução

Esperado: 15 resoluções, nenhum pendente nem duplicado, 3 atendentes encerrados com soma 15, todos os processos com código de saída 0, e a configuração ainda disponível.

```
[Coordenador] 15 chamados publicados, 3 atendentes
[atendente-1] pegou chamado  1 (hardware: teclado com defeito) prioridade media, prazo 24h
[atendente-2] pegou chamado  2 (software: licenca expirada) prioridade media, prazo 12h
[atendente-3] pegou chamado  3 (acesso: senha bloqueada) prioridade alta, prazo 2h
[Coordenador] resolucao do chamado  2 por atendente-2
[atendente-2] pegou chamado  4 (impressora: impressora offline) prioridade baixa, prazo 48h
[Coordenador] resolucao do chamado  3 por atendente-3
[atendente-3] pegou chamado  5 (rede: VPN nao conecta) prioridade alta, prazo 4h
[Coordenador] resolucao do chamado  1 por atendente-1
...
[Coordenador] resolucao do chamado 13 por atendente-3
[Coordenador] resolucao do chamado 15 por atendente-2
[Coordenador] resolucao do chamado 14 por atendente-1
[atendente-3] recebeu tupla de termino, encerrando (4 chamados)
[atendente-2] recebeu tupla de termino, encerrando (6 chamados)
[atendente-1] recebeu tupla de termino, encerrando (5 chamados)

=========== RESOLUCOES ===========
chamado  1 hardware   teclado com defeito      -> atendente-1 (prioridade media, prazo 24h)
chamado  2 software   licenca expirada         -> atendente-2 (prioridade media, prazo 12h)
chamado  3 acesso     senha bloqueada          -> atendente-3 (prioridade alta, prazo 2h)
chamado  4 impressora impressora offline       -> atendente-2 (prioridade baixa, prazo 48h)
chamado  5 rede       VPN nao conecta          -> atendente-3 (prioridade alta, prazo 4h)
chamado  6 hardware   monitor piscando         -> atendente-1 (prioridade media, prazo 24h)
chamado  7 software   atualizacao travada      -> atendente-2 (prioridade media, prazo 12h)
chamado  8 acesso     criar usuario novo       -> atendente-1 (prioridade alta, prazo 2h)
chamado  9 impressora papel enroscado          -> atendente-3 (prioridade baixa, prazo 48h)
chamado 10 rede       sem acesso a internet    -> atendente-2 (prioridade alta, prazo 4h)
chamado 11 hardware   notebook nao liga        -> atendente-1 (prioridade media, prazo 24h)
chamado 12 software   erro ao abrir planilha   -> atendente-2 (prioridade media, prazo 12h)
chamado 13 acesso     sem permissao na pasta   -> atendente-3 (prioridade alta, prazo 2h)
chamado 14 impressora sem toner                -> atendente-1 (prioridade baixa, prazo 48h)
chamado 15 rede       wifi caindo              -> atendente-2 (prioridade alta, prazo 4h)

Por atendente:
  atendente-1: 5 chamados [1, 6, 8, 11, 14]
  atendente-2: 6 chamados [2, 4, 7, 10, 12, 15]
  atendente-3: 4 chamados [3, 5, 9, 13]

Resolucoes recebidas: 15 (esperado 15)
Pendentes: []  Duplicadas: []  Sobrando no espaco: []
Atendentes encerrados: 3/3, soma dos atendimentos 15
Codigos de saida dos processos: [0, 0, 0, 0]
Tuplas de configuracao ainda disponiveis (rd): True
Sem resolucoes/terminos esquecidos no espaco: True
OK: cada chamado retirado e resolvido por exatamente um atendente
```

### Testes

`make test` roda `test_chamados.py`, que repete a execução 50 vezes para 5 combinações (15/3, 15/5, 30/4 sem atraso, 15/3 e 40/8 com atraso pequeno), 250 execuções no total. As rodadas sem atraso servem pra forçar mais disputa entre os atendentes. Em cada uma a função `verificar` confere:

- 15 (ou N) resoluções, sem duplicadas, sem pendentes e sem chamado sobrando no espaço;
- se a categoria de cada resolução é a do chamado original e se a prioridade/prazo batem com a configuração da categoria (ou seja, o `rd` leu a tupla certa);
- se todos os atendentes mandaram `encerrado` e se a soma dos atendimentos é N;
- se todos os processos (atendentes e servidor) terminaram com código 0;
- se a configuração continua disponível no final (`rdp`) e se o espaço não tem resolução nem término esquecido.

```
250 execucoes, 0 falhas
TESTES OK
```
Também conferi com `pgrep` que não sobra nenhum processo depois da execução.

---

## Regras gerais atendidas

- **Concorrência real:** goroutines no Go, processos da BEAM no Erlang e processos do sistema operacional (`multiprocessing`) no Python, sempre com pelo menos 3 trabalhadores.
- **Sem espera ocupada:** quem espera fica bloqueado em `range`/receive de canal (Go), `receive` (Erlang) ou no `in`/`rd` bloqueante (Linda).
- **`sleep` só simula processamento:** em nenhum lugar ele é usado para esperar outra tarefa.
- **Independente da ordem:** os resultados são sempre associados por id (pedido, solicitação, chamado) e não pela ordem de chegada.
- **Encerramento:** `close` + `WaitGroup` no Go, mensagem `encerrar` + `monitor`/`'DOWN'` no Erlang, tupla de término no mesmo padrão + `join()` no Linda.
- **Sem perda nem duplicação:** os três programas comparam o obtido com o esperado no final, e os testes repetem isso centenas de vezes.
