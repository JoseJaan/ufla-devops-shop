# Atividade 3: Automatizar de verdade

A aplicação roda como serviço Linux: instalada por `scripts/deploy.sh`, gerenciada pelo
`systemd` (`systemd/`), com backup diário agendado (`scripts/backup.sh` + timer) e o Nginx
como proxy reverso com TLS autoassinado (`nginx/loja.conf`).

Ambiente usado nas evidências: Ubuntu 24.04 (noble) no WSL2 com `systemd` ativo, Nginx 1.24.

| Artefato | Destino na máquina |
|----------|--------------------|
| código (`app/`, `static/`, `requirements.txt`) + venv | `/opt/ufla-shop` (dono root, só leitura para o serviço) |
| `systemd/ufla-shop.env.example` | `/etc/ufla-shop.env.example`, copiado para `/etc/ufla-shop.env` (640, `root:ufla-shop`) |
| `systemd/*.service`, `systemd/*.timer` | `/etc/systemd/system/` |
| `nginx/loja.conf` | `/etc/nginx/sites-available/loja.conf` + link em `sites-enabled` |
| certificado autoassinado | `/etc/ssl/ufla-shop/loja.pem` e `loja.key` (gerados, nunca versionados) |
| dumps | `/var/backups/ufla-shop/loja-AAAA-MM-DD-HHMM.sql.gz` (mantém os 7 mais recentes) |

## (a) Como rodar o deploy numa máquina limpa

Pré requisitos: Ubuntu/Debian com `systemd` e acesso a `sudo`. O script instala sozinho
PostgreSQL, Redis, Nginx, `python3-venv`, `openssl`, `rsync` e `curl`.

```bash
git clone https://github.com/JoseJaan/ufla-devops-shop.git
cd ufla-devops-shop
git switch atividade-03
sudo ./scripts/deploy.sh
```

O que ele faz, em ordem, sem quebrar nem duplicar nada ao rodar de novo:

1. instala os pacotes (`apt-get install` é idempotente) e sobe PostgreSQL e Redis;
2. cria o usuário de sistema `ufla-shop` só se `id ufla-shop` falhar;
3. cria `/etc/ufla-shop.env` a partir do `.example` **só se ele não existir**, com uma senha
   aleatória (`openssl rand -hex 16`). A senha nunca passa pelo repositório;
4. cria a role e o banco `loja` só se não existirem (a senha da role é sempre alinhada à do env);
5. sincroniza o código com `rsync --delete`, cria o venv só se faltar e roda `pip install`;
6. instala as units, `daemon-reload`, habilita o serviço e o timer e reinicia o serviço;
7. gera o certificado só se a chave não existir, instala o site do Nginx, `nginx -t` e `reload`;
8. healthcheck: até 10 consultas a `http://localhost:8000/ready`, 1 s de intervalo;
   sai com `exit 1` se nunca vier `200`.

Para trocar a senha do banco: edite `/etc/ufla-shop.env` (as duas linhas) e rode o deploy de novo.

Primeira execução, na máquina ainda sem nada da aplicação (sem as linhas `W:` do `apt`,
explicadas na seção (e)):

```
==> instalando pacotes
==> usuario ufla-shop
==> arquivo de ambiente /etc/ufla-shop.env
==>   /etc/ufla-shop.env criado com senha nova
==> banco loja
==> codigo em /opt/ufla-shop
==> diretorio de backup /var/backups/ufla-shop
==> units do systemd
==> certificado TLS
==>   certificado gerado
==> nginx
==> healthcheck http://localhost:8000/ready
==> deploy ok (tentativa 1)
exit=0

$ curl -s localhost:8000/ready
{"status":"ok","banco":"ok","cache":"ok"}
```

## (b) Restart comprovado: `systemctl status` depois do `kill -9`

Observação: `pidof uvicorn` volta vazio, porque o `uvicorn` do venv é um script Python e o
processo se chama `python3`. O `-x` do `pidof` também casa scripts.

