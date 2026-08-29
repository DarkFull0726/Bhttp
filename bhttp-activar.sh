#!/usr/bin/env bash
# bhttp-activar.sh - deja el DTProto Server (BHTTP) levantado en la VPS.
#
# Que hace, solo, sin preguntar nada:
#   1. Comprueba que el servidor este instalado
#   2. Mira que puertos estan libres y elige uno
#   3. Escribe ese puerto en /etc/config.json (con copia de seguridad antes)
#   4. Habilita y arranca el servicio
#   5. Verifica al final: servicio activo + puerto escuchando + protocolo BHTTP
#      respondiendo de verdad
#
# Si algo sale mal deshace el cambio: restaura la config anterior y reinicia.
#
# Uso:  ./bhttp-activar.sh                 elige puerto libre y activa
#       ./bhttp-activar.sh --puerto 8080   fuerza ese puerto
#       ./bhttp-activar.sh --dry-run       dice que haria, sin tocar nada
#       ./bhttp-activar.sh --ssl           marca el listener como SSL/TLS
#
# Necesita root. Probado contra el servidor del instalador oficial de DTunnel.

set -uo pipefail

CONFIG="${BHTTP_CONFIG:-/etc/config.json}"
UNIT="${BHTTP_UNIT:-/etc/systemd/system/proto-server.service}"
SERVICE="${BHTTP_SERVICE:-proto-server}"
INSTALADOR="https://raw.githubusercontent.com/DTunnel0/DTProto-Server-Releases/main/install-server.sh"

# por orden de preferencia: los dos del instalador y luego alternativas comunes
CANDIDATOS=(80 443 8080 8443 2082 2095 8880 2052 2086 3128)

PUERTO_FORZADO=""; DRYRUN=0; USAR_SSL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --puerto|-p) shift; PUERTO_FORZADO="$1" ;;
    --dry-run)   DRYRUN=1 ;;
    --ssl)       USAR_SSL="true" ;;
    --no-ssl)    USAR_SSL="false" ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *)           echo "opcion desconocida: $1" >&2; exit 2 ;;
  esac
  shift
done

rojo()  { printf '\033[31m%s\033[0m\n' "$*"; }
verde() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
paso()  { printf '\n[%s] %s\n' "$1" "$2"; }

# ---------------------------------------------------------------- utilidades

# puertos TCP en escucha ahora mismo
puertos_ocupados() {
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | tail -n +2 | awk '{print $4}' | sed 's/.*://'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk '/^tcp/ {print $4}' | sed 's/.*://'
  fi | grep -E '^[0-9]+$' | sort -u
}

# puertos que ya ocupa nuestro propio servicio (esos no cuentan como ocupados)
puertos_propios() {
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep -i "$SERVICE" | awk '{print $4}' | sed 's/.*://'
  fi | grep -E '^[0-9]+$' | sort -u
}

# quien ocupa un puerto (para el mensaje de aviso)
quien_ocupa() {
  if command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | awk -v p=":$1\$" '$4 ~ p {print $NF}' \
      | grep -oE 'users:\(\("[^"]+' | sed 's/.*"//' | head -1
  fi
}

puerto_libre() {
  local p="$1"
  if printf '%s\n' "$PROPIOS" | grep -qx "$p"; then return 0; fi
  if printf '%s\n' "$OCUPADOS" | grep -qx "$p"; then return 1; fi
  return 0
}

# puertos que hay ahora en la config
puertos_config() {
  [ -r "$CONFIG" ] || return 0
  grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' "$CONFIG" \
    | grep -oE '[0-9]+' | sort -n -u
}

# escribe el puerto elegido en la config, conservando el resto de campos
poner_puerto() {
  local archivo="$1" puerto="$2" ssl="$3"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$archivo" "$puerto" "$ssl" <<'PY'
import json, sys
ruta, puerto, ssl = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(ruta) as f:
    cfg = json.load(f)
proxy = cfg.get("proxy")
if not isinstance(proxy, dict):
    proxy = {}
    cfg["proxy"] = proxy
lst = proxy.get("listen")
# se conserva la forma del primer listener (host, ssl, lo que traiga) y solo
# se le cambia el puerto; si no habia ninguno se crea uno minimo
base = dict(lst[0]) if isinstance(lst, list) and lst and isinstance(lst[0], dict) \
       else {"host": "0.0.0.0", "ssl": False}
base["port"] = puerto
if ssl in ("true", "false"):
    base["ssl"] = (ssl == "true")
proxy["listen"] = [base]
with open(ruta, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
    return $?
  fi
  if command -v jq >/dev/null 2>&1; then
    local tmp; tmp="$(mktemp)"
    jq --argjson p "$puerto" \
       '.proxy.listen = [ (( .proxy.listen[0] // {host:"0.0.0.0",ssl:false} ) + {port:$p}) ]' \
       "$archivo" > "$tmp" && mv "$tmp" "$archivo" && return 0
    rm -f "$tmp"; return 1
  fi
  # ultimo recurso: cambiar el primer "port": N que aparezca
  sed -i "0,/\"port\"[[:space:]]*:[[:space:]]*[0-9]\+/s//\"port\": $puerto/" "$archivo"
}

json_valido() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null
  elif command -v jq >/dev/null 2>&1; then
    jq -e . "$1" >/dev/null 2>&1
  else
    return 0   # sin herramientas no se puede validar; se da por bueno
  fi
}

