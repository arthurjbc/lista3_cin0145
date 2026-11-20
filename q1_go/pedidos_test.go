package main

import (
	"runtime"
	"testing"
	"time"
)

// Roda o processamento várias vezes com quantidades diferentes de pedidos e
// trabalhadores e compara com o cálculo sequencial.
func TestProcessarIgualSequencial(t *testing.T) {
	for rodada := 0; rodada < 50; rodada++ {
		for _, nTrab := range []int{1, 3, 8} {
			pedidos := GerarPedidos(20 + rodada)
			r := Processar(pedidos, nTrab, time.Millisecond, false)
			v, i, tot := Esperado(pedidos)
			if r.Processados != len(pedidos) || r.Validos != v || r.Invalidos != i || r.ValorTotal != tot {
				t.Fatalf("rodada %d trab %d: obtido %+v, esperado v=%d i=%d t=%d", rodada, nTrab, r, v, i, tot)
			}
			if len(r.Duplicados) > 0 || len(r.Faltando) > 0 {
				t.Fatalf("duplicados %v faltando %v", r.Duplicados, r.Faltando)
			}
			for _, p := range pedidos {
				if r.Resultados[p.ID].PedidoID != p.ID {
					t.Fatalf("resultado do pedido %d nao associado", p.ID)
				}
			}
		}
	}
}

// Depois de Processar retornar não pode sobrar goroutine viva.
func TestSemGoroutinesVazando(t *testing.T) {
	antes := runtime.NumGoroutine()
	Processar(GerarPedidos(30), 5, time.Millisecond, false)
	// a goroutine que fecha o canal de resultados pode ainda estar retornando
	for i := 0; i < 100 && runtime.NumGoroutine() > antes; i++ {
		runtime.Gosched()
	}
	if depois := runtime.NumGoroutine(); depois > antes {
		t.Fatalf("goroutines antes=%d depois=%d", antes, depois)
	}
}