```
$ pidof -x uvicorn
10029

$ systemctl status ufla-shop --no-pager -n 0
● ufla-shop.service - ufla-devops-shop API
     Loaded: loaded (/etc/systemd/system/ufla-shop.service; enabled; preset: enabled)
     Active: active (running) since Sun 2026-09-27 19:13:41 -03; 658ms ago
   Main PID: 10029 (uvicorn)
      Tasks: 2 (limit: 19142)
     Memory: 45.2M ()
     CGroup: /system.slice/ufla-shop.service
             └─10029 /opt/ufla-shop/.venv/bin/python3 /opt/ufla-shop/.venv/bin/uvicorn app:api --port 8000

$ sudo kill -9 $(pidof -x uvicorn)
$ sleep 5

$ systemctl status ufla-shop --no-pager -n 6
● ufla-shop.service - ufla-devops-shop API
     Loaded: loaded (/etc/systemd/system/ufla-shop.service; enabled; preset: enabled)
     Active: active (running) since Sun 2026-09-27 19:13:43 -03; 2s ago
   Main PID: 10196 (uvicorn)
      Tasks: 1 (limit: 19142)
     Memory: 42.0M ()
     CGroup: /system.slice/ufla-shop.service
             └─10196 /opt/ufla-shop/.venv/bin/python3 /opt/ufla-shop/.venv/bin/uvicorn app:api --port 8000

Sep 27 19:13:44 Neto uvicorn[10196]: INFO:     Started server process [10196]
Sep 27 19:13:44 Neto uvicorn[10196]: INFO:     Waiting for application startup.
Sep 27 19:13:44 Neto uvicorn[10196]: 2026-09-27 19:13:44,231 INFO loja: ufla-devops-shop 1.0.0 subindo (banco=postgresql, cache=redis, instancia=Neto)
Sep 27 19:13:44 Neto uvicorn[10196]: 2026-09-27 19:13:44,282 INFO loja.banco: banco pronto (modo postgresql)
Sep 27 19:13:44 Neto uvicorn[10196]: INFO:     Application startup complete.
Sep 27 19:13:44 Neto uvicorn[10196]: INFO:     Uvicorn running on http://127.0.0.1:8000 (Press CTRL+C to quit)

$ journalctl -u ufla-shop --no-pager | grep -E "KILL|Failed with|Scheduled restart" | tail -n 3
Sep 27 19:13:41 Neto systemd[1]: ufla-shop.service: Main process exited, code=killed, status=9/KILL
Sep 27 19:13:41 Neto systemd[1]: ufla-shop.service: Failed with result 'signal'.
Sep 27 19:13:43 Neto systemd[1]: ufla-shop.service: Scheduled restart job, restart counter is at 1.

$ ps -o user=,pid=,cmd= -p $(pidof -x uvicorn)
ufla-sh+   10196 /opt/ufla-shop/.venv/bin/python3 /opt/ufla-shop/.venv/bin/uvicorn app:api --port 8000

$ systemctl show ufla-shop -p NRestarts -p User
NRestarts=1
User=ufla-shop
```

O PID mudou de 10029 para 10196, o systemd registrou o `SIGKILL` e o restart, e o processo
novo roda como `ufla-shop` (não root).

## (c) Nginx: HTTPS e redirecionamento

A API só declara `GET` nas rotas, então um `HEAD` (o que `curl -I` envia) voltava
`HTTP/2 405`. O `loja.conf` tem um `map` que repassa `HEAD` como `GET` para a API
(`proxy_method`); o Nginx descarta o corpo na resposta ao cliente. Os demais métodos
seguem inalterados (o `POST` abaixo continua `201`).

```
$ curl -kI https://localhost
HTTP/2 200 
server: nginx/1.24.0 (Ubuntu)
date: Sun, 27 Sep 2026 22:13:47 GMT
content-type: text/html; charset=utf-8
content-length: 1262
accept-ranges: bytes
last-modified: Sun, 27 Sep 2026 21:46:13 GMT
etag: "34edd173ec4a08d36824bf09c4e4adc9"

$ curl -I http://localhost
HTTP/1.1 301 Moved Permanently
Server: nginx/1.24.0 (Ubuntu)
Date: Sun, 27 Sep 2026 22:13:47 GMT
Content-Type: text/html
Content-Length: 178
Connection: keep-alive
Location: https://localhost/

$ curl -sk -X POST https://localhost/api/carrinho -o /dev/null -w "%{http_code}\n"
201

$ curl -ks https://localhost/ready
{"status":"ok","banco":"ok","cache":"ok"}

$ ss -ltn | grep -E ':(80|443|8000)\b'
LISTEN 0      511           0.0.0.0:443       0.0.0.0:*
LISTEN 0      511           0.0.0.0:80        0.0.0.0:*
LISTEN 0      2048        127.0.0.1:8000      0.0.0.0:*
```

A API ouve só em `127.0.0.1:8000` (padrão do uvicorn, sem `--host`); de fora, só o Nginx (80 e 443).

## (d) Backups: `ls -la` depois de três execuções

O nome do dump tem hora e minuto, então as três execuções foram feitas com um minuto
de intervalo.

```
$ for i in 1 2 3; do sudo systemctl start ufla-shop-backup.service; echo "backup $i exit=$?"; [ $i -lt 3 ] && sleep 61; done
backup 1 exit=0
backup 2 exit=0
backup 3 exit=0

$ ls -la /var/backups/ufla-shop
total 20
drwxr-x--- 2 ufla-shop ufla-shop 4096 Sep 27 19:02 .
drwxr-xr-x 3 root      root      4096 Sep 27 18:59 ..
-rw------- 1 ufla-shop ufla-shop 1622 Sep 27 19:00 loja-2026-09-27-1900.sql.gz
-rw------- 1 ufla-shop ufla-shop 1622 Sep 27 19:01 loja-2026-09-27-1901.sql.gz
-rw------- 1 ufla-shop ufla-shop 1620 Sep 27 19:02 loja-2026-09-27-1902.sql.gz

$ journalctl -t backup -n 3 --no-pager
Sep 27 19:00:06 Neto backup[6216]: gerado /var/backups/ufla-shop/loja-2026-09-27-1900.sql.gz (4.0K)
Sep 27 19:01:07 Neto backup[6236]: gerado /var/backups/ufla-shop/loja-2026-09-27-1901.sql.gz (4.0K)
Sep 27 19:02:08 Neto backup[6256]: gerado /var/backups/ufla-shop/loja-2026-09-27-1902.sql.gz (4.0K)

$ systemctl list-timers ufla-shop-backup.timer --no-pager
NEXT                        LEFT LAST PASSED UNIT                   ACTIVATES
Mon 2026-09-28 03:00:00 -03   7h -         - ufla-shop-backup.timer ufla-shop-backup.service

1 timers listed.
```

