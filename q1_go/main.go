package main

import (
	"flag"
	"fmt"
	"os"
	"time"
)

func main() {
	nPedidos := flag.Int("pedidos", 25, "quantidade de pedidos (>= 20)")
	nTrab := flag.Int("trabalhadores", 4, "quantidade de goroutines trabalhadoras (>= 3)")
	atrasoMs := flag.Int("atraso", 100, "atraso maximo simulado por pedido, em ms")
	flag.Parse()

	pedidos := GerarPedidos(*nPedidos)
	fmt.Printf("%d pedidos gerados, %d trabalhadores\n\n", len(pedidos), *nTrab)

	resumo := Processar(pedidos, *nTrab, time.Duration(*atrasoMs)*time.Millisecond, true)

	expV, expI, expT := Esperado(pedidos)

	fmt.Println()
	fmt.Println("=========== RESUMO ===========")
	fmt.Printf("Pedidos processados: %d (esperado %d)\n", resumo.Processados, len(pedidos))
	fmt.Printf("Pedidos validos:     %d (esperado %d)\n", resumo.Validos, expV)
	fmt.Printf("Pedidos invalidos:   %d (esperado %d)\n", resumo.Invalidos, expI)
	fmt.Printf("Valor total validos: %s (esperado %s)\n", reais(resumo.ValorTotal), reais(expT))
	fmt.Printf("Duplicados: %v  Faltando: %v\n", resumo.Duplicados, resumo.Faltando)

	ok := resumo.Processados == len(pedidos) && resumo.Validos == expV &&
		resumo.Invalidos == expI && resumo.ValorTotal == expT &&
		len(resumo.Duplicados) == 0 && len(resumo.Faltando) == 0
	if ok {
		fmt.Println("OK: todos os pedidos processados exatamente uma vez")
	} else {
		fmt.Println("ERRO: resultado diferente do esperado")
		os.Exit(1)
	}
}
