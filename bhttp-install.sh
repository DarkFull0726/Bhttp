#!/usr/bin/env bash
# bhttp-install.sh - instala TU PROPIO servidor BHTTP en la VPS.
#
# No depende de ningun servidor de pago: el protocolo va aqui dentro (implementado
# desde el APK de DTunnel). Solo pide el puerto, escribe el servidor, crea el
# servicio de systemd, lo arranca y lo verifica.
#
# El servidor hace de puente:  app (BHTTP) <-> este servidor <-> SSH local (22).
# Osea: monta un tunel SSH-sobre-BHTTP para saltar el DPI del operador.
#
# Uso:  sudo bash bhttp-install.sh                      pregunta el puerto (o elige libre)
#       sudo bash bhttp-install.sh --puerto 8080        sin preguntar
#       sudo bash bhttp-install.sh --ssh-puerto 22      backend SSH (por defecto 22)
#       sudo bash bhttp-install.sh --crear-usuario juan crea el usuario del tunel
#       sudo bash bhttp-install.sh --crear-usuario juan --clave miclave
#       sudo bash bhttp-install.sh --desinstalar        lo quita todo
#
# El tunel autentica con un usuario del sistema (PAM). Puedes crear uno con
# --crear-usuario; si no pasas --clave, se genera una y se muestra al final.
#
# Requiere: root y python3 (viene en toda VPS moderna).

set -uo pipefail

DESTDIR="/usr/local/lib/bhttp"
SERVER_PY="$DESTDIR/bhttp-server.py"
UNIT="/etc/systemd/system/bhttp.service"
SERVICE="bhttp"
CANDIDATOS=(8080 80 8443 443 2082 2095 8880 2052 3128)

PUERTO=""; SSHPORT=22; DESINSTALAR=0; NUEVO_USER=""; NUEVO_PASS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --puerto|-p)     shift; PUERTO="$1" ;;
    --ssh-puerto)    shift; SSHPORT="$1" ;;
    --crear-usuario) shift; NUEVO_USER="$1" ;;
    --clave)         shift; NUEVO_PASS="$1" ;;
    --desinstalar)   DESINSTALAR=1 ;;
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