ip_publica() {
  local ip=""
  command -v curl >/dev/null 2>&1 && ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null)"
  [ -z "$ip" ] && command -v hostname >/dev/null 2>&1 && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "$ip"
}

# ------------------------------------------------------------------- 1. comprobaciones

echo "=== Activar BHTTP (DTProto Server) ==="

if [ "$DRYRUN" = 0 ] && [ "$(id -u 2>/dev/null || echo 0)" != 0 ]; then
  rojo "Hay que ejecutarlo como root:  sudo $0"
  exit 2
fi

paso "1/5" "Comprobando la instalacion"

FALTA=0
if [ -f "$UNIT" ]; then info "servicio  : $UNIT"; else info "servicio  : NO EXISTE ($UNIT)"; FALTA=1; fi
if [ -r "$CONFIG" ]; then info "config    : $CONFIG"; else info "config    : NO EXISTE ($CONFIG)"; FALTA=1; fi

if [ "$FALTA" = 1 ]; then
  echo
  rojo "El DTProto Server no esta instalado en esta maquina."
  echo "  Este script solo lo configura y lo arranca; no lo instala."
  echo
  echo "  Instalalo primero con el instalador oficial:"
  echo "    bash <(curl -fsSL $INSTALADOR)"
  echo
  echo "  Y despues vuelve a lanzar:  $0"
  exit 1
fi

ACTUALES="$(puertos_config)"
info "puertos en la config: $(printf '%s' "$ACTUALES" | tr '\n' ' ')"
if command -v systemctl >/dev/null 2>&1; then
  info "estado del servicio : $(systemctl is-active "$SERVICE" 2>/dev/null)"
fi

# ------------------------------------------------------------------- 2. elegir puerto

paso "2/5" "Eligiendo puerto"

OCUPADOS="$(puertos_ocupados)"
PROPIOS="$(puertos_propios)"

PUERTO=""
if [ -n "$PUERTO_FORZADO" ]; then
  PUERTO="$PUERTO_FORZADO"
  if puerto_libre "$PUERTO"; then
    info "puerto $PUERTO forzado y libre"
  else
    ocupante="$(quien_ocupa "$PUERTO")"
    rojo "  El puerto $PUERTO ya lo usa ${ocupante:-otro proceso}. El servicio no podra arrancar."
    echo "  Elige otro, o para ese proceso primero."
    exit 1
  fi
else
  for p in "${CANDIDATOS[@]}"; do
    if puerto_libre "$p"; then
      PUERTO="$p"
      info "elegido el puerto $p (libre)"
      break
    else
      ocupante="$(quien_ocupa "$p")"
      info "puerto $p ocupado${ocupante:+ por $ocupante}, siguiente"
    fi
  done
fi

if [ -z "$PUERTO" ]; then
  rojo "No hay ningun puerto libre de la lista: ${CANDIDATOS[*]}"
  echo "  Usa uno tuyo:  $0 --puerto 9443"
  exit 1
fi

# el 443 se suele querer con TLS; el resto en plano, salvo que digas otra cosa
SSL_FINAL="$USAR_SSL"
if [ -z "$SSL_FINAL" ]; then
  if [ "$PUERTO" = 443 ] || [ "$PUERTO" = 8443 ]; then SSL_FINAL="true"; else SSL_FINAL="false"; fi
fi
info "ssl/tls en ese listener: $SSL_FINAL"

if [ "$DRYRUN" = 1 ]; then
  echo
  verde "--dry-run: aqui me paro. Habria puesto el puerto $PUERTO (ssl=$SSL_FINAL) y reiniciado $SERVICE."
  exit 0
fi

# ------------------------------------------------------------------- 3. escribir config

paso "3/5" "Escribiendo la configuracion"

