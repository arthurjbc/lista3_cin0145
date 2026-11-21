all: atendimento.beam

atendimento.beam: atendimento.erl
	erlc atendimento.erl

run: atendimento.beam
	erl -noshell -s atendimento main

test: atendimento.beam
	erl -noshell -s atendimento teste

# Para quem nao tem Erlang instalado (usa a imagem oficial)
docker-run:
	docker run --rm --user $$(id -u):$$(id -g) -v "$(CURDIR)":/app -w /app erlang:27-alpine sh -c "erlc atendimento.erl && erl -noshell -s atendimento main"

docker-test:
	docker run --rm --user $$(id -u):$$(id -g) -v "$(CURDIR)":/app -w /app erlang:27-alpine sh -c "erlc atendimento.erl && erl -noshell -s atendimento teste"

clean:
	rm -f *.beam erl_crash.dump

.PHONY: all run test docker-run docker-test clean