### Rotação de 7

Foram criados seis dumps falsos, datados de 20 a 25/09, somando 9 arquivos. Depois de
mais um backup (10 arquivos), sobram os 7 mais recentes:

```
$ ls -1 /var/backups/ufla-shop | wc -l
9

$ sudo systemctl start ufla-shop-backup.service; echo exit=$?
exit=0

$ ls -1t /var/backups/ufla-shop; ls -1 /var/backups/ufla-shop | wc -l
loja-2026-09-27-1902.sql.gz
loja-2026-09-27-1901.sql.gz
loja-2026-09-27-1900.sql.gz
loja-2026-09-25-0300.sql.gz
loja-2026-09-24-0300.sql.gz
loja-2026-09-23-0300.sql.gz
loja-2026-09-22-0300.sql.gz
7
```

(O backup dessa execução caiu no mesmo minuto 19:02 e sobrescreveu o arquivo daquele minuto.
Os dumps falsos foram apagados depois do teste.)

### Código de saída com o banco fora do ar

```
$ sudo systemctl stop postgresql
$ sudo systemctl start ufla-shop-backup.service; echo exit=$?
Job for ufla-shop-backup.service failed because the control process exited with error code.
exit=1

$ systemctl show ufla-shop-backup.service -p Result -p ExecMainStatus
Result=exit-code
ExecMainStatus=1

$ journalctl -u ufla-shop-backup.service -n 4 --no-pager -o cat
pg_dump: error: connection to server at "localhost" (127.0.0.1), port 5432 failed: FATAL:  the database system is shutting down
ufla-shop-backup.service: Main process exited, code=exited, status=1/FAILURE
ufla-shop-backup.service: Failed with result 'exit-code'.
Failed to start ufla-shop-backup.service - Backup diario do banco loja (ufla-devops-shop).

$ ls /var/backups/ufla-shop/*.tmp 2>/dev/null | wc -l
0
```

Com `pipefail`, a falha do `pg_dump` derruba o pipeline mesmo com o `gzip` terminando bem;
o `trap` apaga o arquivo temporário, então nenhum dump vazio fica na pasta.

## (e) Idempotência: duas execuções seguidas do deploy

As linhas `W:` vêm de um repositório apt da HashiCorp já configurado nesta máquina, sem
relação com a atividade; o `apt-get update` só avisa e segue.

```
$ sudo ./scripts/deploy.sh 2>&1 | tail -n 15; echo "exit=${PIPESTATUS[0]}"
W: An error occurred during the signature verification. The repository is not updated and the previous index files will be used. GPG error: https://apt.releases.hashicorp.com noble InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY FC9CA96ACA026560
W: Failed to fetch https://apt.releases.hashicorp.com/dists/noble/InRelease  The following signatures couldn't be verified because the public key is not available: NO_PUBKEY FC9CA96ACA026560
W: Some index files failed to download. They have been ignored, or old ones used instead.
==> usuario ufla-shop
==> arquivo de ambiente /etc/ufla-shop.env
==>   /etc/ufla-shop.env ja existe, mantido
==> banco loja
==> codigo em /opt/ufla-shop
==> diretorio de backup /var/backups/ufla-shop
==> units do systemd
==> certificado TLS
==>   certificado ja existe, mantido
==> nginx
==> healthcheck http://localhost:8000/ready
==> deploy ok (tentativa 1)
exit=0

$ sudo ./scripts/deploy.sh 2>&1 | tail -n 15; echo "exit=${PIPESTATUS[0]}"
W: An error occurred during the signature verification. The repository is not updated and the previous index files will be used. GPG error: https://apt.releases.hashicorp.com noble InRelease: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY FC9CA96ACA026560
W: Failed to fetch https://apt.releases.hashicorp.com/dists/noble/InRelease  The following signatures couldn't be verified because the public key is not available: NO_PUBKEY FC9CA96ACA026560
W: Some index files failed to download. They have been ignored, or old ones used instead.
==> usuario ufla-shop
==> arquivo de ambiente /etc/ufla-shop.env
==>   /etc/ufla-shop.env ja existe, mantido
==> banco loja
==> codigo em /opt/ufla-shop
==> diretorio de backup /var/backups/ufla-shop
==> units do systemd
==> certificado TLS
==>   certificado ja existe, mantido
==> nginx
==> healthcheck http://localhost:8000/ready
==> deploy ok (tentativa 1)
exit=0
```

As duas terminam com `exit=0`, sem recriar usuário, senha, banco nem certificado.
