"""
Questao 7 - Fila compartilhada de chamados de suporte (Linda com pylinda 0.1.4)

Arquitetura:
  - 1 processo servidor do espaco de tuplas (pylinda.server)
  - 1 processo coordenador (este, o main)
  - N processos atendentes (multiprocessing.Process), cada um com sua
    propria conexao (pylinda.client) com o espaco de tuplas

Tuplas usadas:
  ("config",    categoria, prioridade, prazo_horas)            persistente, so rd
  ("chamado",   id, categoria, descricao)                        tarefa, retirada com in
  ("chamado",   0, "FIM", "")                                    termino (mesmo padrao)
  ("resolucao", id, atendente, categoria, prioridade, prazo)     publicada pelo atendente
  ("encerrado", atendente, qtd_chamados)                         atendente avisando que saiu
"""

import argparse
import contextlib
import io
import multiprocessing as mp
import random
import socket
import sys
import time

import pylinda
from pylinda import Any

HOST = "127.0.0.1"
PORTA_PADRAO = 21643

# Casam com qualquer valor do tipo (os "formais" do Linda)
INT = Any(int)
STR = Any(str)

# Configuracao por categoria: (prioridade, prazo em horas)
CONFIG = {
    "rede":       ("alta", 4),
    "hardware":   ("media", 24),
    "software":   ("media", 12),
    "acesso":     ("alta", 2),
    "impressora": ("baixa", 48),
}

DESCRICOES = {
    "rede":       ["wifi caindo", "sem acesso a internet", "VPN nao conecta"],
    "hardware":   ["monitor piscando", "teclado com defeito", "notebook nao liga"],
    "software":   ["erro ao abrir planilha", "atualizacao travada", "licenca expirada"],
    "acesso":     ["senha bloqueada", "sem permissao na pasta", "criar usuario novo"],
    "impressora": ["papel enroscado", "impressora offline", "sem toner"],
}

ID_FIM = 0  # id do chamado de termino


def gerar_chamados(n):
    cats = list(CONFIG)
    chamados = []
    for i in range(1, n + 1):
        cat = cats[i % len(cats)]
        desc = DESCRICOES[cat][i % len(DESCRICOES[cat])]
        chamados.append((i, cat, desc))
    return chamados


# ----------------------------------------------------------------------
# Correspondencia com as primitivas do Linda
#   out(t)  -> client.post(t)   publica (nao bloqueia, nao responde)
#   in(t)   -> client.in_b(t)   retira, bloqueia ate existir tupla que case
#   rd(t)   -> client.rd_b(t)   le sem remover, bloqueia ate existir
#   inp(t)  -> client.in_n(t)   retira sem bloquear (False se nao existir)
#   rdp(t)  -> client.rd_n(t)   le sem bloquear (False se nao existir)
# ----------------------------------------------------------------------
class EspacoDeTuplas:
    def __init__(self, porta):
        self.c = pylinda.client(PORT=porta)
        with contextlib.redirect_stdout(io.StringIO()):  # o attach imprime na tela
            self.c.attach(HOST, porta)
        # A pylinda manda cabecalho e payload em dois send(); sem NODELAY o
        # Nagle + ACK atrasado deixa cada operacao ~80 ms mais lenta.
        self.c.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def out(self, t):
        self.c.post(t)

    def in_(self, t):
        return self.c.in_b(t)

    def rd(self, t):
        return self.c.rd_b(t)

    def inp(self, t):
        return self.c.in_n(t)

    def rdp(self, t):
        return self.c.rd_n(t)

    def desligar_servidor(self):
        self.c.reply(None, "shutdown")

    def fechar(self):
        self.c.sock.close()


# ----------------------------------------------------------------------
# Servidor do espaco de tuplas
# ----------------------------------------------------------------------
class Servidor(pylinda.server):
    """So acrescenta um Event avisando que o socket ja esta escutando."""

    def __init__(self, porta, pronto):
        self.pronto = pronto
        super().__init__(PORT=porta)  # fica no laco de servico ate o shutdown

    def setup(self):
        super().setup()
        self.pronto.set()

    def reply(self, sock, term):
        # mesmo motivo do NODELAY no cliente; nao muda o protocolo
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        super().reply(sock, term)


