#!/usr/bin/env bash
# bhttp-probe.sh - cliente minimo del protocolo BHTTP de DTunnel.
#
# Hace, a mano, lo mismo que la app hace sola al conectar:
#   1. TCP (o TLS, para los puertos con SSL)
#   2. Handshake / sondeo BHP1            (mode 0)
#   3. Path probe: tamano maximo de trama (mode 1, busqueda binaria)
#   4. Abrir sesion                       (mode 1, seq 0, len 0, sin payload)
#   5. Mover datos por el tunel           (mode 1 = subida, mode 2 = bajada, mode 4 = ack)
#
# Contra un DTProto Server (el del instalador oficial), que escucha en
# 0.0.0.0:80 sin SSL y 0.0.0.0:443 con SSL, si no le pasas puerto prueba los
# dos solo, poniendo TLS donde hace falta.
#
# ---------------------------------------------------------------------------
# Protocolo (extraido de classes.dex):
#
#   PETICION  = cabecera 29 bytes + payload enmascarado
#      [0]      mode        0=probe/echo 1=subida 2=descarga 3=lote 4=ack
#      [1..16]  sessionId   16 bytes (UUID de la sesion)
#      [17..24] sequence    big-endian 64 bits
#      [25..28] length      big-endian 32 bits
#                           en mode 2 NO es la longitud del payload (no hay):
#                           es el tamano de chunk que se pide de vuelta
#
#   RESPUESTA = cabecera 5 bytes + payload enmascarado
#      [0]      status      0 = OK
#                           2 = OK con relleno: el cuerpo empieza por 4 bytes
#                               en claro con la longitud real, luego el payload
#                           otro = el cuerpo es un error UTF-8 SIN enmascarar
#      [1..4]   length      big-endian 32 bits
#
#   MASCARA (no es cifrado: el sessionId viaja en claro, es anti-DPI)
#      keystream = SHA256( sessionId(16) || mode(1) || seq(8) || dir(1) || contador(4) )
#      dir = 0 en peticiones, 1 en respuestas; contador sube cada 32 bytes
#      en_el_cable = payload XOR keystream
#
#   PAYLOAD DE SONDEO
#      "BHP1"(4) || version=1(1) || mode(1) || size(4 BE) || relleno[i]=(byte)(i*31)
#
#   OJO: el host es el serverHost de la config (el del SSH), NO proxyHost:
#        en modo bhttp la app ignora proxyHost/proxyPort.
# ---------------------------------------------------------------------------
#
# Uso:   ./bhttp-probe.sh <host> [puerto] [opciones]
#          sin puerto     prueba 80 (plano) y 443 (TLS) y se queda en el que ande
#          --tls          fuerza TLS
#          --no-tls       fuerza texto plano
#          --sni <nombre> nombre SNI para el TLS (por defecto, el host)
#          -v             imprime cada trama en hexadecimal
#          --fast         salta el path probe (paso 3), va mas rapido
#          --solo-sondeo  se queda en el paso 3, no abre sesion ni manda datos
#          -d <texto>     manda ese texto en vez del banner SSH
#          -t <segundos>  timeout de lectura (por defecto 10)
#
# Requiere: bash, openssl, xxd, sha256sum (todo eso ya viene en Git Bash / Termux).

set -uo pipefail

HOST=""; PORT=""; SNI=""; VERBOSE=0; LADDER=1; DATAPHASE=1; TMO=10; TLSMODE="auto"
SEND_TEXT=$'SSH-2.0-OpenSSH_8.9\r\n'

while [ $# -gt 0 ]; do
  case "$1" in
    -v)            VERBOSE=1 ;;
    --tls)         TLSMODE="on" ;;
    --no-tls)      TLSMODE="off" ;;
    --sni)         shift; SNI="$1" ;;
    --fast)        LADDER=0 ;;
    --solo-sondeo) DATAPHASE=0 ;;
    -d)            shift; SEND_TEXT="$1" ;;
    -t)            shift; TMO="$1" ;;
    -h|--help)     sed -n '2,56p' "$0"; exit 0 ;;
    *)             if [ -z "$HOST" ]; then HOST="$1"; elif [ -z "$PORT" ]; then PORT="$1"; fi ;;
  esac
  shift
done

if [ -z "$HOST" ]; then
  echo "uso: $0 <host> [puerto] [--tls|--no-tls] [--sni nombre] [-v] [--fast]" >&2
  echo "     sin puerto prueba 80 y 443" >&2
  exit 2