RESPALDO="$CONFIG.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$CONFIG" "$RESPALDO" || { rojo "No pude hacer copia de seguridad"; exit 1; }
info "copia de seguridad: $RESPALDO"

if ! poner_puerto "$CONFIG" "$PUERTO" "$SSL_FINAL"; then
  rojo "No pude escribir el puerto en $CONFIG"
  cp -a "$RESPALDO" "$CONFIG"
  exit 1
fi

if ! json_valido "$CONFIG"; then
  rojo "El JSON resultante no es valido; restaurando la copia"
  cp -a "$RESPALDO" "$CONFIG"
  exit 1
fi
info "puerto $PUERTO escrito y JSON valido"

# deshacer el cambio si algo falla de aqui en adelante
restaurar() {
  echo
  rojo "Algo fallo. Restaurando la configuracion anterior."
  cp -a "$RESPALDO" "$CONFIG"
  systemctl restart "$SERVICE" >/dev/null 2>&1
  echo "  Config restaurada desde $RESPALDO"
  echo
  echo "  Mira el error exacto con:"
  echo "    systemctl status $SERVICE --no-pager -l"
  echo "    journalctl -u $SERVICE -n 50 --no-pager"
}

# ------------------------------------------------------------------- 4. arrancar

paso "4/5" "Arrancando el servicio"

systemctl daemon-reload >/dev/null 2>&1
systemctl enable "$SERVICE" >/dev/null 2>&1 && info "activado en el arranque"
systemctl restart "$SERVICE" >/dev/null 2>&1

# se le dan unos segundos a que levante y haga bind
LEVANTADO=0
for i in $(seq 1 15); do
  estado="$(systemctl is-active "$SERVICE" 2>/dev/null)"
  if [ "$estado" = "active" ]; then
    if puertos_ocupados | grep -qx "$PUERTO"; then LEVANTADO=1; break; fi
  elif [ "$estado" = "failed" ]; then
    break
  fi
  sleep 1
done

if [ "$LEVANTADO" != 1 ]; then
  info "estado: $(systemctl is-active "$SERVICE" 2>/dev/null)"
  journalctl -u "$SERVICE" -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
  restaurar
  exit 1
fi
verde "  servicio activo y escuchando en el puerto $PUERTO"

# ------------------------------------------------------------------- 5. verificar

paso "5/5" "Verificacion final"

OK=1

estado="$(systemctl is-active "$SERVICE" 2>/dev/null)"
if [ "$estado" = "active" ]; then info "servicio activo ............ SI"
else info "servicio activo ............ NO ($estado)"; OK=0; fi

if puertos_ocupados | grep -qx "$PUERTO"; then info "puerto $PUERTO escuchando ..... SI"
else info "puerto $PUERTO escuchando ..... NO"; OK=0; fi

if systemctl is-enabled "$SERVICE" >/dev/null 2>&1; then info "arranca solo al reiniciar .. SI"
else info "arranca solo al reiniciar .. NO"; fi

# la prueba de verdad: hablar el protocolo BHTTP contra el puerto
if command -v bhttp-probe >/dev/null 2>&1; then
  echo
  info "Probando el protocolo BHTTP contra 127.0.0.1:$PUERTO ..."
  echo
  if bhttp-probe 127.0.0.1 "$PUERTO" --fast; then
    PROTO_OK=1
  else
    PROTO_OK=0; OK=0
  fi
else
  PROTO_OK=-1
  echo
  info "El probador no esta instalado, asi que no puedo verificar el protocolo."
  info "Instalalo con:"
  info "  curl -fsSL https://raw.githubusercontent.com/DarkFull0726/Bhttp/refs/heads/main/bhttp-probe.sh -o /usr/local/bin/bhttp-probe && chmod +x /usr/local/bin/bhttp-probe"
fi

echo
IP="$(ip_publica)"
if [ "$OK" = 1 ]; then
  verde "=== LISTO ==="
  echo
  echo "  En la app pon:"
  echo "     host      : ${IP:-<la ip de tu vps>}"
  echo "     puerto    : $PUERTO"
  echo "     protocolo : bhttp"
  [ "$SSL_FINAL" = "true" ] && echo "     con TLS activado"
  echo
  [ "$PROTO_OK" = -1 ] && echo "  (servicio y puerto verificados; el protocolo no, falta el probador)"
  echo "  Copia de seguridad de la config anterior: $RESPALDO"
  exit 0
fi

rojo "=== Quedo algo sin verificar ==="
echo "  El servicio arranco pero alguna comprobacion fallo."
echo "  Revisa:  journalctl -u $SERVICE -n 50 --no-pager"
echo "  Config anterior guardada en: $RESPALDO"
exit 1