def processo_servidor(porta, pronto, log):
    # a pylinda imprime cada operacao; manda isso para um arquivo de log
    sys.stdout = open(log, "w", buffering=1)
    Servidor(porta, pronto)


# ----------------------------------------------------------------------
# Atendente
# ----------------------------------------------------------------------
def atendente(nome, porta, atraso, verbose):
    ts = EspacoDeTuplas(porta)
    feitos = 0
    while True:
        # retira QUALQUER chamado; bloqueia se nao houver nenhum
        _, cid, cat, desc = ts.in_(("chamado", INT, STR, STR))
        if cid == ID_FIM:
            break
        # consulta a configuracao da categoria sem remover
        _, _, prioridade, prazo = ts.rd(("config", cat, STR, INT))
        if verbose:
            print(f"[{nome}] pegou chamado {cid:2d} ({cat}: {desc}) prioridade {prioridade}, prazo {prazo}h",
                  flush=True)
        if atraso > 0:
            time.sleep(random.uniform(0, atraso))  # simula o atendimento
        ts.out(("resolucao", cid, nome, cat, prioridade, prazo))
        feitos += 1
    ts.out(("encerrado", nome, feitos))
    if verbose:
        print(f"[{nome}] recebeu tupla de termino, encerrando ({feitos} chamados)", flush=True)
    ts.fechar()


# ----------------------------------------------------------------------
# Coordenador
# ----------------------------------------------------------------------
def executar(n_chamados=15, n_atendentes=3, atraso=0.4, verbose=True, porta=PORTA_PADRAO,
             log="linda_server.log"):
    pronto = mp.Event()
    servidor = mp.Process(target=processo_servidor, args=(porta, pronto, log))
    servidor.start()
    if not pronto.wait(timeout=10):
        servidor.terminate()
        raise RuntimeError(f"servidor Linda nao subiu na porta {porta}")

    ts = EspacoDeTuplas(porta)

    # 1) configuracao persistente. O rd logo depois do out confirma que a tupla
    #    ja esta guardada no espaco antes de qualquer atendente existir.
    for cat, (prio, prazo) in CONFIG.items():
        ts.out(("config", cat, prio, prazo))
    for cat in CONFIG:
        ts.rd(("config", cat, STR, INT))

    # 2) atendentes (ficam bloqueados no in ate aparecer chamado)
    nomes = [f"atendente-{i}" for i in range(1, n_atendentes + 1)]
    procs = [mp.Process(target=atendente, args=(nome, porta, atraso, verbose)) for nome in nomes]
    for p in procs:
        p.start()

    # 3) chamados no quadro compartilhado
    chamados = gerar_chamados(n_chamados)
    for cid, cat, desc in chamados:
        ts.out(("chamado", cid, cat, desc))
    if verbose:
        print(f"[Coordenador] {len(chamados)} chamados publicados, {n_atendentes} atendentes", flush=True)

    # 4) reune as resolucoes (a ordem de chegada nao importa)
    resolucoes = {}
    duplicadas = []
    for _ in range(n_chamados):
        _, cid, nome, cat, prio, prazo = ts.in_(("resolucao", INT, STR, STR, STR, INT))
        if cid in resolucoes:
            duplicadas.append(cid)
        else:
            resolucoes[cid] = (nome, cat, prio, prazo)
        if verbose:
            print(f"[Coordenador] resolucao do chamado {cid:2d} por {nome}", flush=True)

    pendentes = [cid for cid, _, _ in chamados if cid not in resolucoes]
    # confere se nao sobrou chamado no espaco (inp nao bloqueia)
    sobrando = []
    while (t := ts.inp(("chamado", INT, STR, STR))):
        sobrando.append(t)

    # 5) uma tupla de termino por atendente, no mesmo padrao dos chamados
    for _ in procs:
        ts.out(("chamado", ID_FIM, "FIM", ""))
    encerrados = {}
    for _ in procs:
        _, nome, feitos = ts.in_(("encerrado", STR, INT))
        encerrados[nome] = feitos
    for p in procs:
        p.join()

    # 6) verificacoes finais no espaco
    config_ok = all(ts.rdp(("config", cat, STR, INT)) for cat in CONFIG)
    resto_resolucao = ts.inp(("resolucao", INT, STR, STR, STR, INT))
    resto_fim = ts.inp(("chamado", INT, STR, STR))

    ts.desligar_servidor()
    ts.fechar()
    servidor.join()

    return {
        "chamados": chamados,
        "resolucoes": resolucoes,
        "duplicadas": duplicadas,
        "pendentes": pendentes,
        "sobrando": sobrando,
        "encerrados": encerrados,
        "exitcodes": [p.exitcode for p in procs] + [servidor.exitcode],
        "config_ok": config_ok,
        "espaco_limpo": not resto_resolucao and not resto_fim,
    }