fi
[ -z "$SNI" ] && SNI="$HOST"

for req in openssl xxd sha256sum; do
  command -v "$req" >/dev/null 2>&1 || { echo "falta '$req' en el PATH" >&2; exit 2; }
done

MAGIC="42485031"            # "BHP1"
DOWNCHUNK=1350              # maxDownloadChunkSize por defecto de la app (Lqk.b())

# Escalera de tamanos que prueba la app (Lcl.<clinit>). Cortada en 4096:
# por encima, generar el keystream en bash cuesta demasiadas llamadas a sha256sum.
# ponytail: escalera recortada; subir el tope si hace falta medir por encima de 4096.
LADDER_SIZES=(512 1024 1200 1280 1320 1350 1360 1370 1380 1388 1390 1400 1402 1410 1450 1600 2048 3205 4096)

SESS=""; USETLS=0; TLS_PID=""

# ---------- utilidades hex ----------

emit()   { printf '%s' "$1" | xxd -r -p; }            # hex -> bytes por stdout
wire()   { { printf '%s' "$1" | xxd -r -p >&4; } 2>/dev/null; }  # hex -> bytes al socket
tohex()  { printf '%s' "$1" | xxd -p | tr -d '\n'; }  # texto -> hex
totext() { emit "$1" | tr -c '\11\12\15\40-\176' '.'; }

# lee N bytes del socket y los devuelve en hex; vacio si timeout/EOF
recv() { { timeout "$TMO" dd bs=1 count="$1" <&3 | xxd -p | tr -d '\n'; } 2>/dev/null; }