# ------------------------------------------------------------ crear usuario SSH
# El tunel autentica con un usuario del sistema (PAM). Este helper crea uno
# pensado solo para el tunel: sin shell de login, solo sirve para el SSH.
crear_usuario() {
  local u="$1" p="$2"
  if id "$u" >/dev/null 2>&1; then
    info "el usuario '$u' ya existe; solo actualizo la clave"
  else
    useradd -M -s /usr/sbin/nologin "$u" 2>/dev/null \
      || useradd -M -s /bin/false "$u" \
      || { rojo "no pude crear el usuario '$u'"; return 1; }
    info "usuario '$u' creado (sin shell, solo para el tunel)"
  fi
  if [ -z "$p" ]; then
    p="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 12)"
    [ -z "$p" ] && p="dt$(date +%s | tail -c 7)"
    info "clave generada automaticamente"
  fi
  echo "$u:$p" | chpasswd || { rojo "no pude poner la clave"; return 1; }
  # nologin no deja abrir sesion SSH normal, pero el tunel (con -N, sin shell) si;
  # aun asi permitimos el shell falso por si el cliente pide PTY.
  USER_FINAL="$u"; PASS_FINAL="$p"
  return 0
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
  # si solo se pidio crear usuario (sin nada mas), terminamos aqui
  [ -z "$PUERTO$DESINSTALAR" ] && { echo; echo "Usuario creado. Para (re)instalar el servidor:  sudo bash $0"; exit 0; }
  echo
fi

# ------------------------------------------------------------ desinstalar
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

# ------------------------------------------------------------ elegir puerto
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

# ------------------------------------------------------------ escribir servidor
paso "2/4" "Instalando el servidor"
mkdir -p "$DESTDIR"

cat > "$SERVER_PY" <<'PYEOF'
#!/usr/bin/env python3
# Servidor BHTTP autonomo para DTunnel.
# Habla el protocolo binario que usa la app (extraido de classes.dex) y hace de
# puente hacia un backend TCP local (por defecto el SSH del sistema, 127.0.0.1:22).
# Solo stdlib: no necesita pip ni el servidor de pago.
#
# Trama peticion : mode(1) sessionId(16) seq(8 BE) len(4 BE) + payload enmascarado
# Trama respuesta: status(1) len(4 BE) + payload enmascarado
# Mascara        : XOR con SHA256(sessionId||mode||seq||dir||contador), dir 0=req 1=resp
# Modos          : 0=probe 1=subida 2=bajada 3=lote 4=ack
import argparse, hashlib, socket, struct, sys, threading, time

MAGIC = b"BHP1"
# long-poll de la bajada: la conexion que pide el proximo slot espera hasta este
# tiempo a que el backend produzca datos, y los entrega EN CUANTO llegan (el
# reader hace notify). Debe quedar por debajo del read-timeout del cliente (~8s)
# para que no vea "Read timed out"; asi cada round-trip del SSH es casi instantaneo
# en vez de esperar el backoff del cliente (auth PAM que tardaba ~37s -> <2s).
LONGPOLL = 6.0

def log(msg):
    # a stderr -> systemd lo captura en `journalctl -u bhttp`
    sys.stderr.write("[bhttp] %s\n" % msg)
    sys.stderr.flush()

def keystream(sess, mode, seq, d, n):
    out = bytearray(); c = 0
    while len(out) < n:
        out += hashlib.sha256(sess + bytes([mode]) +
                              seq.to_bytes(8, "big") + bytes([d]) +
                              c.to_bytes(4, "big")).digest()
        c += 1
    return bytes(out[:n])

def mask(data, sess, mode, seq, d):
    ks = keystream(sess, mode, seq, d, len(data))
    return bytes(a ^ b for a, b in zip(data, ks))

def recvn(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return bytes(buf)

def send_frame(sock, sess, mode, seq, status, payload):
    body = mask(payload, sess, mode, seq, 1) if payload else b""
    sock.sendall(bytes([status]) + len(body).to_bytes(4, "big") + body)

def send_data(sock, sess, mode, seq, data):
    # respuesta de bajada (status 2) en el formato exacto que valida la app:
    #   [4B longitud_real BE EN CLARO] [datos enmascarados]
    # El prefijo son 4 bytes sin mascara (el cliente hace getInt(body,0) sobre el
    # crudo); los datos empiezan en el offset 4 y van enmascarados desde el
    # contador 0. NO lleva relleno: el cliente exige longitud == body.length - 4
    # (BhttpBridge.downloadBatch: arraycopy(body, 4, ...), sub-int body.length-4).
    real = len(data)
    masked = mask(data, sess, mode, seq, 1) if data else b""
    body = real.to_bytes(4, "big") + masked
    sock.sendall(bytes([2]) + len(body).to_bytes(4, "big") + body)

def send_error(sock, msg):
    b = msg.encode()
    sock.sendall(bytes([1]) + len(b).to_bytes(4, "big") + b)  # error va sin mascara


class Session:
    """Un tunel logico: empareja el flujo BHTTP con una conexion al backend."""
    def __init__(self, sess, backend):
        self.sess = sess
        self.backend = backend
        self.lock = threading.Lock()
        self.cond = threading.Condition(self.lock)
        self.up_next = 0                 # siguiente seq de subida a escribir
        self.up_pending = {}             # frames de subida fuera de orden
        self.down_raw = bytearray()      # bytes del backend sin trocear
        self.down_chunks = {}            # seq -> chunk ya cortado
        self.down_assign = 0             # siguiente seq de bajada a asignar
        self.eof = False
        self.closed = False
        self.sock = None
        self._connect()

    def _connect(self):
        host, port = self.backend
        self.sock = socket.create_connection((host, port), timeout=15)
        log("sesion %s: conectada al backend %s:%d" % (self.sess.hex()[:8], host, port))
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        total = 0
        try:
            while True:
                data = self.sock.recv(65536)
                if not data:
                    break
                total += len(data)
                with self.cond:
                    self.down_raw += data
                    self.cond.notify_all()
        except Exception as e:
            log("sesion %s: error leyendo del backend: %s" % (self.sess.hex()[:8], e))
        finally:
            log("sesion %s: el backend cerro (recibidos %d B en bajada)"
                % (self.sess.hex()[:8], total))
            with self.cond:
                self.eof = True
                self.cond.notify_all()

    # --- subida: escribe al backend respetando el orden de seq ---
    def upload(self, seq, data):
        with self.cond:
            if data:
                self.up_pending[seq] = data
            while self.up_next in self.up_pending:
                chunk = self.up_pending.pop(self.up_next)
                try:
                    self.sock.sendall(chunk)
                except Exception:
                    self.closed = True
                self.up_next += 1

    # --- bajada: asigna el slot 'seq' AL INSTANTE (datos si hay, vacio si no) ---
    # El cliente pide TODOS los slots en orden global (ronda 1: 0..255, ronda 2:
    # 256..511, ...) a traves de sus 32 conexiones, y entrega al SSH por nextRead
    # avanzando tambien en los vacios. Un slot vacio no aporta bytes, asi que el
    # stream sale bien MIENTRAS los datos se asignen a slots crecientes. Por eso:
    # cada peticion asigna los slots hasta 'seq', cortando down_raw cuando hay
    # datos y dejando vacio cuando no; el contador avanza SIEMPRE. Sin esperas ni
    # timeouts: los datos que lleguen mas tarde caen en slots que el cliente
    # pedira en la siguiente ronda. (El cliente hace su propio backoff.)
    # 'deadline' (compartido por todo un batch) permite un long-poll corto: el
    # primer slot del batch espera un poco a que haya datos; los siguientes ya lo
    # ven consumido y salen al instante. Reduce el polling y baja la latencia del
    # kex sin colgar (nunca se pierde un slot: los datos futuros caen en slots
    # crecientes que el cliente pedira en la ronda siguiente).
    def download(self, seq, maxlen, deadline):
        if maxlen <= 0:
            maxlen = 1399
        with self.cond:
            while True:
                if seq < self.down_assign:             # slot ya servido: retransmite
                    return self.down_chunks.get(seq, b"")
                if self.down_raw:                      # hay datos: asigna hasta seq
                    while self.down_assign <= seq:
                        if self.down_raw:
                            take = bytes(self.down_raw[:maxlen])
                            del self.down_raw[:maxlen]
                            self.down_chunks[self.down_assign] = take
                        self.down_assign += 1
                    return self.down_chunks.get(seq, b"")
                # sin datos y seq >= down_assign
                if seq == self.down_assign and not self.eof and time.time() < deadline:
                    self.cond.wait(timeout=max(0.01, deadline - time.time()))
                    continue                           # reevalua tras esperar
                while self.down_assign <= seq:         # timeout/futuro/eof: slot vacio
                    self.down_assign += 1
                return b""

    # --- ack: libera lo ya consumido por el cliente ---
    def ack(self, seq):
        with self.cond:
            for k in [k for k in self.down_chunks if k <= seq]:
                del self.down_chunks[k]

    def close(self):
        with self.cond:
            self.closed = True
            self.cond.notify_all()
        try:
            self.sock.close()
        except Exception:
            pass


class Server:
    def __init__(self, host, port, backend):
        self.host, self.port, self.backend = host, port, backend
        self.sessions = {}
        self.slock = threading.Lock()

    def get_session(self, sess):
        with self.slock:
            s = self.sessions.get(sess)
            if s is None or s.closed:
                # sesion nueva (o reconexion): cierra las huerfanas para no dejar
                # conexiones colgando en el sshd (el cliente usa 1 SID por conexion;
                # al reconectar genera otro). Evita agotar el backend con el tiempo.
                for old_sid, old in list(self.sessions.items()):
                    if old_sid != sess:
                        old.close()
                        del self.sessions[old_sid]
                s = Session(sess, self.backend)
                self.sessions[sess] = s
                log("sesion %s: registrada (sesiones vivas: %d)"
                    % (sess.hex()[:8], len(self.sessions)))
            return s

    def probe_reply(self, mode, size, req_payload):
        # eco del sondeo: BHP1 ver1 mode size + relleno i*31.
        # mode 2 (bajada) => respuesta del tamano pedido; el resto => 10 bytes.
        n = size if (mode == 2 and size >= 10) else 10
        out = bytearray(MAGIC + bytes([1, mode]) + size.to_bytes(4, "big"))
        for i in range(10, n):
            out.append((i * 31) & 255)
        return bytes(out)

    def handle(self, conn):
        conn.settimeout(60)
        try:
            while True:
                hdr = recvn(conn, 29)
                mode = hdr[0]
                sess = hdr[1:17]
                seq = int.from_bytes(hdr[17:25], "big")
                ln = int.from_bytes(hdr[25:29], "big")
                # Traen bytes: 0/1 (probe o subida), 2 (PROBE de download: 10B BHP1,
                # espera respuesta de 'param' bytes) y 3 (batch: 6B [chunkSize][count]).
                # El 4 (ack) no trae payload; su 'len' es semantico.
                payload = b""
                if ln and mode in (0, 1, 2, 3):
                    raw = recvn(conn, ln)
                    payload = mask(raw, sess, mode, seq, 0)

                # --- sondeo de camino (BHP1) ---
                if payload[:4] == MAGIC:
                    size = int.from_bytes(payload[6:10], "big") if len(payload) >= 10 else 0
                    pmode = payload[5] if len(payload) >= 6 else mode
                    send_frame(conn, sess, mode, seq, 0,
                               self.probe_reply(pmode, size, payload))
                    continue

                # --- datos ---
                s = self.get_session(sess)
                if mode == 1:                      # subida (len 0 = solo abrir)
                    s.upload(seq, payload)
                    send_frame(conn, sess, mode, seq, 0, b"")
                elif mode == 2:                    # bajada simple (rara vez usada)
                    chunk = s.download(seq, ln if ln > 0 else 1399, time.time() + LONGPOLL)
                    send_data(conn, sess, mode, seq, chunk)
                elif mode == 3:                    # lote de bajadas
                    # payload = [chunkSize:4BE][reservado:1][count:1]
                    if len(payload) >= 6:
                        chunk_size = int.from_bytes(payload[0:4], "big")
                        count = payload[5]
                    else:
                        chunk_size, count = 1399, 1
                    if chunk_size <= 0:
                        chunk_size = 1399
                    if count <= 0:
                        count = 1
                    # CLAVE: el cliente lee las 'count' respuestas ANTES de entregar
                    # nada al SSH (downloadBatch), asi que el long-poll solo puede
                    # esperar mientras el batch NO tenga nada que entregar. En cuanto
                    # un slot trae datos, los siguientes salen al instante; si no,
                    # el banner/KEXINIT se retrasaria 'LONGPOLL' por slot y el kex
                    # (20s) caeria. Solo se espera cuando el batch entero esta vacio.
                    deadline = time.time() + LONGPOLL
                    entregado = False
                    for i in range(count):
                        dl = deadline if not entregado else 0.0   # 0 = inmediato
                        chunk = s.download(seq + i, chunk_size, dl)
                        if chunk:
                            entregado = True
                        send_data(conn, sess, mode, seq + i, chunk)
                elif mode == 4:                    # ack
                    s.ack(seq)
                    send_frame(conn, sess, mode, seq, 0, b"")
                else:
                    send_error(conn, "modo desconocido")
                    return
        except (EOFError, ConnectionError, socket.timeout, OSError):
            pass
        except Exception as e:
            # una excepcion inesperada aqui cierra la conexion y el cliente ve
            # EOFException: la registramos para poder diagnosticarla.
            log("handle: excepcion inesperada: %r" % e)
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def serve(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((self.host, self.port))
        srv.listen(128)
        print("BHTTP escuchando en %s:%d -> backend %s:%d"
              % (self.host, self.port, self.backend[0], self.backend[1]), flush=True)
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=self.handle, args=(conn,), daemon=True).start()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--backend-host", default="127.0.0.1")
    ap.add_argument("--backend-port", type=int, default=22)
    a = ap.parse_args()
    Server(a.host, a.port, (a.backend_host, a.backend_port)).serve()


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

# ------------------------------------------------------------ arrancar
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

# ------------------------------------------------------------ verificar protocolo
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
    # 1) handshake BHP1 (probe): payload enmascarado, respuesta status 0 con eco
    p=MAGIC+bytes([1,0])+(0).to_bytes(4,"big")
    sk=open_sock(); send(sk,0,0,mask(p,0,0,0)); st,body=resp(sk); sk.close()
    assert st==0 and mask(body,0,0,1)[:4]==MAGIC, "handshake"
    # 2) registro + subida (mode 1, status 0)
    sk=open_sock(); send(sk,1,0,b""); assert resp(sk)[0]==0, "registro"; sk.close()
    sk=open_sock(); send(sk,1,0,mask(b"SSH-2.0-Test\r\n",1,0,0)); resp(sk); sk.close()
    # 3) batch (mode 3) como Frontera: prefijo 4 bytes, sin relleno, payload
    #    de peticion enmascarado. La bajada se produce en orden estricto, asi
    #    que solo el chunk 0 (el banner del SSH) esta disponible sin subir mas;
    #    leemos con socket-timeout corto y validamos ese chunk (los siguientes
    #    esperarian datos, que es correcto: el flujo real los va produciendo).
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
  echo "  Gestion:  systemctl status $SERVICE | restart | stop"
  echo "  Quitar :  sudo bash $0 --desinstalar"
  exit 0
fi

rojo "=== El servidor arranco pero no valido el protocolo ==="
echo "  Revisa:  journalctl -u $SERVICE -n 30 --no-pager"
exit 1
