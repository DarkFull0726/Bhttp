#!/usr/bin/env bash

set -uo pipefail

DESTDIR="/usr/local/lib/bhttp"
SERVER_PY="$DESTDIR/bhttp-server.py"
UNIT="/etc/systemd/system/bhttp.service"
SERVICE="bhttp"
CANDIDATOS=(8080 80 8443 443 2082 2095 8880 2052 3128)

PUERTO=""; SSHPORT=22; DESINSTALAR=0; NUEVO_USER=""; NUEVO_PASS=""; SOLO_DIAG=0

while [ $# -gt 0 ]; do
  case "$1" in
    --puerto|-p)     shift; PUERTO="$1" ;;
    --ssh-puerto)    shift; SSHPORT="$1" ;;
    --crear-usuario) shift; NUEVO_USER="$1" ;;
    --clave)         shift; NUEVO_PASS="$1" ;;
    --desinstalar)   DESINSTALAR=1 ;;
    --diag)          SOLO_DIAG=1 ;;
    -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
    *)               echo "opcion desconocida: $1" >&2; exit 2 ;;
  esac
  shift
done

rojo()  { printf '\033[31m%s\033[0m\n' "$*"; }
verde() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
paso()  { printf '\n[%s] %s\n' "$1" "$2"; }

[ "$(id -u 2>/dev/null || echo 0)" != 0 ] && { rojo "Ejecutalo como root:  sudo bash $0"; exit 2; }

crear_usuario() {
  local u="$1" p="$2"
  if id "$u" >/dev/null 2>&1; then
    info "el usuario '$u' ya existe; solo actualizo la clave"
  else
    useradd -M -s /bin/bash "$u" \
      || { rojo "no pude crear el usuario '$u'"; return 1; }
    info "usuario '$u' creado (shell /bin/bash, compatible con el forward del tunel)"
  fi
  if [ -z "$p" ]; then
    p="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 12)"
    [ -z "$p" ] && p="dt$(date +%s | tail -c 7)"
    info "clave generada automaticamente"
  fi
  echo "$u:$p" | chpasswd || { rojo "no pude poner la clave"; return 1; }
  USER_FINAL="$u"; PASS_FINAL="$p"
  return 0
}

diagnostico_ssh() {
  paso "diag" "Comprobando el entorno SSH/red"
  local cfg="/etc/ssh/sshd_config" fwd=""
  [ -r "$cfg" ] && fwd="$(grep -iE '^[[:space:]]*AllowTcpForwarding' "$cfg" | tail -1 | awk '{print tolower($2)}')"
  if [ "$fwd" = "no" ]; then
    rojo "  AllowTcpForwarding no  -> el tunel NO podra salir. Cambialo a yes:"
    echo "     sed -i 's/^[[:space:]]*AllowTcpForwarding.*/AllowTcpForwarding yes/' $cfg"
    echo "     systemctl restart ssh"
  else
    info "AllowTcpForwarding: ${fwd:-yes (por defecto)} -> OK"
  fi
  if timeout 5 bash -c 'exec 3<>/dev/tcp/8.8.8.8/53' 2>/dev/null; then
    info "salida TCP a 8.8.8.8:53 (DNS): OK"
  else
    rojo "  La VPS NO alcanza 8.8.8.8:53 por TCP -> el DNS del tunel fallara."
    echo "     Revisa el firewall de salida del proveedor / la red de la VPS."
  fi
  if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -qE ":$SSHPORT\b"; then
    info "sshd escuchando en el puerto $SSHPORT: OK"
  else
    rojo "  No veo sshd escuchando en el puerto $SSHPORT (backend del tunel)."
    echo "     Comprueba:  systemctl status ssh"
  fi
}

if [ -n "$NUEVO_USER" ]; then
  echo "=== Crear usuario para el tunel ==="
  if crear_usuario "$NUEVO_USER" "$NUEVO_PASS"; then
    verde "Usuario listo:"
    echo "   usuario : $USER_FINAL"
    echo "   clave   : $PASS_FINAL"
    echo
    echo "   Ponlos en la app (campos usuario/clave del SSH)."
  fi
  [ -z "$PUERTO$DESINSTALAR" ] && { echo; echo "Usuario creado. Para (re)instalar el servidor:  sudo bash $0"; exit 0; }
  echo
