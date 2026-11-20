package main

import (
	"fmt"
	"math/rand"
	"sync"
	"time"
)

// Valores em centavos para não ter erro de arredondamento com float.
type Pedido struct {
	ID            int
	Quantidade    int
	ValorUnitario int
}

type Resultado struct {
	PedidoID    int
	Trabalhador int
	Valido      bool
	Total       int
	Motivo      string
}

type Resumo struct {
	Processados int
	Validos     int
	Invalidos   int
	ValorTotal  int
	Resultados  map[int]Resultado // pedido -> resultado
	Duplicados  []int
	Faltando    []int
}

// Gera n pedidos de forma determinística. Alguns são inválidos de propósito
// (quantidade <= 0 ou valor unitário negativo).
func GerarPedidos(n int) []Pedido {
	pedidos := make([]Pedido, n)
	for i := 0; i < n; i++ {
		id := i + 1
		qtd := 1 + id%5
		valor := 990 + (id*731)%5000
		if id%7 == 0 {
			qtd = 0
		}
		if id%11 == 0 {
			qtd = -2
		}
		if id%9 == 0 {
			valor = -500
		}
		pedidos[i] = Pedido{ID: id, Quantidade: qtd, ValorUnitario: valor}
	}
	return pedidos
}

func Validar(p Pedido) (bool, string) {
	if p.Quantidade <= 0 {
		return false, "quantidade nao positiva"
	}
	if p.ValorUnitario < 0 {
		return false, "valor unitario negativo"
	}
	return true, ""
}

func trabalhador(id int, pedidos <-chan Pedido, resultados chan<- Resultado, wg *sync.WaitGroup, atraso time.Duration, verbose bool) {
	defer wg.Done()
	// O range termina sozinho quando o canal de pedidos é fechado e esvaziado.
	for p := range pedidos {
		if verbose {
			fmt.Printf("[Trabalhador %d] processando pedido %d\n", id, p.ID)
		}
		if atraso > 0 {
			// simula o tempo de processamento (não é sincronização)
			time.Sleep(time.Duration(rand.Int63n(int64(atraso))))
		}
		ok, motivo := Validar(p)
		total := 0
		if ok {
			total = p.Quantidade * p.ValorUnitario
		}
		resultados <- Resultado{PedidoID: p.ID, Trabalhador: id, Valido: ok, Total: total, Motivo: motivo}
	}
	if verbose {
		fmt.Printf("[Trabalhador %d] canal de pedidos fechado, encerrando\n", id)
	}
}

// Rotina coordenadora: única dona do resumo, então não precisa de mutex.
func coordenador(resultados <-chan Resultado, esperados []Pedido, fim chan<- Resumo, verbose bool) {
	r := Resumo{Resultados: make(map[int]Resultado)}
	for res := range resultados {
		if _, existe := r.Resultados[res.PedidoID]; existe {
			r.Duplicados = append(r.Duplicados, res.PedidoID)
			continue
		}
		r.Resultados[res.PedidoID] = res
		r.Processados++
		if res.Valido {
			r.Validos++
			r.ValorTotal += res.Total
		} else {
			r.Invalidos++
		}
		if verbose {
			if res.Valido {
				fmt.Printf("[Coordenador] pedido %2d (trabalhador %d): valido, total %s\n", res.PedidoID, res.Trabalhador, reais(res.Total))
			} else {
				fmt.Printf("[Coordenador] pedido %2d (trabalhador %d): INVALIDO, %s\n", res.PedidoID, res.Trabalhador, res.Motivo)
			}
		}
	}
	for _, p := range esperados {
		if _, ok := r.Resultados[p.ID]; !ok {
			r.Faltando = append(r.Faltando, p.ID)
		}
	}
	fim <- r
}

// Processa os pedidos com nTrab goroutines e devolve o resumo.
func Processar(pedidos []Pedido, nTrab int, atraso time.Duration, verbose bool) Resumo {
	canalPedidos := make(chan Pedido)
	canalResultados := make(chan Resultado)
	fim := make(chan Resumo)
	var wg sync.WaitGroup

	go coordenador(canalResultados, pedidos, fim, verbose)

	for i := 1; i <= nTrab; i++ {
		wg.Add(1)
		go trabalhador(i, canalPedidos, canalResultados, &wg, atraso, verbose)
	}

	for _, p := range pedidos {
		canalPedidos <- p
	}
	// Sem mais pedidos: cada trabalhador sai do range depois de terminar o atual.
	close(canalPedidos)

	// Quando todos os trabalhadores terminarem ninguém mais escreve em
	// resultados, então pode fechar e o coordenador sai do range.
	wg.Wait()
	close(canalResultados)

	return <-fim
}

// Cálculo sequencial, usado só para conferir o resultado concorrente.
func Esperado(pedidos []Pedido) (validos, invalidos, total int) {
	for _, p := range pedidos {
		if ok, _ := Validar(p); ok {
			validos++
			total += p.Quantidade * p.ValorUnitario
		} else {
			invalidos++
		}
	}
	return
}

func reais(centavos int) string {
	return fmt.Sprintf("R$ %d,%02d", centavos/100, centavos%100)
}