def verificar(r, n_chamados, n_atendentes):
    # cada resolucao tem que trazer a prioridade/prazo lidos da config da sua categoria
    configs_certas = all((prio, prazo) == CONFIG[cat]
                         for (_, cat, prio, prazo) in r["resolucoes"].values())
    categorias_certas = all(r["resolucoes"][cid][1] == cat for cid, cat, _ in r["chamados"]
                            if cid in r["resolucoes"])
    return (len(r["resolucoes"]) == n_chamados
            and not r["duplicadas"] and not r["pendentes"] and not r["sobrando"]
            and len(r["encerrados"]) == n_atendentes
            and sum(r["encerrados"].values()) == n_chamados
            and all(c == 0 for c in r["exitcodes"])
            and r["config_ok"] and r["espaco_limpo"]
            and configs_certas and categorias_certas)


def imprimir(r, n_chamados, n_atendentes):
    print("\n=========== RESOLUCOES ===========")
    for cid, cat, desc in r["chamados"]:
        if cid in r["resolucoes"]:
            nome, _, prio, prazo = r["resolucoes"][cid]
            print(f"chamado {cid:2d} {cat:<10} {desc:<24} -> {nome} (prioridade {prio}, prazo {prazo}h)")
        else:
            print(f"chamado {cid:2d} {cat:<10} {desc:<24} -> PENDENTE")

    print("\nPor atendente:")
    for nome in sorted(r["encerrados"]):
        ids = sorted(cid for cid, (n, *_) in r["resolucoes"].items() if n == nome)
        print(f"  {nome}: {len(ids)} chamados {ids}")

    print(f"\nResolucoes recebidas: {len(r['resolucoes'])} (esperado {n_chamados})")
    print(f"Pendentes: {r['pendentes']}  Duplicadas: {r['duplicadas']}  Sobrando no espaco: {r['sobrando']}")
    print(f"Atendentes encerrados: {len(r['encerrados'])}/{n_atendentes}, "
          f"soma dos atendimentos {sum(r['encerrados'].values())}")
    print(f"Codigos de saida dos processos: {r['exitcodes']}")
    print(f"Tuplas de configuracao ainda disponiveis (rd): {r['config_ok']}")
    print(f"Sem resolucoes/terminos esquecidos no espaco: {r['espaco_limpo']}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chamados", type=int, default=15)
    ap.add_argument("--atendentes", type=int, default=3)
    ap.add_argument("--atraso", type=float, default=0.4, help="atraso maximo simulado, em segundos")
    ap.add_argument("--porta", type=int, default=PORTA_PADRAO)
    a = ap.parse_args()

    r = executar(a.chamados, a.atendentes, a.atraso, True, a.porta)
    imprimir(r, a.chamados, a.atendentes)
    if verificar(r, a.chamados, a.atendentes):
        print("OK: cada chamado retirado e resolvido por exatamente um atendente")
    else:
        print("ERRO: resultado diferente do esperado")
        sys.exit(1)


if __name__ == "__main__":
    main()
