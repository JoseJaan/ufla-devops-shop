# Atividade 4: containerizar a aplicação

Ambiente das medições: Docker Desktop 27.2.0 no Windows 11, amd64, com o
containerd image store. Nesse modo o `docker images` mostra o espaço total em
disco (conteúdo comprimido somado ao descompactado) e o `docker image inspect
--format '{{.Size}}'` mostra o tamanho comprimido. Por isso os números abaixo vêm
em três colunas, e a soma das camadas do `docker history` é a que corresponde à
tabela de `docs/aplicacao.md`.

## 1. Antes e depois

```
$ docker images ufla-shop
REPOSITORY   TAG       IMAGE ID       CREATED              SIZE
ufla-shop    1.0       cd141d341fea   33 seconds ago       125MB
ufla-shop    0.1       c5c88222634e   About a minute ago   479MB
```

| Imagem | `docker images` | `inspect .Size` | soma das camadas |
|---|---|---|---|
| `ufla-shop:0.1` (primeira que funcionou) | 479 MB | 86 MB | ~375 MB |
| `ufla-shop:1.0` (final) | 125 MB | 29 MB | ~96 MB |

A primeira versão já rodava como não root, com HEALTHCHECK e CMD na forma exec,
mas tinha um único estágio:

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
RUN useradd -m app && chown -R app /app
USER app
HEALTHCHECK --interval=5s CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health')"]
CMD ["uvicorn", "app:api", "--host", "0.0.0.0", "--port", "8000"]
```

## 2. O que mudou e quanto cada corte economizou

Camadas pesadas da primeira versão (`docker history ufla-shop:0.1`):

```
91MB     RUN /bin/sh -c useradd -m app && chown -R app /app
90.9MB   COPY . . # buildkit
68.5MB   RUN /bin/sh -c pip install -r requirements.txt
```

Camadas da versão final (`docker history ufla-shop:1.0`):

```
24.6kB   COPY static/ ./static/
53.2kB   COPY app/ ./app/
33.4MB   COPY /install /usr/local
36.9kB   RUN adduser -D -H -u 10001 app && mkdir /dados && chown app /dados
50.4MB   (base) python 3.12 do alpine
2.83MB   (base) apk add
9.08MB   (base) alpine-minirootfs
```

| Mudança | Economia | Por quê |
|---|---|---|
| `dados/` e `*.log` no `.dockerignore`, `COPY app/` e `COPY static/` no lugar de `COPY . .` | ~91 MB | o `COPY . .` levou o `dados/access.log` da Atividade 2 (87 MB, ignorado pelo git mas presente na pasta); agora só entram os 80 kB de código |
| fim do `chown -R /app` | ~91 MB | o `chown` recursivo regrava cada arquivo numa camada nova e duplica tudo o que o COPY trouxe; o usuário só precisa escrever em `/dados`, que é o único diretório com `chown` |
| build multi-stage com `pip install --no-cache-dir --no-compile --prefix=/install` e remoção de `__pycache__` e `tests` dos pacotes | ~35 MB (68,5 para 33,4 MB) | o estágio final recebe só os pacotes instalados, sem cache do pip, sem bytecode gerado na instalação e sem as suítes de teste das bibliotecas |
| base `python:3.12-alpine` no lugar de `python:3.12-slim` | ~65 MB (cerca de 125 para 62 MB) | `musl` e busybox no lugar de `glibc` e coreutils do Debian; todas as dependências têm wheels para `musl`, então nada é compilado |
| `PYTHONDONTWRITEBYTECODE=1` | evita crescimento em tempo de execução | o Python não grava `.pyc` na camada gravável do container |

Uma tentativa que não economizou: rodar `pip uninstall pip setuptools` no estágio
final. O pip mora numa camada da imagem base, e apagá-lo numa camada posterior só
acrescenta *whiteouts* (a camada nova pesou 242 kB a mais). O passo foi removido.

`SQLITE_PATH=/dados/loja.db` aponta o banco para um diretório do usuário `app`, o
que evita o `Permission denied` em `loja.db` sem dar ao usuário escrita sobre o
código.

## 3. Verificação

```
$ docker image inspect --format '{{.Size}}' ufla-shop:1.0
29207050

$ docker run --rm ufla-shop:1.0 id -u
10001

$ docker run --rm ufla-shop:1.0 ls -a
.
..
app
static

$ docker run -d --name loja -p 8000:8000 ufla-shop:1.0
$ sleep 10 && docker inspect --format '{{.State.Health.Status}}' loja
healthy

$ curl -s localhost:8000/health
{"status":"ok","versao":"1.0.0"}

$ curl -s localhost:8000/api/produtos | python -c "import sys,json; print(len(json.load(sys.stdin)))"
12

$ time docker stop loja
loja

real    0m0,777s
user    0m0,045s
sys     0m0,015s
```

## 4. Por que o HEALTHCHECK consulta `/health` e não `/ready`?

`/health` responde se o processo está vivo e nunca toca em banco ou cache, então
o container só fica `unhealthy` quando o problema está nele mesmo e reiniciá-lo
resolve. `/ready` depende de PostgreSQL e Redis, e usá-lo marcaria o container
como doente (e o faria ser reiniciado em vão) toda vez que uma dependência externa
caísse, problema que reiniciar a API não conserta.
