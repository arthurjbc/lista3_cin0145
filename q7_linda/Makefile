VENV = .venv
PY = $(VENV)/bin/python

$(PY):
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -r requirements.txt

install: $(PY)

run: $(PY)
	$(PY) chamados.py

test: $(PY)
	$(PY) test_chamados.py

clean:
	rm -rf __pycache__ linda_server.log

.PHONY: install run test clean