fi

if [ "$SOLO_DIAG" = 1 ]; then
  echo "=== Diagnostico del entorno del tunel ==="
  diagnostico_ssh
  exit 0
fi

if [ "$DESINSTALAR" = 1 ]; then
  systemctl stop "$SERVICE" 2>/dev/null
  systemctl disable "$SERVICE" 2>/dev/null
  rm -f "$UNIT"; rm -rf "$DESTDIR"
  systemctl daemon-reload 2>/dev/null
  verde "Servidor BHTTP desinstalado."
  exit 0
fi

echo "=== Instalar servidor BHTTP propio ==="

command -v python3 >/dev/null 2>&1 || { rojo "Falta python3. Instalalo:  apt install -y python3"; exit 1; }

paso "1/4" "Puerto"

ocupados() {
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | tail -n +2 | awk '{print $4}' | sed 's/.*://'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk '/^tcp/ {print $4}' | sed 's/.*://'
  fi | grep -E '^[0-9]+$' | sort -u
}
libre() { ! ocupados | grep -qx "$1"; }

primer_libre=""
for p in "${CANDIDATOS[@]}"; do libre "$p" && { primer_libre="$p"; break; }; done

if [ -z "$PUERTO" ]; then
  if [ -t 0 ]; then
    read -r -p "  Puerto para el servidor BHTTP [${primer_libre:-8080}]: " PUERTO
    [ -z "$PUERTO" ] && PUERTO="${primer_libre:-8080}"
  else
    PUERTO="${primer_libre:-8080}"
    info "sin terminal interactiva; elijo el puerto libre $PUERTO"
  fi
fi

if ! [[ "$PUERTO" =~ ^[0-9]+$ ]] || [ "$PUERTO" -lt 1 ] || [ "$PUERTO" -gt 65535 ]; then
  rojo "Puerto invalido: $PUERTO"; exit 1
fi
if ! libre "$PUERTO"; then
  rojo "El puerto $PUERTO ya esta ocupado. Elige otro:  sudo bash $0 --puerto 8081"
  exit 1
fi
info "puerto elegido: $PUERTO   (backend SSH: 127.0.0.1:$SSHPORT)"

paso "2/4" "Instalando el servidor"
mkdir -p "$DESTDIR"

cat > "$SERVER_PY" <<'PYEOF'
#!/usr/bin/env python3
import argparse, asyncio, hashlib, struct, sys

MAGIC = b"BHP1"
LONGPOLL = 2.0   # espera max de un batch vacio a que el backend produzca datos

def log(msg):
    sys.stderr.write("[bhttp] %s\n" % msg); sys.stderr.flush()

def keystream(sess, mode, seq, d, n):
    base = hashlib.sha256(sess + bytes([mode]) + seq.to_bytes(8, "big") + bytes([d]))
    out = bytearray(); c = 0
    while len(out) < n:
        h = base.copy(); h.update(c.to_bytes(4, "big")); out += h.digest(); c += 1
    return bytes(out[:n])

def mask(data, sess, mode, seq, d):
    return bytes(a ^ b for a, b in zip(data, keystream(sess, mode, seq, d, len(data))))

async def amask(data, sess, mode, seq, d):
    if len(data) <= 2048:
        return mask(data, sess, mode, seq, d)
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, mask, data, sess, mode, seq, d)

def probe_reply(mode, size):
    n = size if (mode == 2 and size >= 10) else 10
    out = bytearray(MAGIC + bytes([1, mode]) + size.to_bytes(4, "big"))
    for i in range(10, n):
        out.append((i * 31) & 255)
    return bytes(out)

