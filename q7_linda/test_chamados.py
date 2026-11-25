"""Repete a execucao varias vezes, com e sem atraso, e confere as invariantes."""
import sys

from chamados import executar, verificar

CASOS = [(15, 3, 0.0), (15, 5, 0.0), (30, 4, 0.0), (15, 3, 0.02), (40, 8, 0.01)]
RODADAS = 50

if __name__ == "__main__":
    falhas = []
    for rodada in range(RODADAS):
        for n, a, atraso in CASOS:
            r = executar(n, a, atraso, verbose=False)
            if not verificar(r, n, a):
                falhas.append((rodada, n, a, atraso, r))
    total = RODADAS * len(CASOS)
    print(f"{total} execucoes, {len(falhas)} falhas")
    for f in falhas:
        print("FALHA:", f)
    print("TESTES OK" if not falhas else "TESTES FALHARAM")
    sys.exit(1 if falhas else 0)