# keystream(mode, seq, dir, nbytes) -> hex
keystream() {
  local mode="$1" seq="$2" dir="$3" n="$4" c=0 nonce out=""
  while [ ${#out} -lt $((n * 2)) ]; do
    nonce="$(printf '%s%02x%016x%02x%08x' "$SESS" "$mode" "$seq" "$dir" "$c")"
    out+="$(emit "$nonce" | sha256sum | cut -d' ' -f1)"
    c=$((c + 1))
  done
  printf '%s' "${out:0:$((n * 2))}"
}

# xorhex(a_hex, b_hex) -> hex
xorhex() {
  local a="$1" b="$2" i byte
  local -a acc=()
  for ((i = 0; i < ${#a}; i += 2)); do
    printf -v byte '%02x' $(( 0x${a:i:2} ^ 0x${b:i:2} ))
    acc+=("$byte")
  done
  local IFS=''
  printf '%s' "${acc[*]}"
}

# probe_payload(mode, size) -> hex del payload de sondeo
probe_payload() {
  local mode="$1" size="$2" len=10 i byte
  local -a acc=()
  if [ "$mode" = 1 ] && [ "$size" -ge 10 ]; then len="$size"; fi
  printf -v byte '%s01%02x%08x' "$MAGIC" "$mode" "$size"
  acc+=("$byte")
  for ((i = 10; i < len; i++)); do
    printf -v byte '%02x' $(( (i * 31) & 255 ))
    acc+=("$byte")
  done
  local IFS=''
  printf '%s' "${acc[*]}"
}

cut64() { if [ ${#1} -gt 64 ]; then printf '%s...' "${1:0:64}"; else printf '%s' "$1"; fi; }
# el log va a stderr: recv_frame se llama dentro de $(...) y no debe contaminar el valor
log()   { if [ "$VERBOSE" = 1 ]; then printf '    %s\n' "$*" >&2; fi; return 0; }

# ---------- transporte: fd 3 = lectura, fd 4 = escritura ----------

open_conn() {
  if [ "$USETLS" = 1 ]; then
    local tr tw
    coproc TLSC { openssl s_client -quiet -connect "$HOST:$PORT" -servername "$SNI" 2>/dev/null; }
    [ -z "${TLSC_PID:-}" ] && return 1
    TLS_PID="$TLSC_PID"
    tr="${TLSC[0]}"; tw="${TLSC[1]}"
    exec 3<&"$tr" 4>&"$tw" || return 1
    exec {tr}<&- {tw}>&-              # sueltas las copias, si no el coproc no cierra
    return 0
  fi
  { exec 3<>"/dev/tcp/$HOST/$PORT"; } 2>/dev/null || return 1
  exec 4>&3
  return 0
}

close_conn() {
  { exec 3<&-; exec 4>&-; } 2>/dev/null
  if [ -n "$TLS_PID" ]; then
    kill "$TLS_PID" 2>/dev/null
    wait "$TLS_PID" 2>/dev/null
    TLS_PID=""
  fi
  return 0
}

# ---------- protocolo ----------

# send_frame(mode, seq, payload_hex, len_field)
send_frame() {
  local mode="$1" seq="$2" payload="$3" lenf="$4" hdr masked ks
  printf -v hdr '%02x%s%016x%08x' "$mode" "$SESS" "$seq" "$lenf"
  log "-> cabecera 29B: $hdr"
  log "   mode=$mode session=$SESS seq=$seq length=$lenf"
  wire "$hdr"
  if [ -n "$payload" ]; then
    ks="$(keystream "$mode" "$seq" 0 $(( ${#payload} / 2 )))"
    masked="$(xorhex "$payload" "$ks")"
    log "-> payload $(( ${#payload} / 2 ))B en claro: $(cut64 "$payload")"
    log "-> payload enmascarado   : $(cut64 "$masked")"
    wire "$masked"
  fi
}

# recv_frame(mode, seq) -> imprime "status payload_hex"; 1 si falla
recv_frame() {
  local mode="$1" seq="$2" hdr status len body real plain ks
  hdr="$(recv 5)"
  if [ ${#hdr} -ne 10 ]; then return 1; fi
  log "<- cabecera 5B: $hdr"
  status=$(( 0x${hdr:0:2} ))
  len=$(( 0x${hdr:2:8} ))
  log "   status=$status length=$len"
  plain=""
  if [ "$len" -gt 0 ]; then
    body="$(recv "$len")"
    if [ ${#body} -ne $((len * 2)) ]; then return 1; fi
    if [ "$status" != 0 ] && [ "$status" != 2 ]; then
      # los cuerpos de error van en claro, sin mascara (Lbw.L() los lee tal cual)
      plain="$body"
      log "<- error en claro: $(totext "$plain")"
    else
      # status 2 = respuesta rellenada: 4 bytes en claro con la longitud real
      # delante y relleno detras. Se quita antes de desenmascarar (Lbw.y()).
      if [ "$status" = 2 ] && [ "$len" -ge 4 ]; then
        real=$(( 0x${body:0:8} ))
        if [ "$real" -gt 0 ] && [ "$real" -le $((len - 4)) ]; then
          body="${body:8:$((real * 2))}"
        else
          body=""
        fi
      fi
      if [ -n "$body" ]; then
        ks="$(keystream "$mode" "$seq" 1 $(( ${#body} / 2 )))"
        plain="$(xorhex "$body" "$ks")"
        log "<- payload en claro: $(cut64 "$plain")"
      fi
    fi
  fi
  printf '%s %s' "$status" "$plain"
}

# request(mode, seq, payload_hex, len_field) -> "status plain_hex"; 1 si falla
request() {
  local res
  open_conn || return 1
  send_frame "$1" "$2" "$3" "$4"
  res="$(recv_frame "$1" "$2")" || { close_conn; return 1; }
  close_conn
  printf '%s' "$res"
}

# check_echo(mode, size_esperado, plain_hex) -> 0 si el eco BHP1 es valido
check_echo() {
  local mode="$1" size="$2" p="$3" want
  if [ ${#p} -lt 20 ]; then return 1; fi
  if [ "${p:0:8}" != "$MAGIC" ]; then return 1; fi
  if [ "${p:8:2}" != "01" ]; then return 1; fi
  printf -v want '%02x' "$mode"
  if [ "${p:10:2}" != "$want" ]; then return 1; fi
  printf -v want '%08x' "$size"
  if [ "${p:12:8}" != "$want" ]; then return 1; fi
  return 0
}

# probe_wire(wire_size) -> 0 si una trama de subida de ese tamano pasa
probe_wire() {
  local wire="$1" plen payload res status plain
  plen=$(( wire - 29 )); [ "$plen" -lt 10 ] && plen=10
  payload="$(probe_payload 1 "$plen")"
  res="$(request 1 "$wire" "$payload" $(( ${#payload} / 2 )))" || return 1
  status="${res%% *}"; plain="${res#* }"
  if [ "$status" != 0 ] && [ "$status" != 2 ]; then return 1; fi
  check_echo 1 "$plen" "$plain"
}

# ---------- pasos ----------

# 0 = todo bien, 1 = fallo definitivo, 2 = no habla BHTTP (se puede reintentar
# con el otro transporte), 3 = ni siquiera abre el TCP
run_target() {
  local TOTAL=5 RES ST PL lo hi mid w BEST GOT TXT SEND_HEX NSEND intento
  [ "$DATAPHASE" = 0 ] && TOTAL=3
  SESS="$(openssl rand -hex 16)"

  local via="TCP plano"
  [ "$USETLS" = 1 ] && via="TLS (sni=$SNI)"
  echo "== $HOST:$PORT via $via"
  echo "   sessionId = $SESS"

  # --- 1: conexion ---
  printf '[1/%d] Conexion .......... ' "$TOTAL"
  if ! open_conn; then
    echo "FALLO"
    [ "$USETLS" = 1 ] && echo "      No se pudo abrir TLS contra $HOST:$PORT." \
                      || echo "      No conecta a $HOST:$PORT (cerrado, DNS, o filtrado)."
    close_conn
    return 3
  fi
  close_conn
  echo "OK"

  # --- 2: handshake ---
  printf '[2/%d] Handshake BHP1 .... ' "$TOTAL"
  local PAY; PAY="$(probe_payload 0 0)"
  if RES="$(request 0 0 "$PAY" $(( ${#PAY} / 2 )))"; then
    ST="${RES%% *}"; PL="${RES#* }"
  else
    ST=""; PL=""
  fi

  if [ -z "$ST" ]; then
    echo "FALLO"
    if [ "$USETLS" = 1 ]; then
      echo "      TLS abre pero no responde BHTTP: puerto equivocado, SNI que no"
      echo "      le gusta, o ese puerto en realidad no lleva SSL."
    else
      echo "      Acepta TCP pero no responde: puede que ese puerto lleve TLS."
    fi
    return 2
  elif [ "$ST" != 0 ] && [ "$ST" != 2 ]; then
    echo "FALLO (status=$ST)"
    echo "      El servidor contesta pero rechaza: \"$(totext "$PL")\""
    return 1
  elif ! check_echo 0 0 "$PL"; then
    echo "FALLO"
    echo "      Responde, pero el eco no es un BHP1 valido: status=$ST payload=$PL"
    return 2
  fi
  echo "OK"
  echo "      es un servidor BHTTP con path probe v1"

  # --- 3: path probe ---
  printf '[3/%d] Path probe ........ ' "$TOTAL"
  BEST=0
  if [ "$LADDER" = 0 ]; then
    echo "(saltado con --fast)"
  else
    echo
    lo=0; hi=$(( ${#LADDER_SIZES[@]} - 1 ))
    while [ "$lo" -le "$hi" ]; do
      mid=$(( (lo + hi) / 2 ))
      w="${LADDER_SIZES[$mid]}"
      printf '      trama de %6d B ... ' "$w"
      if probe_wire "$w"; then
        echo "pasa"; BEST="$w"; lo=$(( mid + 1 ))
      else
        echo "bloqueada"; hi=$(( mid - 1 ))
      fi
    done
    if [ "$BEST" -gt 0 ]; then
      echo "      subida: trama max $BEST B -> $(( BEST - 29 )) B utiles por chunk"
      echo "      (la app resta ademas un margen de ~1/16 y baja un escalon)"
    else
      echo "      ningun tamano paso: el servidor no acepta sondeos de subida"
    fi
  fi

  if [ "$DATAPHASE" = 0 ]; then
    echo
    echo "Listo (--solo-sondeo)."
    return 0
  fi

  # --- 4: abrir sesion (igual que Lpk.a(): mode 1, seq 0, len 0, sin payload) ---
  printf '[4/%d] Abrir sesion ...... ' "$TOTAL"
  if RES="$(request 1 0 "" 0)"; then
    ST="${RES%% *}"; PL="${RES#* }"
  else
    ST=""; PL=""
  fi
  if [ -z "$ST" ]; then
    echo "FALLO (sin respuesta)"
    return 1
  elif [ "$ST" != 0 ] && [ "$ST" != 2 ]; then
    echo "FALLO (status=$ST)"
    echo "      \"$(totext "$PL")\""
    return 1
  fi
  echo "OK"

  # --- 5: datos ---
  echo "[5/$TOTAL] Datos ............."
  SEND_HEX="$(tohex "$SEND_TEXT")"
  NSEND=$(( ${#SEND_HEX} / 2 ))

  printf '      -> mode 1 seq 0   %4d B ... ' "$NSEND"
  if RES="$(request 1 0 "$SEND_HEX" "$NSEND")"; then
    ST="${RES%% *}"; PL="${RES#* }"
  else
    ST=""
  fi
  if [ -z "$ST" ]; then
    echo "sin respuesta"
    echo "      La subida no fue aceptada; el tunel no llega al backend."
    return 1
  elif [ "$ST" != 0 ] && [ "$ST" != 2 ]; then
    echo "rechazada (status=$ST)"
    echo "      \"$(totext "$PL")\""
    return 1
  fi
  echo "aceptada"

  GOT=""
  for intento in 1 2 3; do
    printf '      <- mode 2 seq 0        ... '
    if RES="$(request 2 0 "" "$DOWNCHUNK")"; then
      ST="${RES%% *}"; PL="${RES#* }"
    else
      ST=""; PL=""
    fi
    if [ -z "$ST" ]; then
      echo "sin respuesta"; break
    elif [ "$ST" != 0 ] && [ "$ST" != 2 ]; then
      echo "status=$ST -> \"$(totext "$PL")\""; break
    elif [ -n "$PL" ]; then
      GOT="$PL"; echo "$(( ${#PL} / 2 )) B recibidos"; break
    fi
    echo "vacio, reintento $intento/3"
    sleep 1
  done

  echo
  if [ -n "$GOT" ]; then
    request 4 0 "" 0 >/dev/null 2>&1        # ack, como el hilo BhttpDownload-Ack
    TXT="$(totext "$GOT")"
    echo "      primeros bytes: $(printf '%s' "$TXT" | head -c 120)"
    echo "      hex           : $(cut64 "$GOT")"
    echo
    case "$TXT" in
      SSH-2.0*|SSH-1*)
        echo "  TUNEL OK: mueve bytes en ambos sentidos y detras hay un SSH." ;;
      *)
        echo "  TUNEL OK: mueve bytes en ambos sentidos."
        echo "            Lo que responde no parece un banner SSH; mira el texto de arriba." ;;
    esac
    echo
    echo "  Para la app:  host $HOST   puerto $PORT   protocolo bhttp"
    [ "$USETLS" = 1 ] && echo "                con TLS activado y SNI = $SNI"
    return 0
  fi

  echo "  El servidor BHTTP responde, pero el tunel no devolvio datos."
  echo "  La sesion se abre y acepta la subida, pero la bajada viene vacia."
  echo "  Los pasos 1-4 estan bien: el problema no es la conexion, es que el"
  echo "  backend de detras (SSH o el propio proto-server) no arranca la sesion."
  return 1
}

# ---------- main ----------

# que puertos y con que transporte
declare -a TRY_PORT=() TRY_TLS=()
if [ -n "$PORT" ]; then
  TRY_PORT+=("$PORT")
  case "$TLSMODE" in
    on)  TRY_TLS+=(1) ;;
    off) TRY_TLS+=(0) ;;
    *)   if [ "$PORT" = 443 ]; then TRY_TLS+=(1); else TRY_TLS+=(0); fi ;;
  esac
else
  # DTProto Server: 80 sin SSL, 443 con SSL
  case "$TLSMODE" in
    on)  TRY_PORT+=(443 80);   TRY_TLS+=(1 1) ;;
    off) TRY_PORT+=(80 443);   TRY_TLS+=(0 0) ;;
    *)   TRY_PORT+=(80 443);   TRY_TLS+=(0 1) ;;
  esac
fi

RC=1
for i in "${!TRY_PORT[@]}"; do
  PORT="${TRY_PORT[$i]}"; USETLS="${TRY_TLS[$i]}"
  [ "$i" -gt 0 ] && echo
  run_target; RC=$?
  if [ "$RC" = 0 ]; then break; fi
  # si no habla BHTTP y el transporte lo elegimos nosotros, probamos el otro
  if [ "$RC" = 2 ] && [ "$TLSMODE" = "auto" ]; then
    echo
    if [ "$USETLS" = 1 ]; then USETLS=0; else USETLS=1; fi
    echo "   -> reintentando el mismo puerto con el otro transporte"
    echo
    run_target; RC=$?
    [ "$RC" = 0 ] && break
  fi
done

exit "$RC"