class Session:
    """Un tunel logico: empareja el flujo BHTTP con la conexion al backend (sshd)."""
    def __init__(self, sess, backend):
        self.sess = sess
        self.backend = backend
        self.cond = asyncio.Condition()
        self.up_next = 0
        self.up_pending = {}
        self.down_raw = bytearray()
        self.down_chunks = {}
        self.down_assign = 0
        self.eof = False
        self.closed = False
        self.br = None      # backend reader
        self.bw = None      # backend writer

    async def connect(self):
        host, port = self.backend
        self.br, self.bw = await asyncio.open_connection(host, port)
        log("sesion %s: conectada al backend %s:%d" % (self.sess.hex()[:8], host, port))
        asyncio.create_task(self._reader())

    async def _reader(self):
        total = 0
        try:
            while True:
                data = await self.br.read(65536)
                if not data:
                    break
                total += len(data)
                async with self.cond:
                    self.down_raw += data
                    self.cond.notify_all()
        except Exception as e:
            log("sesion %s: error leyendo del backend: %s" % (self.sess.hex()[:8], e))
        finally:
            log("sesion %s: el backend cerro (recibidos %d B en bajada)"
                % (self.sess.hex()[:8], total))
            async with self.cond:
                self.eof = True
                self.cond.notify_all()

    async def upload(self, seq, data):
        async with self.cond:
            if data:
                self.up_pending[seq] = data
            while self.up_next in self.up_pending:
                chunk = self.up_pending.pop(self.up_next)
                try:
                    self.bw.write(chunk)
                    await self.bw.drain()
                except Exception:
                    self.closed = True
                self.up_next += 1

    async def download(self, seq, maxlen, deadline):
        if maxlen <= 0:
            maxlen = 1399
        loop = asyncio.get_running_loop()
        async with self.cond:
            while True:
                if seq < self.down_assign:
                    return self.down_chunks.get(seq, b"")
                if seq == self.down_assign:
                    if self.down_raw:
                        take = bytes(self.down_raw[:maxlen]); del self.down_raw[:maxlen]
                        self.down_chunks[self.down_assign] = take
                        self.down_assign += 1
                        self.cond.notify_all()
                        return take
                    if self.eof:
                        self.down_assign += 1
                        self.cond.notify_all()
                        return b""
                if not self.eof and loop.time() < deadline:
                    try:
                        await asyncio.wait_for(self.cond.wait(),
                                               timeout=max(0.01, deadline - loop.time()))
                    except asyncio.TimeoutError:
                        pass
                    continue
                if seq == self.down_assign:
                    self.down_assign += 1
                    self.cond.notify_all()
                return b""

    async def ack(self, seq):
        async with self.cond:
            for k in [k for k in self.down_chunks if k <= seq]:
                del self.down_chunks[k]

    async def close(self):
        async with self.cond:
            self.closed = True
            self.cond.notify_all()
        try:
            self.bw.close()
        except Exception:
            pass

class Server:
    def __init__(self, host, port, backend):
        self.host, self.port, self.backend = host, port, backend
        self.sessions = {}
        self.slock = asyncio.Lock()

    async def get_session(self, sess):
        async with self.slock:
            s = self.sessions.get(sess)
            if s is not None:
                return s
            for old_sid, old in list(self.sessions.items()):
                await old.close()
                del self.sessions[old_sid]
            s = Session(sess, self.backend)
            await s.connect()
            self.sessions[sess] = s
            log("sesion %s: registrada (sesiones vivas: %d)"
                % (sess.hex()[:8], len(self.sessions)))
            return s

    async def handle(self, reader, writer):
        try:
            pending_hdr = None
            first = await reader.readexactly(1)
            if first[0] > 4:
                head = bytearray(first)
                while not head.endswith(b"\r\n\r\n"):
                    head += await reader.readexactly(1)
                    if len(head) > 8192:
                        return
            else:
                pending_hdr = first + await reader.readexactly(28)
            while True:
                if pending_hdr is not None:
                    hdr = pending_hdr
                    pending_hdr = None
                else:
                    hdr = await reader.readexactly(29)
                mode = hdr[0]
                sess = hdr[1:17]
                seq = int.from_bytes(hdr[17:25], "big")
                ln = int.from_bytes(hdr[25:29], "big")
                payload = b""
                if ln and mode in (0, 1, 2, 3):
                    raw = await reader.readexactly(ln)
                    payload = await amask(raw, sess, mode, seq, 0)

                if payload[:4] == MAGIC:  # probe (calibracion / handshake)
                    size = int.from_bytes(payload[6:10], "big") if len(payload) >= 10 else 0
                    pmode = payload[5] if len(payload) >= 6 else mode
                    body = await amask(probe_reply(pmode, size), sess, mode, seq, 1)
                    writer.write(bytes([0]) + len(body).to_bytes(4, "big") + body)
                    await writer.drain()
                    continue

                s = await self.get_session(sess)
                if mode == 1:                       # subida (len 0 = registro)
                    await s.upload(seq, payload)
                    writer.write(bytes([0]) + (0).to_bytes(4, "big"))
                    await writer.drain()
                elif mode == 2:                     # bajada simple (raro)
                    chunk = await s.download(seq, ln if ln > 0 else 1399,
                                             asyncio.get_running_loop().time() + LONGPOLL)
                    self._send_data(writer, sess, mode, seq, chunk)
                    await writer.drain()
                elif mode == 3:                     # lote de bajadas (download real)
                    if len(payload) >= 6:
                        chunk_size = int.from_bytes(payload[0:4], "big"); count = payload[5]
                    else:
                        chunk_size, count = 1399, 1
                    if chunk_size <= 0: chunk_size = 1399
                    if count <= 0: count = 1
                    deadline = asyncio.get_running_loop().time() + LONGPOLL
                    for i in range(count):
                        chunk = await s.download(seq + i, chunk_size, deadline)
                        self._send_data(writer, sess, mode, seq + i, chunk)
                    await writer.drain()
                elif mode == 4:                     # ack
                    await s.ack(seq)
                    writer.write(bytes([0]) + (0).to_bytes(4, "big"))
                    await writer.drain()
                else:
                    return
        except (asyncio.IncompleteReadError, ConnectionError, OSError):
            pass
        except Exception as e:
            log("handle: excepcion inesperada: %r" % e)
        finally:
            try:
                writer.close()
            except Exception:
                pass

    def _send_data(self, writer, sess, mode, seq, data):
        real = len(data)
        masked = mask(data, sess, mode, seq, 1) if data else b""
        body = real.to_bytes(4, "big") + masked
        writer.write(bytes([2]) + len(body).to_bytes(4, "big") + body)

    async def serve(self):
        srv = await asyncio.start_server(self.handle, self.host, self.port, backlog=512)
        print("BHTTP escuchando en %s:%d -> backend %s:%d"
              % (self.host, self.port, self.backend[0], self.backend[1]), flush=True)
        async with srv:
            await srv.serve_forever()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--backend-host", default="127.0.0.1")
    ap.add_argument("--backend-port", type=int, default=22)
    a = ap.parse_args()
    asyncio.run(Server(a.host, a.port, (a.backend_host, a.backend_port)).serve())

if __name__ == "__main__":
    main()
PYEOF

chmod +x "$SERVER_PY"
if ! python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SERVER_PY"; then
  rojo "El servidor quedo mal escrito"; exit 1
fi
info "servidor en $SERVER_PY"

PYBIN="$(command -v python3)"
cat > "$UNIT" <<EOF
[Unit]
Description=Servidor BHTTP (DTunnel) puerto $PUERTO
After=network.target

[Service]
Type=simple
ExecStart=$PYBIN $SERVER_PY --host 0.0.0.0 --port $PUERTO --backend-host 127.0.0.1 --backend-port $SSHPORT
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
info "servicio en $UNIT"

paso "3/4" "Arrancando"
systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null 2>&1 && info "activado en el arranque"
systemctl restart "$SERVICE"

LEVANTADO=0
for _ in $(seq 1 10); do
  estado="$(systemctl is-active "$SERVICE" 2>/dev/null)"
  if [ "$estado" = active ] && ocupados | grep -qx "$PUERTO"; then LEVANTADO=1; break; fi
  [ "$estado" = failed ] && break
  sleep 1
done

if [ "$LEVANTADO" != 1 ]; then
  rojo "El servicio no arranco. Estado: $(systemctl is-active "$SERVICE" 2>/dev/null)"
  journalctl -u "$SERVICE" -n 20 --no-pager 2>/dev/null | sed 's/^/    /'
  exit 1
fi
verde "  servicio activo y escuchando en el puerto $PUERTO"

paso "4/4" "Verificacion del protocolo BHTTP"

VERIF="$(python3 - "$PUERTO" <<'PYV'
import hashlib, socket, sys, os
PORT = int(sys.argv[1]); SESS = os.urandom(16); MAGIC = b"BHP1"
def ks(m,s,d,n):
    o=b""; c=0
    while len(o)<n:
        o+=hashlib.sha256(SESS+bytes([m])+s.to_bytes(8,"big")+bytes([d])+c.to_bytes(4,"big")).digest(); c+=1
    return o[:n]
def mask(x,m,s,d): return bytes(a^b for a,b in zip(x,ks(m,s,d,len(x))))
def rn(sk,n):
    b=b""
    while len(b)<n:
        z=sk.recv(n-len(b))
        if not z: raise EOFError
        b+=z
    return b
def open_sock(): return socket.create_connection(("127.0.0.1",PORT),timeout=6)
def send(sk,mode,seq,payload=b"",lenf=None):
    if lenf is None: lenf=len(payload)
    sk.sendall(bytes([mode])+SESS+seq.to_bytes(8,"big")+lenf.to_bytes(4,"big"))
    if payload: sk.sendall(payload)
def resp(sk):
    st=rn(sk,1)[0]; ln=int.from_bytes(rn(sk,4),"big"); return st, (rn(sk,ln) if ln else b"")
try:
    p=MAGIC+bytes([1,0])+(0).to_bytes(4,"big")
    sk=open_sock(); send(sk,0,0,mask(p,0,0,0)); st,body=resp(sk); sk.close()
    assert st==0 and mask(body,0,0,1)[:4]==MAGIC, "handshake"
    sk=open_sock(); send(sk,1,0,b""); assert resp(sk)[0]==0, "registro"; sk.close()
    sk=open_sock(); send(sk,1,0,mask(b"SSH-2.0-Test\r\n",1,0,0)); resp(sk); sk.close()
    pay=(1399).to_bytes(4,"big")+bytes([0,8])
    sk=open_sock(); sk.settimeout(4); send(sk,3,0,mask(pay,3,0,0))
    back=b""; okfmt=True
    try:
        for i in range(8):
            st,body=resp(sk)
            if st!=2 or len(body)<4: okfmt=False; break
            dl=int.from_bytes(body[0:4],"big")
            if dl!=len(body)-4: okfmt=False; break
            if dl: back+=mask(body[4:4+dl],3,i,1)
            if back.startswith(b"SSH-"): break   # banner recibido: suficiente
    except socket.timeout:
        pass
    sk.close()
    ok = back.startswith(b"SSH-")
    print("HANDSHAKE_OK" if okfmt else "FORMATO_MALO")
    print("TUNEL_OK" if ok else "TUNEL_VACIO")
    print("BANNER="+back[:40].decode("latin1").strip())
except Exception as e:
    print("ERROR="+str(e))
PYV
)"
echo "$VERIF" | sed 's/^/    /'

echo
IP="$(command -v curl >/dev/null 2>&1 && curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null)"
[ -z "$IP" ] && IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

if echo "$VERIF" | grep -q HANDSHAKE_OK; then
  verde "=== LISTO: el servidor BHTTP responde ==="
  echo
  echo "  En la app pon:"
  echo "     host      : ${IP:-<la ip de tu vps>}"
  echo "     puerto    : $PUERTO"
  echo "     protocolo : bhttp"
  echo "     (sin TLS; usa el usuario/clave SSH de esta VPS)"
  echo
  if echo "$VERIF" | grep -q TUNEL_OK; then
    verde "  Tunel al SSH verificado de punta a punta."
  else
    rojo "  El protocolo va, pero el SSH local no respondio."
    echo "  Comprueba que el SSH escuche en el puerto $SSHPORT:  systemctl status ssh"
    echo "  Si tu SSH usa otro puerto:  sudo bash $0 --ssh-puerto <n> --puerto $PUERTO"
  fi
  echo
  diagnostico_ssh
  echo
  echo "  Gestion:  systemctl status $SERVICE | restart | stop"
  echo "  Log en vivo (util si el tunel cae al navegar):  journalctl -u $SERVICE -f"
  echo "  Quitar :  sudo bash $0 --desinstalar"
  exit 0
fi

rojo "=== El servidor arranco pero no valido el protocolo ==="
echo "  Revisa:  journalctl -u $SERVICE -n 30 --no-pager"
exit 1
