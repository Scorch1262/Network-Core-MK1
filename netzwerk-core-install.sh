#!/bin/sh
# ============================================================================
#  Netzwerk-Core Installer v1.7.1 fuer GL.iNet Brume 2 (GL-MT2500 / OpenWrt)
#
#  Einmal per SSH ausfuehren:   sh netzwerk-core-install.sh
#
#  Stellt den Router zuletzt auf "Netzwerkteilnehmer ohne Routing" um (LAN- und
#  WAN-Port in einer Bridge, IP per DHCP, DHCP-Server aus; per Statusseite oder
#  "sh /root/Netzwerk-Core/bin/nc-network.sh dhcp-on" wieder einschaltbar).
#  Mit  NC_SKIP_NETWORK=1 sh netzwerk-core-install.sh  wird die Umstellung ausgelassen.
#
#  Selbst-Update: Der Button "Skript aktualisieren" auf der Statusseite laedt die
#  neueste Version dieses Skripts aus GitHub (Scorch1262/Network-Core-MK1) und
#  fuehrt sie im Update-Modus (NC_SELF_UPDATE=1) aus: Hilfsskripte, Statusseite
#  und App-Liste werden erneuert, Netzwerk und App-Daten bleiben unberuehrt.
#
#  Installiert: nano, mosquitto, 15 Anwendungen aus GitHub (Scorch1262),
#  je Anwendung einen Autostart (procd) und die Statusseite "Netzwerk-Core"
#  (Port 8090) mit Kacheln und Update-Buttons.
#  Schlaegt etwas wegen fehlendem Internet fehl, laeuft die Installation beim
#  naechsten Routerstart automatisch weiter (nc-firstrun).
# ============================================================================
BASE=/root/Netzwerk-Core

[ "$(id -u)" = "0" ] || { echo "Bitte als root ausfuehren."; exit 1; }
mkdir -p "$BASE/bin" "$BASE/apps" "$BASE/run"

# Kopie dieses Skripts behalten (Selbstheilung der Statusseite nach Stromausfall/Neustart)
if [ -f "$0" ] && [ "$0" != "$BASE/netzwerk-core-install.sh" ] && grep -q 'NC_SELF_UPDATE' "$0" 2>/dev/null; then
    cp -f "$0" "$BASE/netzwerk-core-install.sh" 2>/dev/null
fi

# Update-Modus (Selbst-Update): vorher Sicherung der Hilfsskripte fuer den Rollback
SELF_UPDATE=${NC_SELF_UPDATE:-0}
if [ "$SELF_UPDATE" = "1" ]; then
    rm -rf "$BASE/backup-core"; mkdir -p "$BASE/backup-core"
    cp -a "$BASE/bin" "$BASE/backup-core/bin" 2>/dev/null
    cp -a "$BASE/apps.conf" "$BASE/backup-core/apps.conf" 2>/dev/null
    cp -a "$BASE/shims" "$BASE/backup-core/shims" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# App-Liste:  id|Name|Repo|Port|Startdatei|Unterordner|Umgebung|Beschreibung
# ---------------------------------------------------------------------------
cat > "$BASE/apps.conf.new" <<'NC_APPS_EOF'
# id|Name|GitHub-Repo (nur Name = Scorch1262/Name, sonst Besitzer/Name)|Port|Startdatei (auto = automatisch, @datei = eigener Installer des Repos)|Unterordner|Umgebungsvariablen|Beschreibung|Startargumente
flow|MQTT Flow-Planer|MQTT-Flow-Planer-MK1|8020|app.py|||MQTT-Ablaeufe als Blockschaltbild entwerfen
dashboard|MQTT-Dashboard|MQTT-Dashboard-MK4|5001|app.py|||Graphen, Status-Anzeigen, Schalter und Slider
makro|MQTT Makro-Zentrale|MQTT-Makro-Zentrale-MK1|8010|app.py|||MQTT-Makro-Ketten verwalten und ausfuehren
diagram|MQTT-Diagram|MQTT-Diagram-MK1|5000|main.py||DASHBOARD_HOST=0.0.0.0 DASHBOARD_PORT=5000 DASHBOARD_OPEN_BROWSER=0|Live-Mindmap aller MQTT-Topics
netzwerkplan|Netzwerkplaner|Netzwerkplaner-MK1|8086|app.py|||Netzwerkplanung und Dokumentation
rohrleitung|Rohrleitungsplan|Rohrleitungsplan-MK1|8087|app.py|||Rohrleitungsplan zeichnen und verwalten
kabelmanager|KabelManager|KabelManager-MK1|8088|app.py|||Kabel verwalten und dokumentieren
ablaufplan|Ablaufplan-Editor|AblaufplanEditor-MK1|8089|app.py|||Ablaufplaene erstellen (mit PDF-Export)
overwatch|OverWatch MK2|OverWatch-MK2|8094|main.py|||Lagekarte mit ADS-B, FLARM und Starlink|--no-sms
bambu|Drucker-Dashboard|BambuLab-MQTT-Dashboard-MK6|8000|app.py|||Bambu Lab / Ultimaker / OctoPrint / Formlabs
outfit|Wetter-Outfit|Wetter-Outfit-Dashboard-MK1|8095|app.py|||Outfit-Vorschlaege nach Wetter und Aktivitaet
kachel|MQTT Kachel-Dashboard|MQTT-Kachel-Dashboard-MK1|8085|app.py|||MQTT-Topics als Kacheln mit Symbolen und Schwellwerten|
klingel|Klingelbildschirm|MQTT-Klingelbildschirm-MK3|8081|@install.sh|||Klingel-Dashboard mit Kamerabild und Tueroeffner (Einrichtung: Port 8083)|
chat|Netzwerk-Chat|Netzwerk-Chat-MK1|8092|netzwerk_chat.py|||Chat fuer alle Teilnehmer im Netzwerk|--port 8092 --host 0.0.0.0
homekit|HomeKit2MQTT|hobbyquaker/homekit2mqtt|51888|index.js|||HomeKit-Bridge fuer MQTT (Login: homekit + Pincode, siehe data/homekit/pincode)|-u mqtt://127.0.0.1 -s /root/Netzwerk-Core/data/homekit -m /root/Netzwerk-Core/data/homekit/map.json -p 51826 -w 51888 -b Netzwerk-Core -c $(cat /root/Netzwerk-Core/data/homekit/pincode) -a $(cat /root/Netzwerk-Core/data/homekit/username)
NC_APPS_EOF

# Vorhandene App-Liste mit der neuen zusammenfuehren: neue Liste gewinnt,
# eigene (selbst ergaenzte) Zeilen mit unbekannter ID bleiben erhalten.
if [ -f "$BASE/apps.conf" ]; then
    cp "$BASE/apps.conf" "$BASE/apps.conf.bak"
    cp "$BASE/apps.conf.new" "$BASE/apps.conf.merged"
    grep -v -E '^[[:space:]]*(#|$)' "$BASE/apps.conf" | while IFS= read -r l; do
        id=${l%%|*}
        grep -q "^$id|" "$BASE/apps.conf.new" || echo "$l" >> "$BASE/apps.conf.merged"
    done
    mv -f "$BASE/apps.conf.merged" "$BASE/apps.conf"
    rm -f "$BASE/apps.conf.new"
else
    mv -f "$BASE/apps.conf.new" "$BASE/apps.conf"
fi

# ---------------------------------------------------------------------------
# Gemeinsame Shell-Funktionen (Installation + Update einer Anwendung)
# ---------------------------------------------------------------------------
cat > "$BASE/bin/nc-lib.sh" <<'NC_LIB_EOF'
#!/bin/sh
BASE=/root/Netzwerk-Core
OWNER=Scorch1262
CONF="$BASE/apps.conf"

log() { echo "[$(date '+%F %T')] $*"; }

# curl mit optionalem GitHub-Token (Datei $BASE/github_token, fuer private Repos)
gh_curl() {
    if [ -r "$BASE/github_token" ]; then
        curl -fsSL --retry 3 --connect-timeout 15 \
            -H "Authorization: token $(tr -d ' \r\n' < "$BASE/github_token")" "$@"
    else
        curl -fsSL --retry 3 --connect-timeout 15 "$@"
    fi
}

app_ids()   { grep -v -E '^[[:space:]]*(#|$)' "$CONF" | cut -d'|' -f1; }
app_field() { grep "^$1|" "$CONF" | head -n1 | cut -d'|' -f"$2"; }

# Entfernte Dienste (werden bei "Alle aktualisieren" / Neuinstallation uebersprungen)
is_removed() { grep -qx "$1" "$BASE/removed.list" 2>/dev/null; }
mark_removed() { is_removed "$1" || echo "$1" >> "$BASE/removed.list"; }
unmark_removed() {
    [ -f "$BASE/removed.list" ] || return 0
    grep -vx "$1" "$BASE/removed.list" > "$BASE/removed.list.t"; mv -f "$BASE/removed.list.t" "$BASE/removed.list"
}
active_ids() { for _i in $(app_ids); do is_removed "$_i" || echo "$_i"; done; }

# Port in einer config.json ("server.port") setzen; gibt "changed" aus, wenn etwas geaendert wurde
set_json_port() {   # datei port
    [ -f "$1" ] || return 0
    python3 - "$1" "$2" <<'NC_PYPORT_EOF'
import json, re, sys
f, p = sys.argv[1], int(sys.argv[2])
raw = open(f, "rb").read().decode("utf-8-sig", "replace")   # auch Dateien mit BOM (Windows-Editor)
try:
    d = json.loads(raw)
    s = d.setdefault("server", {})
    if s.get("port") == p:
        sys.exit(0)
    s["port"] = p
    out = json.dumps(d, indent=2, ensure_ascii=False)
except Exception:
    # kein gueltiges JSON: Port im Textbereich "server" per Textersetzung setzen
    m = re.search(r'("server"\s*:\s*\{[^}]*?"port"\s*:\s*)(\d+)', raw, re.S)
    if not m:
        print("error"); sys.exit(0)
    if int(m.group(2)) == p:
        sys.exit(0)
    out = raw[:m.start(2)] + str(p) + raw[m.end(2):]
open(f, "w", encoding="utf-8").write(out)
print("changed")
NC_PYPORT_EOF
}

# Das Router-Python (OpenWrt) hat nicht alle Standardmodule, z. B. kein "webbrowser".
# Fehlt es, kommt ein Mini-Ersatz nach $BASE/pyshims (wird per PYTHONPATH eingebunden).
ensure_pyshims() {
    mkdir -p "$BASE/pyshims"
    if python3 -c 'import webbrowser' 2>/dev/null && [ ! -f "$BASE/pyshims/.webbrowser_stub" ]; then
        return 0
    fi
    if python3 -c 'import webbrowser' 2>/dev/null; then rm -f "$BASE/pyshims/webbrowser.py" "$BASE/pyshims/.webbrowser_stub"; return 0; fi
    cat > "$BASE/pyshims/webbrowser.py" <<'NC_WB_EOF'
"""Minimaler Ersatz fuer das fehlende Modul webbrowser (Netzwerk-Core, kein Browser auf dem Router)."""
class Error(Exception):
    pass

def open(url, new=0, autoraise=True):
    return False

open_new = open_new_tab = open

def get(using=None):
    raise Error("kein Browser verfuegbar")

def register(*args, **kwargs):
    return None
NC_WB_EOF
    touch "$BASE/pyshims/.webbrowser_stub"
}

# Port in einer config.yaml ("server:" -> "port:") setzen; gibt "changed" / "error" aus
set_yaml_port() {   # datei port
    [ -f "$1" ] || return 0
    python3 - "$1" "$2" <<'NC_PYYAML_EOF'
import re, sys
f, p = sys.argv[1], int(sys.argv[2])
raw = open(f, "rb").read().decode("utf-8-sig", "replace")
lines = raw.split("\n")
inside = False
for i, l in enumerate(lines):
    if re.match(r"^server:\s*(#.*)?$", l.rstrip("\r")):
        inside = True
        continue
    if inside:
        if l.strip() and not l[0].isspace() and not l.lstrip().startswith("#"):
            break
        m = re.match(r"^(\s+port:\s*)(\d+)(.*)$", l.rstrip("\r"))
        if m:
            if int(m.group(2)) == p:
                sys.exit(0)
            lines[i] = m.group(1) + str(p) + m.group(3) + ("\r" if l.endswith("\r") else "")
            open(f, "w", encoding="utf-8").write("\n".join(lines))
            print("changed")
            sys.exit(0)
print("error")
NC_PYYAML_EOF
}

# Anwendungen, deren Web-Port in einer Konfigurationsdatei steht (nicht per Argument)
PORT_CFG_IDS="netzwerkplan rohrleitung kabelmanager ablaufplan overwatch"
set_app_port() {   # id workdir port
    case "$1" in
        netzwerkplan|rohrleitung|kabelmanager|ablaufplan) set_json_port "$2/config.json" "$3" ;;
        overwatch) set_yaml_port "$2/config.yaml" "$3" ;;
    esac
}

repo_path() { case "$1" in */*) echo "$1" ;; *) echo "$OWNER/$1" ;; esac; }

remote_sha() {
    for br in main master; do
        s=$(gh_curl -H "Accept: application/vnd.github.sha" \
            "https://api.github.com/repos/$(repo_path "$1")/commits/$br" 2>/dev/null | head -c 40)
        case "$s" in
            [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) echo "$s"; return 0 ;;
        esac
    done
    return 1
}

fetch_repo() {   # repo tmpdir
    for br in main master; do
        if gh_curl -o "$2/src.tgz" "https://codeload.github.com/$(repo_path "$1")/tar.gz/refs/heads/$br"; then
            mkdir -p "$2/x" && tar -xzf "$2/src.tgz" -C "$2/x" && return 0
        fi
    done
    return 1
}

# Dateien, die beim Update NICHT ueberschrieben werden (Nutzerdaten)
is_preserved() {
    case "$1" in
        config.json|*/config.json|markers.json|*/markers.json|config.yaml|*/config.yaml|*.mbtiles) return 0 ;;
        *.db|*.sqlite|*.sqlite3) return 0 ;;
        data/*|*/data/*|daten/*|*/daten/*|uploads/*|*/uploads/*) return 0 ;;
        print_history/*|*/print_history/*) return 0 ;;
    esac
    return 1
}

# Dateien, die auf dem Router nicht gebraucht werden (Windows/Mac-Builds)
is_skipped() {
    case "$1" in
        .github/*|Release/*|"Programme (exe)"/*|packaging/*|*/Entwürfe/*|*/build/*|offline_build_kit/*|brume2/*) return 0 ;;
        *.exe|*.zip|.DS_Store|*/.DS_Store|*.spec) return 0 ;;
    esac
    return 1
}

# Liegt der Code in versionierten Ordnern (z. B. "Programme (py)/V1.9"), den hoechsten nehmen
pick_workdir() {
    ls "$1"/*.py >/dev/null 2>&1 && { echo "$1"; return; }
    v=$(ls -d "$1"/V[0-9]* 2>/dev/null | sort -V 2>/dev/null | tail -n1)
    [ -n "$v" ] || v=$(ls -d "$1"/V[0-9]* 2>/dev/null | sort | tail -n1)
    if [ -n "$v" ]; then echo "$v"; else echo "$1"; fi
}

resolve_entry() {   # workdir entry
    if [ -n "$2" ] && [ "$2" != "auto" ] && [ -f "$1/$2" ]; then echo "$2"; return; fi
    for c in app.py main.py server.py; do
        [ -f "$1/$c" ] && { echo "$c"; return; }
    done
    best=""
    for f in "$1"/*.py; do
        [ -f "$f" ] || continue
        grep -q -E '\.run\(' "$f" && best=$(basename "$f")
    done
    echo "$best"
}

# Python-Abhaengigkeiten je Anwendung isoliert in .pylibs
python_deps() {
    reqsrc="$workdir/requirements.txt"; [ -f "$reqsrc" ] || reqsrc="$appdir/requirements.txt"
    if [ -f "$reqsrc" ]; then
        grep -v -i -E '^[[:space:]]*(pyinstaller|#|$)' "$reqsrc" > "$tmp/req.txt"
    elif [ -f "$workdir/Python.txt" ]; then
        # Zeilen wie "py -3.11 -m pip install flask==3.0" -> "flask==3.0"
        tr -d '\r' < "$workdir/Python.txt" | sed -n 's/.*pip install //p' | grep -v -i pyinstaller > "$tmp/req.txt"
    else
        : > "$tmp/req.txt"
        grep -q -E '^[[:space:]]*(import|from)[[:space:]]+flask' "$workdir"/*.py 2>/dev/null && echo flask >> "$tmp/req.txt"
        grep -q -E '^[[:space:]]*(import|from)[[:space:]]+paho' "$workdir"/*.py 2>/dev/null && echo paho-mqtt >> "$tmp/req.txt"
    fi
    if ! grep -q '[^[:space:]]' "$tmp/req.txt"; then
        mkdir -p "$appdir/.pylibs"     # nur Standardbibliothek noetig
        echo none > "$appdir/.nc_req"
    fi
    sum=$(md5sum "$tmp/req.txt" | cut -d' ' -f1)
    if grep -q '[^[:space:]]' "$tmp/req.txt" && { [ "$sum" != "$(cat "$appdir/.nc_req" 2>/dev/null)" ] || [ ! -d "$appdir/.pylibs" ]; }; then
        log "Installiere Python-Pakete ..."
        if python3 -m pip install --no-cache-dir --disable-pip-version-check --upgrade \
              --target "$appdir/.pylibs" -r "$tmp/req.txt"; then
            echo "$sum" > "$appdir/.nc_req"
        else
            # Einzeln nachinstallieren, bei Fehlern ohne feste Version (neuere Versionen haben oft passende Wheels)
            log "Gesamtinstallation fehlgeschlagen - installiere Pakete einzeln ..."
            bad=0
            while IFS= read -r pk; do
                [ -n "$(echo "$pk" | tr -d ' \r')" ] || continue
                python3 -m pip install --no-cache-dir --disable-pip-version-check --upgrade --target "$appdir/.pylibs" "$pk" >/dev/null 2>&1 && continue
                pn=$(echo "$pk" | sed 's/[=<>~!;[ ].*//')
                if python3 -m pip install --no-cache-dir --disable-pip-version-check --upgrade --target "$appdir/.pylibs" "$pn" >/dev/null 2>&1; then
                    log "  $pn: ohne feste Version installiert"
                else
                    log "  WARNUNG: Paket $pn nicht installierbar"; bad=$((bad+1))
                fi
            done < "$tmp/req.txt"
            if [ $bad -gt 0 ]; then log "FEHLER: $bad Paket(e) fehlen - die Anwendung startet evtl. nicht"; return 1; fi
            echo "$sum" > "$appdir/.nc_req"
        fi
    fi
    interp=/usr/bin/python3
    return 0
}

# Node.js-Anwendungen: node/npm per opkg, Pakete per npm. Native Module (kein C-Compiler
# auf dem Router) werden durch die JavaScript-Ersatzmodule in $BASE/shims ersetzt.
node_deps() {
    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        log "Installiere Node.js (opkg: node, node-npm) ..."
        opkg update >/dev/null 2>&1
        opkg install node node-npm || { log "FEHLER: Pakete node/node-npm sind nicht installierbar"; return 1; }
    fi
    command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 || { log "FEHLER: node/npm fehlt"; return 1; }
    log "Node.js $(node -v), npm $(npm -v)"
    sum=$(md5sum "$workdir/package.json" 2>/dev/null | cut -d' ' -f1)
    if [ "$sum" != "$(cat "$appdir/.nc_req" 2>/dev/null)" ] || [ ! -d "$workdir/node_modules" ]; then
        log "Installiere Node-Pakete (npm, das dauert einige Minuten) ..."
        if ! (cd "$workdir" && npm install --production --ignore-scripts --no-audit --no-fund --no-progress \
                  --cache "$tmp/npmcache" tweetnacl@1.0.3); then
            log "FEHLER: npm install fehlgeschlagen"; return 1
        fi
        echo "$sum" > "$appdir/.nc_req"
    fi
    # Ersatzmodule fuer native Pakete immer (erneut) einspielen
    for sd in "$BASE"/shims/*/; do
        m=$(basename "$sd")
        find "$workdir/node_modules" -type d -name "$m" 2>/dev/null | while read -r t; do
            rm -rf "$t"; cp -r "$sd" "$t"; log "JavaScript-Ersatz fuer natives Modul $m eingespielt"
        done
    done
    interp=$(command -v node)
    return 0
}

# HomeKit2MQTT: Pincode, Bridge-Kennung und Mapping-Datei einmalig anlegen (ausserhalb des Programmordners)
init_homekit() {
    d="$BASE/data/homekit"; mkdir -p "$d"
    [ -f "$d/map.json" ] || echo '{}' > "$d/map.json"
    if [ ! -s "$d/pincode" ]; then
        i=0
        while [ $i -lt 30 ]; do
            i=$((i+1)); n=$(tr -dc '0-9' < /dev/urandom | head -c 8)
            [ ${#n} -eq 8 ] || continue
            case "$n" in 00000000|11111111|22222222|33333333|44444444|55555555|66666666|77777777|88888888|99999999|12345678|87654321) continue ;; esac
            echo "$(echo "$n" | cut -c1-3)-$(echo "$n" | cut -c4-5)-$(echo "$n" | cut -c6-8)" > "$d/pincode"; break
        done
        [ -s "$d/pincode" ] || echo "482-17-306" > "$d/pincode"
    fi
    if [ ! -s "$d/username" ]; then
        echo "CC:22:3D:$(tr -dc 'A-F0-9' < /dev/urandom | head -c 6 | sed 's/\(..\)\(..\)\(..\)/\1:\2:\3/')" > "$d/username"
    fi
    chmod 600 "$d/pincode"
    log "HomeKit-Pincode: $(cat "$d/pincode")   (Datei: $d/pincode, Web-UI-Login: homekit / Pincode)"
}

# Anwendung installieren bzw. aktualisieren
deploy_app() {   # id
    id="$1"
    name=$(app_field "$id" 2); repo=$(app_field "$id" 3); port=$(app_field "$id" 4)
    entry=$(app_field "$id" 5); subdir=$(app_field "$id" 6); envs=$(app_field "$id" 7)
    args=$(app_field "$id" 9)
    [ -n "$repo" ] || { log "Unbekannte Anwendung: $id"; return 1; }
    appdir="$BASE/apps/$id"
    log "=== $name ($repo) ==="

    tmp=$(mktemp -d /tmp/nc.XXXXXX)
    sha=$(remote_sha "$repo")
    if ! fetch_repo "$repo" "$tmp"; then
        log "FEHLER: Repo $(repo_path "$repo") nicht ladbar (privat oder Name falsch?). Bei privaten Repos Token in $BASE/github_token ablegen."
        rm -rf "$tmp"; return 1
    fi
    src=$(ls -d "$tmp"/x/*/ 2>/dev/null | head -n1); src=${src%/}
    [ -d "$src" ] || { log "FEHLER: Archiv leer"; rm -rf "$tmp"; return 1; }

    mkdir -p "$appdir"

    # Repo gewechselt (z. B. MQTT-Dashboard-MK3 -> MK4): alte Dateien entfernen,
    # Einstellungen (*.json) vorher sichern und fuer die neue Version bereitstellen
    oldrepo=$(cat "$appdir/.nc_repo" 2>/dev/null)
    [ -z "$oldrepo" ] && [ "$id" = "dashboard" ] && [ -f "$appdir/.nc_ok" ] && oldrepo="MQTT-Dashboard-MK3"
    if [ -n "$oldrepo" ] && [ "$oldrepo" != "$repo" ]; then
        log "Repo-Wechsel $oldrepo -> $repo: Einstellungen werden uebernommen"
        mkdir -p "$tmp/keep"
        oldwd=$(cat "$appdir/.nc_workdir" 2>/dev/null); [ -d "$oldwd" ] || oldwd="$appdir"
        for f in "$oldwd"/*.json "$appdir"/*.json; do [ -f "$f" ] && cp -n "$f" "$tmp/keep/"; done
        /etc/init.d/nc-$id stop 2>/dev/null
        find "$appdir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    fi
    echo "$repo" > "$appdir/.nc_repo"

    # Repos mit eigenem Installer (z. B. Klingelbildschirm: ffmpeg, Autostart, Konfig)
    case "$entry" in
        @*)
            inst="${entry#@}"
            [ -f "$src/$inst" ] || { log "FEHLER: $inst fehlt im Repo"; rm -rf "$tmp"; return 1; }
            log "Starte Installer des Repos ($inst) ..."
            (cd "$src" && sh "./$inst" </dev/null); rc=$?
            [ $rc -ne 0 ] && log "HINWEIS: $inst endete mit Code $rc - pruefe, ob der Dienst trotzdem laeuft"
            # Vom Repo-Installer angelegte Dienste sauber neu starten: erst alle stoppen, uebrig gebliebene
            # (verwaiste) Prozesse der alten Version beenden, dann starten - sonst laeuft die alte Version weiter
            svs=""
            for sv in $(grep -il -e "$id" -e doorbell /etc/init.d/* 2>/dev/null); do
                case "$sv" in /etc/init.d/nc-core|/etc/init.d/nc-firstrun) continue ;; esac
                [ -x "$sv" ] && svs="$svs $sv"
            done
            for sv in $svs; do "$sv" stop >/dev/null 2>&1; done
            sleep 2
            for sig in TERM KILL; do
                for pid in $(ps 2>/dev/null | grep -i -e "$id" -e doorbell | grep -v -e grep -e Netzwerk-Core | awk '{print $1}'); do
                    [ "$pid" = "$$" ] && continue
                    [ "$sig" = TERM ] && log "Beende alten Prozess $pid"
                    kill -$sig "$pid" 2>/dev/null
                done
                sleep 2
            done
            for sv in $svs; do
                log "Starte Dienst: $(basename "$sv")"
                "$sv" start >/dev/null 2>&1
            done
            sleep 6
            if netstat -lnt 2>/dev/null | grep -q ":$port "; then
                log "OK: $name laeuft auf Port $port"
            elif [ $rc -ne 0 ]; then
                log "FEHLER: $inst fehlgeschlagen und $name lauscht nicht auf Port $port"; rm -rf "$tmp"; return 1
            else
                log "WARNUNG: $name lauscht nicht auf Port $port - Log siehe Repo-Anleitung"
            fi
            [ -f "$src/VERSION" ] && cp -f "$src/VERSION" "$appdir/VERSION"
            echo "$sha" > "$appdir/.nc_sha"; touch "$appdir/.nc_ok"
            rm -rf "$tmp"
            return 0 ;;
    esac

    (cd "$src" && find . -type f) | while read -r f; do
        f=${f#./}
        is_skipped "$f" && continue
        dest="$appdir/$f"
        if [ -e "$dest" ] && is_preserved "$f"; then continue; fi
        mkdir -p "$(dirname "$dest")"
        cp -f "$src/$f" "$dest"
    done
    # Dateiliste des Repos merken: alles andere im Ordner sind Einstellungen/Daten (Sicherung per ZIP)
    (cd "$src" && find . -type f) | sed 's#^\./##' | while read -r f; do is_skipped "$f" || echo "$f"; done > "$appdir/.nc_files"

    workdir="$appdir"; [ -n "$subdir" ] && workdir="$appdir/$subdir"
    workdir=$(pick_workdir "$workdir")
    if [ -d "$tmp/keep" ]; then
        for f in "$tmp"/keep/*.json; do [ -f "$f" ] && cp -n "$f" "$workdir/"; done
    fi
    old=$(cat "$appdir/.nc_workdir" 2>/dev/null)
    if [ -n "$old" ] && [ "$old" != "$workdir" ] && [ -d "$old" ]; then
        log "Neuer Versionsordner - uebernehme Einstellungen aus $old"
        for f in "$old"/*.json; do [ -f "$f" ] && cp -n "$f" "$workdir/"; done
        rm -rf "$old"
    fi
    echo "$workdir" > "$appdir/.nc_workdir"
    entry=$(resolve_entry "$workdir" "$entry")
    if [ -z "$entry" ]; then
        log "FEHLER: keine Startdatei gefunden in $workdir"; rm -rf "$tmp"; return 1
    fi
    log "Startdatei: $entry"

    # Abhaengigkeiten (Python oder Node.js, je nach Startdatei)
    case "$entry" in
        *.js) node_deps ;;
        *)    python_deps ;;
    esac || { rm -rf "$tmp"; return 1; }
    [ "$id" = "homekit" ] && init_homekit
    # Anwendungen mit Port in der Konfigurationsdatei (8080 kollidiert mit der Router-Oberflaeche)
    case "$(set_app_port "$id" "$workdir" "$port")" in
        changed) log "Port in der Konfigurationsdatei auf $port gesetzt" ;;
        error)   log "WARNUNG: Port in $workdir nicht aenderbar - bitte server.port = $port selbst eintragen" ;;
    esac

    ensure_pyshims
    # Startskript + Autostart (procd)
    cat > "$BASE/run/$id.sh" <<RUN_EOF
#!/bin/sh
cd "$workdir" || exit 1
[ -r /etc/TZ ] && export TZ="\$(cat /etc/TZ)"
export PYTHONPATH="$appdir/.pylibs:$BASE/pyshims" PYTHONUNBUFFERED=1
exec env $envs $interp "$entry" $args
RUN_EOF
    chmod +x "$BASE/run/$id.sh"

    cat > "/etc/init.d/nc-$id" <<INIT_EOF
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /bin/sh "$BASE/run/$id.sh"
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
INIT_EOF
    chmod +x "/etc/init.d/nc-$id"
    "/etc/init.d/nc-$id" enable
    "/etc/init.d/nc-$id" restart

    echo "$sha" > "$appdir/.nc_sha"
    touch "$appdir/.nc_ok"
    rm -rf "$tmp"

    sleep 5
    if netstat -lnt 2>/dev/null | grep -q ":$port "; then
        log "OK: $name laeuft auf Port $port"
    else
        log "WARNUNG: $name lauscht nicht auf Port $port - Log: logread | grep nc-$id"
        logread 2>/dev/null | grep -F "nc-$id" | tail -n 8 | while IFS= read -r l; do log "  | $l"; done
    fi
    return 0
}
NC_LIB_EOF

# ---------------------------------------------------------------------------
# Update-Script (wird von der Statusseite aufgerufen)
# ---------------------------------------------------------------------------
cat > "$BASE/bin/nc-update.sh" <<'NC_UPDATE_EOF'
#!/bin/sh
. /root/Netzwerk-Core/bin/nc-lib.sh
target="$1"
log "Update gestartet: ${target:-all}"
if [ -z "$target" ] || [ "$target" = "all" ]; then
    for id in $(active_ids); do deploy_app "$id"; done
else
    unmark_removed "$target"
    deploy_app "$target"
fi
sync
log "Update beendet."
NC_UPDATE_EOF

# ---------------------------------------------------------------------------
# Dienst deinstallieren (wird von der Statusseite aufgerufen)
#   nc-uninstall.sh <id> keep     Dienst entfernen, Einstellungen/Daten behalten
#   nc-uninstall.sh <id> delete   Dienst samt Daten entfernen
# ---------------------------------------------------------------------------
cat > "$BASE/bin/nc-uninstall.sh" <<'NC_UNINSTALL_EOF'
#!/bin/sh
. /root/Netzwerk-Core/bin/nc-lib.sh
id="$1"; mode="${2:-keep}"
name=$(app_field "$id" 2)
[ -n "$name" ] || { log "Unbekannte Anwendung: $id"; exit 1; }
appdir="$BASE/apps/$id"
log "Deinstalliere $name (Daten: $([ "$mode" = delete ] && echo loeschen || echo behalten)) ..."

# Autostart-Dienste stoppen und entfernen (eigener Dienst + ggf. vom Repo-Installer angelegte)
for s in "/etc/init.d/nc-$id" $(grep -l -e "$appdir/" /etc/init.d/* 2>/dev/null); do
    [ -f "$s" ] || continue
    case "$s" in /etc/init.d/nc-core|/etc/init.d/nc-firstrun) continue ;; esac
    "$s" stop >/dev/null 2>&1; "$s" disable >/dev/null 2>&1
    rm -f "$s"; log "Dienst entfernt: $(basename "$s")"
done
# uebrig gebliebene Prozesse der Anwendung beenden
for pid in $(ps 2>/dev/null | grep -F "$appdir/" | grep -v grep | awk '{print $1}'); do
    [ "$pid" = "$$" ] || kill "$pid" 2>/dev/null
done

rm -f "$BASE/run/$id.sh" "$appdir/.nc_ok" "$appdir/.nc_sha" "$appdir/.nc_workdir"
if [ "$mode" = "delete" ]; then
    rm -rf "$appdir" "$BASE/data/$id"
    log "Programmdateien und Daten geloescht."
else
    log "Einstellungen/Daten bleiben erhalten (bei erneuter Installation wieder da)."
fi
mark_removed "$id"
sync
log "$name wurde deinstalliert. Mit \"Installieren\" auf der Kachel jederzeit wieder einrichten."
NC_UNINSTALL_EOF

# ---------------------------------------------------------------------------
# Selbst-Update: neueste Version dieses Skripts aus GitHub holen und im
# Update-Modus ausfuehren (wird von der Statusseite aufgerufen)
# ---------------------------------------------------------------------------
cat > "$BASE/bin/nc-selfupdate.sh" <<'NC_SELFUPDATE_EOF'
#!/bin/sh
# Auf eine Kopie umschalten: das Update ueberschreibt dieses Skript, waehrend es laeuft.
if [ "$NC_SU_COPY" != "1" ]; then
    cp "$0" /tmp/nc-selfupdate-run.sh && NC_SU_COPY=1 exec /bin/sh /tmp/nc-selfupdate-run.sh "$@"
fi
. /root/Netzwerk-Core/bin/nc-lib.sh
SELF_REPO=Scorch1262/Network-Core-MK1
SELF_FILE=netzwerk-core-install.sh

say() { log "$*"; echo "$*" > "$BASE/selfupdate.last"; }
fail() { say "FEHLER: $* - Selbst-Update abgebrochen."; rm -rf "$tmp"; exit 1; }

log "Selbst-Update gestartet"
tmp=$(mktemp -d /tmp/nc-self.XXXXXX) || fail "kein temporaerer Ordner"
f="$tmp/$SELF_FILE"

# Download ohne CDN-Cache: erst GitHub-API (immer aktuell), dann raw mit Cache-Umgehung
got=0
for br in main master; do
    for m in api raw; do
        rm -f "$f"
        if [ $m = api ]; then
            gh_curl -H "Accept: application/vnd.github.raw" -o "$f" \
                "https://api.github.com/repos/$SELF_REPO/contents/$SELF_FILE?ref=$br" 2>/dev/null
        else
            gh_curl -o "$f" "https://raw.githubusercontent.com/$SELF_REPO/$br/$SELF_FILE?nc=$(date +%s)" 2>/dev/null
        fi
        if [ -s "$f" ] && head -n1 "$f" | grep -q '^#!/bin/sh'; then got=1; log "Skript geladen ($m, Branch $br, $(wc -c < "$f") Bytes)"; break 2; fi
    done
done
[ $got = 1 ] || fail "Skript konnte nicht von GitHub geladen werden ($SELF_REPO, Datei $SELF_FILE im Hauptverzeichnis)"

head -n1 "$f" | grep -q '^#!/bin/sh' || fail "heruntergeladene Datei ist kein Shell-Skript"
sh -n "$f" 2>/dev/null || fail "heruntergeladenes Skript hat Syntaxfehler"
grep -q 'NC_SELF_UPDATE' "$f" || fail "die Version auf GitHub kennt den Update-Modus nicht - bitte manuell ausfuehren"

oldv=$(sed -n 's/^NC_VERSION = "\(.*\)"/\1/p' "$BASE/bin/nc-core.py" | head -n1)
newv=$(sed -n 's/^NC_VERSION = "\(.*\)"/\1/p' "$f" | head -n1)
log "Version: ${oldv:-?} -> ${newv:-?}"
[ "$oldv" = "$newv" ] && log "HINWEIS: GitHub liefert dieselbe Version (${newv:-?}). Wurde die neue Datei im Hauptverzeichnis hochgeladen und NC_VERSION erhoeht?"

cp "$f" "$BASE/netzwerk-core-install.sh"
if NC_SELF_UPDATE=1 NC_SKIP_NETWORK=1 /bin/sh "$f"; then
    rm -rf "$tmp"
    sync
    say "Selbst-Update $(date '+%H:%M'): Version ${oldv:-?} -> ${newv:-?} abgeschlossen."
    # Statusseite erst ganz zum Schluss neu starten (dieses Skript wird von ihr gestartet)
    ( sleep 3; /etc/init.d/nc-core restart ) >/dev/null 2>&1 &
    exit 0
fi

say "FEHLER: das neue Skript (Version ${newv:-?}) ist fehlgeschlagen - vorherige Version ${oldv:-?} wiederhergestellt. Details: Protokoll."
if [ -d "$BASE/backup-core/bin" ]; then
    cp -f "$BASE"/backup-core/bin/* "$BASE/bin/" 2>/dev/null
    [ -f "$BASE/backup-core/apps.conf" ] && cp -f "$BASE/backup-core/apps.conf" "$BASE/apps.conf"
    log "Rollback abgeschlossen."
fi
rm -rf "$tmp"
( sleep 3; /etc/init.d/nc-core restart ) >/dev/null 2>&1 &
exit 1
NC_SELFUPDATE_EOF

# ---------------------------------------------------------------------------
# Statusseite "Netzwerk-Core" (nur Python-Standardbibliothek)
# ---------------------------------------------------------------------------
cat > "$BASE/bin/nc-core.py" <<'NC_CORE_EOF'
#!/usr/bin/env python3
"""Netzwerk-Core - Statusseite mit Kacheln und Update-Button."""
import json, os, re, shutil, socket, subprocess, threading, time, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NC_VERSION = "1.7.1"
BASE = os.environ.get("NC_BASE", "/root/Netzwerk-Core")
PORT = int(os.environ.get("NC_PORT", "8090"))
OWNER = "Scorch1262"
CONF = os.path.join(BASE, "apps.conf")
APPS_DIR = os.path.join(BASE, "apps")
LOG = os.path.join(BASE, "update.log")
UPDATE = os.path.join(BASE, "bin", "nc-update.sh")
SELFUPDATE = os.path.join(BASE, "bin", "nc-selfupdate.sh")
SELF_REPO = "Scorch1262/Network-Core-MK1"
SELF_FILE = "netzwerk-core-install.sh"
REMOTE_CORE = {"version": ""}

REMOTE = {}
_lock = threading.Lock()
_proc = None


def read(path, limit=400000):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read(limit).strip()
    except OSError:
        return ""


def load_apps():
    apps = []
    for line in read(CONF).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        p = (line.split("|") + [""] * 8)[:8]
        try:
            port = int(p[3])
        except ValueError:
            port = 0
        apps.append(dict(id=p[0], name=p[1], repo=p[2], port=port,
                         subdir=p[5], desc=p[7]))
    return apps


def port_up(port):
    try:
        with socket.create_connection(("127.0.0.1", port), 0.6):
            return True
    except OSError:
        return False


VER_RE = re.compile(r"""^[ \t]*(?:APP_|__)?VERSION(?:__)?[ \t]*(?::[ \t]*str[ \t]*)?=[ \t]*['"]v?([0-9][^'"]*)['"]""", re.I | re.M)
CHL_RE = re.compile(r"^#+[ \t]*\[?v?([0-9]+\.[0-9]+(?:\.[0-9]+)?)", re.M)


def app_version(wd, appdir=""):
    for d in (wd, appdir):
        if not d:
            continue
        m = re.search(r'"version"\s*:\s*"([^"]+)"', read(os.path.join(d, "package.json"), 20000))
        if m:
            return m.group(1)
        for n in ("VERSION", "version.txt"):
            v = read(os.path.join(d, n), 50)
            if v and len(v) < 30:
                return v.lstrip("vV")
    try:
        files = sorted(f for f in os.listdir(wd) if f.endswith(".py"))
    except OSError:
        files = []
    for f in files:
        m = VER_RE.search(read(os.path.join(wd, f)))
        if m:
            return m.group(1)
    for d in (wd, appdir):
        if d:
            m = CHL_RE.search(read(os.path.join(d, "CHANGELOG.md"), 20000))
            if m:
                return m.group(1)
    return ""


# Anwendungen, deren "Oeffnen"-Link auf eine andere Seite/Port zeigt (Klingel: Einrichtungsseite)
OPEN_PORT = {"klingel": 8083}


def app_status(a):
    d = os.path.join(APPS_DIR, a["id"])
    installed = os.path.exists(os.path.join(d, ".nc_ok"))
    wd = read(os.path.join(d, ".nc_workdir"), 500) or (os.path.join(d, a["subdir"]) if a["subdir"] else d)
    local = read(os.path.join(d, ".nc_sha"), 60)
    remote = REMOTE.get(a["repo"], "")
    return dict(id=a["id"], name=a["name"], desc=a["desc"], port=a["port"],
                open_port=OPEN_PORT.get(a["id"], a["port"]), web=True, manage=True, installed=installed,
                up=port_up(a["port"]),
                version=app_version(wd, d) if installed else "",
                help=(a["id"] == "homekit"),
                update=bool(installed and local and remote and local != remote))


def all_status():
    apps = [app_status(a) for a in load_apps()]
    apps.append(dict(id="mosquitto", name="Mosquitto Broker",
                     desc="MQTT-Broker dieses Routers", port=1883, web=False,
                     manage=False, installed=True, up=port_up(1883),
                     version="", update=False))
    return apps


NET = os.path.join(BASE, "bin", "nc-network.sh")
UNINSTALL = os.path.join(BASE, "bin", "nc-uninstall.sh")


def help_homekit(host):
    d = os.path.join(BASE, "data", "homekit")
    pin = read(os.path.join(d, "pincode"), 40)
    user = read(os.path.join(d, "username"), 40)
    if not pin or not os.path.exists(os.path.join(APPS_DIR, "homekit", ".nc_ok")):
        return dict(title="HomeKit2MQTT - Einrichtung", creds=[], tips=[], steps=[dict(
            t="Noch nicht installiert",
            d="HomeKit2MQTT ist nicht installiert. Auf der Kachel \"Installieren\" klicken; danach steht hier die Anleitung mit den Zugangsdaten.")])
    digits = pin.replace("-", "")
    creds = [["HomeKit-Code (Home-App)", pin + "  (manuell: " + digits + ")"],
             ["Bridge-Name", "Netzwerk-Core"],
             ["Bridge-ID", user],
             ["Web-Oberfl\u00e4che", "http://%s:51888/" % host],
             ["Web-Login Benutzer", "homekit"],
             ["Web-Login Passwort", pin],
             ["MQTT-Broker (dieser Router)", "%s:1883  (intern 127.0.0.1)" % host],
             ["HomeKit-Port (TCP)", "51826"]]
    steps = [
        dict(t="Voraussetzungen", d="iPhone/iPad (Home-App) muss im selben Netzwerk sein wie der Router. Die Kachel HomeKit2MQTT muss mit gr\u00fcnem Punkt \"l\u00e4uft\" anzeigen."),
        dict(t="Bridge in der Home-App hinzuf\u00fcgen", d="Home-App \u00f6ffnen \u2192 \"+\" \u2192 \"Gerät hinzuf\u00fcgen\" \u2192 \"Weitere Optionen\u2026\" \u2192 die Bridge \"Netzwerk-Core\" antippen. Die Meldung \"Nicht zertifiziertes Zubeh\u00f6r\" mit \"Trotzdem hinzuf\u00fcgen\" best\u00e4tigen."),
        dict(t="Code eingeben", d="\"Code manuell eingeben\" w\u00e4hlen und den HomeKit-Code oben eintragen (%s). Danach Raum und Namen w\u00e4hlen und fertig." % digits),
        dict(t="Web-Oberfl\u00e4che \u00f6ffnen", d="Auf der Kachel \"\u00d6ffnen\" klicken (oder %s im Browser aufrufen) und mit Benutzer \"homekit\" und dem Pincode als Passwort anmelden." % ("http://%s:51888/" % host)),
        dict(t="Ger\u00e4te anlegen", d="In der Web-Oberfl\u00e4che ein neues Ger\u00e4t hinzuf\u00fcgen: Name, Typ (z. B. Lightbulb, Switch, TemperatureSensor) und die MQTT-Topics f\u00fcr Status (Werte vom Ger\u00e4t) und Setzen (Befehle an das Ger\u00e4t) eintragen und speichern. Als Broker dient der Mosquitto dieses Routers. Die Feldnamen k\u00f6nnen je nach Programmversion leicht abweichen."),
        dict(t="Testen", d="Einen Wert ver\u00f6ffentlichen, z. B. mosquitto_pub -h %s -t <Status-Topic> -m <Wert>, und in der Home-App pr\u00fcfen, ob sich das Ger\u00e4t \u00e4ndert. Neue Ger\u00e4te erscheinen meist sofort, sonst die Home-App kurz schlie\u00dfen und neu \u00f6ffnen." % host)]
    tips = ["Bridge wird nicht gefunden: gleiches Netzwerk/VLAN pr\u00fcfen, Port 51826 (TCP) und Multicast (Bonjour) m\u00fcssen durchgelassen werden; notfalls Router und iPhone neu starten.",
            "Neu koppeln: Bridge in der Home-App entfernen, hier auf der Kachel \"Deinstallieren\" (Daten l\u00f6schen) und danach \"Installieren\". Es entstehen ein neuer Code und eine neue Bridge-ID, die hier dann automatisch angezeigt werden.",
            "Die Zugangsdaten liegen auf dem Router in /root/Netzwerk-Core/data/homekit/ (pincode, username)."]
    return dict(title="HomeKit2MQTT - Einrichtung", creds=creds, steps=steps, tips=tips)


def sh(cmd):
    try:
        return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              universal_newlines=True, timeout=5).stdout.strip()
    except Exception:
        return ""


def net_status():
    ip = sh(["sh", "-c", "ubus call network.interface.lan status 2>/dev/null | "
                         "jsonfilter -e '@[\"ipv4-address\"][0].address'"])
    return dict(proto=sh(["uci", "-q", "get", "network.lan.proto"]), ip=ip,
                dhcp_server=sh(["uci", "-q", "get", "dhcp.lan.ignore"]) != "1")


def fetch_sha(repo):
    hdr = {"Accept": "application/vnd.github.sha", "User-Agent": "netzwerk-core"}
    tok = read(os.path.join(BASE, "github_token"), 200)
    if tok:
        hdr["Authorization"] = "token " + tok
    for br in ("main", "master"):
        try:
            req = urllib.request.Request(
                "https://api.github.com/repos/%s/commits/%s" % (repo if "/" in repo else OWNER + "/" + repo, br), headers=hdr)
            with urllib.request.urlopen(req, timeout=10) as r:
                s = r.read().decode().strip()
            if re.fullmatch(r"[0-9a-f]{40}", s):
                return s
        except Exception:
            continue
    return ""


def vtuple(v):
    return tuple(int(x) for x in re.findall(r"\d+", v or "")[:4])


def fetch_core_version():
    hdr = {"User-Agent": "netzwerk-core"}
    tok = read(os.path.join(BASE, "github_token"), 200)
    if tok:
        hdr["Authorization"] = "token " + tok
    for br in ("main", "master"):
        try:
            req = urllib.request.Request(
                "https://raw.githubusercontent.com/%s/%s/%s?nc=%d" % (SELF_REPO, br, SELF_FILE, int(time.time())), headers=hdr)
            with urllib.request.urlopen(req, timeout=15) as r:
                head = r.read(300000).decode("utf-8", "replace")
            m = re.search(r'^NC_VERSION\s*=\s*"([^"]+)"', head, re.M)
            if m:
                return m.group(1)
        except Exception:
            continue
    return ""


def selfupdate_last():
    p = os.path.join(BASE, "selfupdate.last")
    try:
        if time.time() - os.path.getmtime(p) > 3600:
            return ""
    except OSError:
        return ""
    return read(p, 400)


def core_status():
    rv = REMOTE_CORE["version"]
    newer = bool(rv) and vtuple(rv) > vtuple(NC_VERSION)
    return dict(version=NC_VERSION, remote=rv, update=newer, last=selfupdate_last())


def refresher():
    while True:
        v = fetch_core_version()
        if v:
            REMOTE_CORE["version"] = v
        for a in load_apps():
            s = fetch_sha(a["repo"])
            if s:
                REMOTE[a["repo"]] = s
        time.sleep(1800)


_restoring = False


def running():
    return _restoring or (_proc is not None and _proc.poll() is None)


def start_uninstall(target, mode):
    global _proc
    with _lock:
        if running():
            return False
        f = open(LOG, "w")
        _proc = subprocess.Popen(["/bin/sh", UNINSTALL, target, mode], stdout=f,
                                 stderr=subprocess.STDOUT)
        f.close()
        return True


def start_selfupdate():
    global _proc
    with _lock:
        if running():
            return False
        f = open(LOG, "w")
        # eigene Sitzung: das Skript startet die Statusseite am Ende selbst neu
        _proc = subprocess.Popen(["/bin/sh", SELFUPDATE], stdout=f,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        f.close()
        return True


def start_update(target):
    global _proc
    with _lock:
        if running():
            return False
        f = open(LOG, "w")
        _proc = subprocess.Popen(["/bin/sh", UPDATE, target], stdout=f,
                                 stderr=subprocess.STDOUT)
        f.close()
        return True


INDEX = r"""<!doctype html>
<html lang="de"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Netzwerk-Core</title>
<style>
:root{--bg:#0f1318;--card:#1a212b;--line:#2a3441;--txt:#e6edf3;--mut:#8b98a8;--acc:#3b82f6;--ok:#22c55e;--bad:#ef4444;--warn:#f59e0b}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--txt);font:15px/1.4 -apple-system,system-ui,Segoe UI,sans-serif}
header{display:flex;flex-wrap:wrap;gap:12px;align-items:center;justify-content:space-between;padding:18px 22px;border-bottom:1px solid var(--line)}
h1{margin:0;font-size:22px}
.sub{color:var(--mut);font-size:13px}
.sub.bad{color:var(--bad)}
.grp{margin:26px 0 10px;font-size:13px;font-weight:600;color:var(--mut);text-transform:uppercase;letter-spacing:.06em;border-bottom:1px solid var(--line);padding-bottom:6px}
.ver{margin-left:auto;font-size:12px;color:var(--mut);white-space:nowrap}
main{padding:22px;max-width:1200px;margin:0 auto}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:14px}
.tile{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;display:flex;flex-direction:column;gap:8px}
.head{display:flex;align-items:center;gap:8px}
.head h3{margin:0;font-size:17px}
.dot{width:10px;height:10px;border-radius:50%;flex:none}
.dot.up{background:var(--ok)}.dot.down{background:var(--bad)}
.desc{margin:0;color:var(--mut);font-size:13px;flex:1}
.meta{font-size:12px;color:var(--mut)}
.badge{display:inline-block;background:var(--warn);color:#111;border-radius:6px;padding:1px 7px;font-size:11px;font-weight:600}
.row{display:flex;gap:8px;margin-top:4px}
a.btn,button{font:inherit;border:0;border-radius:8px;padding:8px 12px;cursor:pointer;text-decoration:none;text-align:center;color:#fff;background:var(--acc)}
a.btn{flex:1}
button.sec{background:#2f3a4a}
button:disabled{opacity:.45;cursor:not-allowed}
a.off{background:#2f3a4a;pointer-events:none;opacity:.5}
pre{background:#0a0d11;border:1px solid var(--line);border-radius:10px;padding:12px;max-height:320px;overflow:auto;font-size:12px;white-space:pre-wrap;margin-top:18px}
#err{color:var(--bad)}
button.del{background:#3a2326;color:#fca5a5}
.gear{position:relative;flex:none;font-size:18px;line-height:1;padding:7px 12px}
.pip{position:absolute;top:4px;right:4px;width:9px;height:9px;border-radius:50%;background:var(--warn)}
a.btn.off{opacity:.45;pointer-events:none}
.row2{display:flex;gap:8px}.row2 button{flex:1;font-size:13px;padding:6px 10px}
#modal{position:fixed;inset:0;background:rgba(0,0,0,.65);display:flex;align-items:flex-start;justify-content:center;padding:24px 12px;overflow:auto;z-index:9}
#modal[hidden]{display:none}
.box{background:var(--card);border:1px solid var(--line);border-radius:14px;max-width:720px;width:100%;padding:20px}
.box h2{margin:0 0 12px;font-size:20px}
.box h4{margin:18px 0 8px;font-size:14px;color:var(--mut);text-transform:uppercase;letter-spacing:.04em}
.cred{display:grid;grid-template-columns:minmax(150px,220px) 1fr;gap:4px 12px;font-size:14px}
.cred span:nth-child(odd){color:var(--mut)}
.cred span:nth-child(even){font-family:ui-monospace,Consolas,monospace;word-break:break-all;user-select:all}
ol.steps{padding-left:22px;margin:0}ol.steps li{margin-bottom:12px}
ol.steps b{display:block}ol.steps span{color:var(--mut);font-size:14px}
ul.tips{margin:0;padding-left:20px;color:var(--mut);font-size:14px}ul.tips li{margin-bottom:8px}
</style></head><body>
<header>
 <div><h1>Netzwerk-Core</h1><div class="sub" id="info"></div></div>
 <div class="row" style="margin:0"><button id="self" class="sec">Skript aktualisieren</button><button id="all" class="sec">Alle aktualisieren</button></div>
</header>
<main>
 <div id="err"></div>
 <div class="tile" id="net" style="margin-bottom:14px" hidden></div>
 <div id="grid"></div>
 <pre id="log" hidden></pre>
</main>
<div id="modal" hidden><div class="box" id="mbox"></div></div>
<script>
const $=s=>document.querySelector(s);
let busy=false;
function el(t,c,x){const e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}
let last=null,openId=null,helpOpen=false,openSig='';
const GROUPS=[
  ['IoT / SmartHome',['mosquitto','flow','dashboard','makro','diagram','kachel','klingel','homekit']],
  ['Planungs Tools',['netzwerkplan','rohrleitung','kabelmanager','ablaufplan']],
  ['Werkstatt',['bambu']],
  ['Sonstiges',['overwatch','outfit','chat']]];
function closeModal(){openId=null;helpOpen=false;openSig='';$('#modal').hidden=true;}
function fmtSize(n){return n>=1048576?(n/1048576).toFixed(1)+' MB':n>=1024?Math.round(n/1024)+' KB':n+' B';}
function render(d){
  last=d;
  const inf=$('#info');inf.textContent='Version '+d.version+' · '+location.hostname;
  if(d.core&&d.core.update){inf.append(' ');inf.append(el('span','badge','Skript-Update '+d.core.remote+' verfügbar'));}
  if(d.core&&d.core.last){inf.append(el('div',d.core.last.indexOf('FEHLER')>=0?'sub bad':'sub',d.core.last));}
  busy=d.running;
  renderNet(d.net);
  const root=$('#grid');root.replaceChildren();
  const mk=a=>{
    const t=el('div','tile'),h=el('div','head');
    h.append(el('span','dot '+(a.up?'up':'down')),el('h3',null,a.name));
    if(a.version)h.append(el('span','ver','v'+a.version));
    t.append(h);
    const r=el('div','row');
    if(a.web){
      const l=el('a','btn'+(a.up?'':' off'),'Öffnen');
      l.href='http://'+location.hostname+':'+(a.open_port||a.port)+'/';l.target='_blank';r.append(l);
    }
    const s=el('button','sec gear','⚙');s.title='Einstellungen';s.setAttribute('aria-label','Einstellungen '+a.name);
    if(a.update)s.append(el('span','pip'));
    s.onclick=()=>openSettings(a.id);r.append(s);
    t.append(r);
    return t;
  };
  GROUPS.forEach(([title,ids],i)=>{
    const items=ids.map(id=>d.apps.find(x=>x.id===id)).filter(Boolean);
    if(i===GROUPS.length-1)d.apps.forEach(a=>{if(!GROUPS.some(g=>g[1].includes(a.id)))items.push(a);});
    if(!items.length)return;
    root.append(el('h2','grp',title));
    const g=el('div','grid');items.forEach(a=>g.append(mk(a)));root.append(g);
  });
  $('#all').disabled=busy;$('#self').disabled=busy;
  if(openId&&!helpOpen){
    const a=d.apps.find(x=>x.id===openId),sig=JSON.stringify([a,busy]);
    if(sig!==openSig)renderSettings();
  }
}
function openSettings(id){openId=id;helpOpen=false;renderSettings();$('#modal').hidden=false;}
function renderSettings(){
  const a=last.apps.find(x=>x.id===openId);
  if(!a){closeModal();return;}
  openSig=JSON.stringify([a,busy]);
  const b=$('#mbox');b.replaceChildren();
  const h=el('h2');h.append(el('span','dot '+(a.up?'up':'down')),' '+a.name);b.append(h);
  b.append(el('p','desc',a.desc));
  const c=el('div','cred');
  const stat=a.up?'läuft':(a.installed?'gestoppt':'nicht installiert');
  c.append(el('span',null,'Status'),el('span',null,stat));
  c.append(el('span',null,'Port'),el('span',null,String(a.port)+(a.open_port&&a.open_port!==a.port?' (Einrichtung: '+a.open_port+')':'')));
  if(a.version)c.append(el('span',null,'Version'),el('span',null,'v'+a.version));
  if(a.update){const u=el('span');u.append(el('span','badge','Update verfügbar'));c.append(el('span',null,'Update'),u);}
  b.append(c);
  if(busy)b.append(el('p','desc','Es läuft gerade eine Aktion - Ablauf im Protokoll unten auf der Seite.'));
  if(a.manage){
    b.append(el('h4',null,'Dienst'));
    const r=el('div','row2');
    const u=el('button',a.update||!a.installed?'':'sec',a.installed?'Update':'Installieren');
    u.disabled=busy;u.onclick=()=>{upd(a.id);closeModal();};r.append(u);
    if(a.installed&&a.help){const x=el('button','sec','❓ Hilfe');x.onclick=()=>help(a.id);r.append(x);}
    if(a.installed){const x=el('button','del','Deinstallieren');x.disabled=busy;x.onclick=()=>{closeModal();uninst(a);};r.append(x);}
    b.append(r);
  }
  if(a.manage&&a.installed){
    b.append(el('h4',null,'Einstellungen & Daten'));
    const info=el('p','desc','Wird geladen ...');b.append(info);
    const r=el('div','row2');
    const dl=el('a','btn','⬇ Sichern (ZIP)');dl.href='/api/backup?id='+encodeURIComponent(a.id);dl.setAttribute('download','');
    const up=el('button','sec','⬆ Hochladen');up.disabled=busy;
    const inp=el('input');inp.type='file';inp.accept='.zip,.json,.ini';inp.hidden=true;
    up.onclick=()=>inp.click();
    const msg=el('p','desc');
    inp.onchange=()=>{if(inp.files[0])doUpload(a,inp.files[0],msg,up);inp.value='';};
    r.append(dl,up,inp);b.append(r,msg);
    b.append(el('p','desc','Hochladen: ZIP einer Sicherung oder eine einzelne Einstellungsdatei (z. B. config.json). Vorher wird automatisch eine Sicherung unter /root/Netzwerk-Core/backup-data/ angelegt, der Dienst startet danach neu.'));
    fetch('/api/files?id='+encodeURIComponent(a.id)).then(x=>x.json()).then(f=>{
      info.textContent=f.total?(f.total+' Datei(en), '+fmtSize(f.size)):'Keine Einstellungs-/Datendateien vorhanden.';
      if(f.total){
        const ul=el('ul','tips');f.files.slice(0,12).forEach(x=>ul.append(el('li',null,x.path+'  ('+fmtSize(x.size)+')')));
        if(f.total>12)ul.append(el('li',null,'… und '+(f.total-12)+' weitere'));
        info.after(ul);
      }else dl.classList.add('off');
    }).catch(()=>{info.textContent='';});
  }
  const x=el('button','sec','Schließen');x.style.marginTop='18px';x.onclick=closeModal;b.append(x);
}
async function doUpload(a,file,msg,btn){
  const zip=/\.zip$/i.test(file.name);
  if(!confirm((zip?'Sicherung ':'Datei ')+file.name+' für '+a.name+' einspielen? Vorhandene Einstellungen/Daten werden ersetzt (automatische Sicherung vorher), der Dienst startet neu.'))return;
  btn.disabled=true;msg.textContent='Wird hochgeladen und eingespielt ...';
  try{
    const r=await fetch('/api/restore?id='+encodeURIComponent(a.id)+'&name='+encodeURIComponent(file.name),{method:'POST',body:file});
    const j=await r.json().catch(()=>({}));
    msg.textContent=r.ok?('✓ '+(j.msg||'fertig')):('Fehler: '+(j.error||('HTTP '+r.status)));
  }catch(e){msg.textContent='Fehler: Verbindung unterbrochen';}
  btn.disabled=false;
}
function renderNet(n){
  const box=$('#net');
  if(!n||!n.proto){box.hidden=true;return;}
  box.hidden=false;box.replaceChildren();
  const h=el('div','head');h.append(el('h3',null,'Netzwerk'));
  const mode=n.proto==='static'?'feste IP':'IP per DHCP';
  box.append(h,el('div','meta','Netzwerkteilnehmer ohne Routing (LAN + WAN Port) \u00b7 '+mode+(n.ip?' \u00b7 '+n.ip:'')+' \u00b7 DHCP-Server: '+(n.dhcp_server?'an':'aus')));
  const r=el('div','row');
  const b=el('button','sec',n.dhcp_server?'DHCP-Server ausschalten':'DHCP-Server einschalten');
  b.onclick=async()=>{
    const msg=n.dhcp_server?'DHCP-Server ausschalten? Der Router holt sich seine IP danach wieder per DHCP.'
      :'DHCP-Server einschalten? Nur sinnvoll, wenn im Netzwerk KEIN anderer DHCP-Server l\u00e4uft. Der Router beh\u00e4lt seine aktuelle IP als feste Adresse. Die Verbindung kann kurz abrei\u00dfen.';
    if(!confirm(msg))return;
    await fetch('/api/dhcp?mode='+(n.dhcp_server?'off':'on'),{method:'POST'});
    $('#err').textContent='Netzwerk wird neu gestartet, Seite l\u00e4dt gleich neu ...';
  };
  r.append(b);box.append(r);
}
async function load(){
  try{
    const d=await (await fetch('/api/status')).json();
    $('#err').textContent='';render(d);
    if(d.running||!$('#log').hidden)loadLog();
  }catch(e){$('#err').textContent='Keine Verbindung zum Netzwerk-Core';}
}
async function loadLog(){
  const d=await (await fetch('/api/log')).json();
  const p=$('#log');p.hidden=false;p.textContent=d.log||'';p.scrollTop=p.scrollHeight;
}
async function uninst(a){
  if(!confirm(a.name+' deinstallieren? Dienst und Autostart werden entfernt.'))return;
  const del=confirm('Auch alle Einstellungen und Daten von '+a.name+' l\u00f6schen?\n\nOK = alles l\u00f6schen\nAbbrechen = Daten behalten (bei erneuter Installation wieder vorhanden)');
  await fetch('/api/uninstall?id='+encodeURIComponent(a.id)+'&data='+(del?'delete':'keep'),{method:'POST'});
  $('#log').hidden=false;load();
}
async function help(id){
  const d=await (await fetch('/api/help?id='+encodeURIComponent(id))).json();
  const b=$('#mbox');b.replaceChildren(el('h2',null,d.title));
  if(d.creds&&d.creds.length){
    b.append(el('h4',null,'Zugangsdaten (aktuell)'));
    const c=el('div','cred');d.creds.forEach(x=>c.append(el('span',null,x[0]),el('span',null,x[1])));b.append(c);
  }
  b.append(el('h4',null,'Schritt f\u00fcr Schritt'));
  const ol=el('ol','steps');
  d.steps.forEach(s=>{const li=el('li');li.append(el('b',null,s.t),el('span',null,s.d));ol.append(li);});
  b.append(ol);
  if(d.tips&&d.tips.length){
    b.append(el('h4',null,'Probleme?'));
    const ul=el('ul','tips');d.tips.forEach(t=>ul.append(el('li',null,t)));b.append(ul);
  }
  const x=el('button','sec',openId?'Zur\u00fcck':'Schlie\u00dfen');x.style.marginTop='16px';
  x.onclick=()=>{if(openId){helpOpen=false;openSig='';renderSettings();}else closeModal();};
  b.append(x);helpOpen=true;$('#modal').hidden=false;
}
$('#modal').onclick=e=>{if(e.target.id==='modal')closeModal();};
async function upd(id){
  await fetch('/api/update?id='+encodeURIComponent(id),{method:'POST'});
  $('#log').hidden=false;load();
}
$('#all').onclick=()=>upd('all');
$('#self').onclick=async()=>{
  if(!confirm('Neue Version des Netzwerk-Core-Skripts von GitHub laden und installieren? Die Statusseite startet dabei kurz neu, Daten und Netzwerkeinstellungen bleiben erhalten.'))return;
  await fetch('/api/selfupdate',{method:'POST'});
  $('#log').hidden=false;load();
};
load();setInterval(load,4000);
</script></body></html>
"""


# ---------------------------------------------------------------------------
# Einstellungen/Daten sichern (ZIP-Download) und wiederherstellen (Upload)
# ---------------------------------------------------------------------------
BACKUP_DIR = os.path.join(BASE, "backup-data")
TMP_DIR = os.path.join(BASE, "tmp")
MAX_UPLOAD = 300 * 1024 * 1024
DATA_DIRS = ("data", "daten", "uploads", "print_history")
DATA_NAMES = ("config.json", "markers.json", "config.yaml")
SKIP_DIRS = {".pylibs", "node_modules", "__pycache__", ".git", "logs", "log", "cache", ".cache", "tmp"}
SKIP_NAMES = {"package-lock.json"}
# Dateien ausserhalb des Programmordners (eigene Installation der Anwendung)
EXTERN = {"klingel": ("/root/Klingel-Dashboard", ["config.ini"])}
CONF_NAMES = ("config.json", "markers.json", "config.ini")


def preserved(rel):
    parts = rel.split("/")
    if parts[-1] in DATA_NAMES:
        return True
    if rel.endswith((".db", ".sqlite", ".sqlite3", ".mbtiles")):
        return True
    return any(p in DATA_DIRS for p in parts[:-1])


def repo_files(app_id):
    return set(read(os.path.join(APPS_DIR, app_id, ".nc_files"), 10 ** 7).splitlines())


def data_ok(rel, repo):
    """Gehoert diese Datei (relativ zum Programmordner) zu den Einstellungen/Daten?"""
    if rel.startswith(".nc_") or rel.endswith((".pyc", ".log", ".tmp")):
        return False
    if os.path.basename(rel) in SKIP_NAMES or any(p in SKIP_DIRS for p in rel.split("/")[:-1]):
        return False
    return preserved(rel) or (bool(repo) and rel not in repo)


def collect(app_id):
    """Liste (Archivname, voller Pfad) aller Einstellungs-/Datendateien der Anwendung."""
    res = []
    ad = os.path.join(APPS_DIR, app_id)
    repo = repo_files(app_id)
    for root, dirs, files in os.walk(ad):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in sorted(files):
            full = os.path.join(root, f)
            rel = os.path.relpath(full, ad).replace(os.sep, "/")
            if data_ok(rel, repo) and os.path.isfile(full) and not os.path.islink(full):
                res.append(("app/" + rel, full))
    dd = os.path.join(BASE, "data", app_id)
    for root, dirs, files in os.walk(dd):
        for f in sorted(files):
            full = os.path.join(root, f)
            if os.path.isfile(full) and not os.path.islink(full):
                res.append(("data/" + os.path.relpath(full, dd).replace(os.sep, "/"), full))
    ex = EXTERN.get(app_id)
    if ex:
        for n in ex[1]:
            full = os.path.join(ex[0], n)
            if os.path.isfile(full):
                res.append(("extern/" + n, full))
    return res


def svc_for(app_id):
    out = []
    p = "/etc/init.d/nc-" + app_id
    if os.path.exists(p):
        out.append(p)
    elif app_id == "klingel":
        try:
            for n in sorted(os.listdir("/etc/init.d")):
                fp = os.path.join("/etc/init.d", n)
                if n.startswith("nc-") or not os.path.isfile(fp):
                    continue
                if re.search(r"klingel|doorbell", read(fp, 20000), re.I):
                    out.append(fp)
        except OSError:
            pass
    return out


def svc_ctl(app_id, action):
    for s in svc_for(app_id):
        try:
            subprocess.run([s, action], timeout=60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass


def build_zip(app_id):
    """ZIP mit allen Einstellungs-/Datendateien in eine Temp-Datei schreiben (geoeffnet, Position 0)."""
    import tempfile
    import zipfile
    os.makedirs(TMP_DIR, exist_ok=True)
    tf = tempfile.TemporaryFile(dir=TMP_DIR)
    entries = collect(app_id)
    with zipfile.ZipFile(tf, "w", zipfile.ZIP_DEFLATED) as z:
        manifest = dict(app=app_id, core=NC_VERSION, created=time.strftime("%Y-%m-%d %H:%M:%S"),
                        files=[a for a, _ in entries])
        z.writestr("nc-backup.json", json.dumps(manifest, indent=1, ensure_ascii=False))
        for arc, full in entries:
            try:
                z.write(full, arc)
            except OSError:
                pass
    tf.seek(0)
    return tf, len(entries)


def safety_backup(app_id):
    """Sicherung vor dem Ueberschreiben; behaelt die letzten 3 je Anwendung."""
    os.makedirs(BACKUP_DIR, exist_ok=True)
    tf, n = build_zip(app_id)
    if n:
        with open(os.path.join(BACKUP_DIR, "%s-%s.zip" % (app_id, time.strftime("%Y%m%d-%H%M%S"))), "wb") as f:
            while True:
                b = tf.read(1 << 20)
                if not b:
                    break
                f.write(b)
    tf.close()
    old = sorted(x for x in os.listdir(BACKUP_DIR) if x.startswith(app_id + "-") and x.endswith(".zip"))
    for x in old[:-3]:
        try:
            os.remove(os.path.join(BACKUP_DIR, x))
        except OSError:
            pass


def safe_join(root, rel):
    rel = rel.replace("\\", "/").lstrip("/")
    if not rel or any(p in ("..", "") for p in rel.split("/")) or ":" in rel.split("/")[0]:
        return None
    full = os.path.normpath(os.path.join(root, rel))
    return full if full.startswith(os.path.normpath(root) + os.sep) else None


def workdir_of(app_id):
    ad = os.path.join(APPS_DIR, app_id)
    wd = read(os.path.join(ad, ".nc_workdir"), 500)
    return wd if wd and os.path.isdir(wd) else ad


def restore_zip(app_id, tmp_path):
    import zipfile
    try:
        z = zipfile.ZipFile(tmp_path)
    except Exception:
        return 400, dict(error="Die Datei ist kein gültiges ZIP-Archiv.")
    with z:
        try:
            man = json.loads(z.read("nc-backup.json").decode("utf-8-sig"))
        except Exception:
            man = {}
        if man.get("app") and man["app"] != app_id:
            return 400, dict(error="Das ZIP gehört zu \"%s\", nicht zu \"%s\"." % (man["app"], app_id))
        ad = os.path.join(APPS_DIR, app_id)
        repo = repo_files(app_id)
        targets = []
        for info in z.infolist():
            name = info.filename
            if info.is_dir() or name == "nc-backup.json":
                continue
            if (info.external_attr >> 16) & 0o170000 == 0o120000:
                continue  # keine symbolischen Links
            if name.startswith("app/"):
                rel = name[4:]
                dest = safe_join(ad, rel)
                if dest is None or not data_ok(rel, repo):
                    continue
            elif name.startswith("data/"):
                dest = safe_join(os.path.join(BASE, "data", app_id), name[5:])
                if dest is None:
                    continue
            elif name.startswith("extern/") and app_id in EXTERN:
                n = name[7:]
                if n not in EXTERN[app_id][1]:
                    continue
                dest = safe_join(EXTERN[app_id][0], n)
                if dest is None:
                    continue
            else:
                continue
            targets.append((info, dest))
        if not targets:
            return 400, dict(error="Das ZIP enthält keine passenden Einstellungs-/Datendateien für diese Anwendung.")
        safety_backup(app_id)
        svc_ctl(app_id, "stop")
        try:
            for info, dest in targets:
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with z.open(info) as src, open(dest + ".nc_new", "wb") as out:
                    shutil.copyfileobj(src, out)
                os.replace(dest + ".nc_new", dest)
        except Exception as e:
            svc_ctl(app_id, "start")
            return 500, dict(error="Fehler beim Entpacken: %s" % e)
    os.sync()
    svc_ctl(app_id, "start")
    return 200, dict(msg="%d Datei(en) wiederhergestellt, Dienst neu gestartet." % len(targets))


def restore_file(app_id, tmp_path, name):
    name = os.path.basename(name or "")
    if not name:
        return 400, dict(error="Dateiname fehlt.")
    raw = open(tmp_path, "rb").read()
    if name.lower().endswith(".json"):
        try:
            json.loads(raw.decode("utf-8-sig"))
        except Exception:
            return 400, dict(error="Keine gültige JSON-Datei.")
    cands = [full for arc, full in collect(app_id) if os.path.basename(arc) == name]
    if len(cands) == 1:
        dest = cands[0]
    elif len(cands) > 1:
        return 400, dict(error="Der Dateiname \"%s\" ist mehrdeutig - bitte ein ZIP verwenden." % name)
    elif app_id in EXTERN and name in EXTERN[app_id][1]:
        dest = os.path.join(EXTERN[app_id][0], name)
    elif name in CONF_NAMES and os.path.exists(os.path.join(APPS_DIR, app_id, ".nc_ok")):
        dest = os.path.join(workdir_of(app_id), name)
    else:
        return 400, dict(error="Unbekannte Datei \"%s\". Bitte die Sicherung (ZIP) dieses Dienstes hochladen." % name)
    safety_backup(app_id)
    svc_ctl(app_id, "stop")
    try:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest + ".nc_new", "wb") as f:
            f.write(raw)
        os.replace(dest + ".nc_new", dest)
    except Exception as e:
        svc_ctl(app_id, "start")
        return 500, dict(error="Fehler beim Schreiben: %s" % e)
    os.sync()
    svc_ctl(app_id, "start")
    return 200, dict(msg="%s ersetzt, Dienst neu gestartet." % name)


def files_info(app_id):
    items = []
    for arc, full in collect(app_id):
        try:
            items.append(dict(path=arc.split("/", 1)[1] if arc.startswith(("app/", "data/", "extern/")) else arc,
                              size=os.path.getsize(full)))
        except OSError:
            pass
    backups = []
    if os.path.isdir(BACKUP_DIR):
        backups = sorted(x for x in os.listdir(BACKUP_DIR) if x.startswith(app_id + "-") and x.endswith(".zip"))[-3:]
    return dict(files=items[:60], total=len(items),
                size=sum(i["size"] for i in items), backups=backups)



class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _send_file(self, f, filename):
        f.seek(0, 2)
        size = f.tell()
        f.seek(0)
        self.send_response(200)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % filename)
        self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        shutil.copyfileobj(f, self.wfile, 1 << 16)

    def _app_id(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        aid = q.get("id", [""])[0]
        ok = aid in [a["id"] for a in load_apps()] and os.path.exists(os.path.join(APPS_DIR, aid, ".nc_ok"))
        return (aid if ok else None), q

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/files":
            aid, _ = self._app_id()
            if not aid:
                return self._send(404, json.dumps(dict(error="nicht installiert")))
            return self._send(200, json.dumps(files_info(aid)))
        if path == "/api/backup":
            aid, _ = self._app_id()
            if not aid:
                return self._send(404, json.dumps(dict(error="nicht installiert")))
            tf, n = build_zip(aid)
            try:
                return self._send_file(tf, "%s-daten-%s.zip" % (aid, time.strftime("%Y%m%d-%H%M")))
            finally:
                tf.close()
        if path == "/":
            self._send(200, INDEX, "text/html")
        elif path == "/api/status":
            self._send(200, json.dumps(dict(version=NC_VERSION, running=running(),
                                            net=net_status(), core=core_status(),
                                            apps=all_status())))
        elif path == "/api/help":
            hid = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("id", [""])[0]
            if hid != "homekit":
                return self._send(404, json.dumps(dict(error="keine Hilfe vorhanden")))
            host = (self.headers.get("Host") or "router").rsplit(":", 1)[0]
            self._send(200, json.dumps(help_homekit(host)))
        elif path == "/api/log":
            self._send(200, json.dumps(dict(running=running(), log=read(LOG)[-12000:])))
        else:
            self._send(404, json.dumps(dict(error="nicht gefunden")))

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/api/dhcp":
            mode = urllib.parse.parse_qs(u.query).get("mode", [""])[0]
            if mode not in ("on", "off"):
                return self._send(400, json.dumps(dict(error="mode=on|off")))
            subprocess.Popen(["/bin/sh", NET, "dhcp-" + mode], stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
            return self._send(200, json.dumps(dict(started=True)))
        if u.path == "/api/uninstall":
            q = urllib.parse.parse_qs(u.query)
            target = q.get("id", [""])[0]
            mode = "delete" if q.get("data", ["keep"])[0] == "delete" else "keep"
            if target not in [a["id"] for a in load_apps()]:
                return self._send(400, json.dumps(dict(error="unbekannte Anwendung")))
            ok = start_uninstall(target, mode)
            return self._send(200 if ok else 409, json.dumps(dict(started=ok)))
        if u.path == "/api/restore":
            global _restoring
            aid, q = self._app_id()
            length = int(self.headers.get("Content-Length") or 0)
            if not aid:
                self.close_connection = True
                return self._send(404, json.dumps(dict(error="Anwendung nicht installiert")))
            if length <= 0 or length > MAX_UPLOAD:
                self.close_connection = True
                return self._send(413, json.dumps(dict(error="Datei leer oder gr\u00f6\u00dfer als %d MB" % (MAX_UPLOAD >> 20))))
            with _lock:
                if running():
                    self.close_connection = True
                    return self._send(409, json.dumps(dict(error="Es l\u00e4uft gerade eine andere Aktion.")))
                _restoring = True
            tmp = os.path.join(TMP_DIR, "upload-%d.bin" % os.getpid())
            try:
                os.makedirs(TMP_DIR, exist_ok=True)
                left = length
                with open(tmp, "wb") as f:
                    while left > 0:
                        chunk = self.rfile.read(min(1 << 16, left))
                        if not chunk:
                            break
                        f.write(chunk)
                        left -= len(chunk)
                if left > 0:
                    return self._send(400, json.dumps(dict(error="Upload unvollst\u00e4ndig")))
                with open(tmp, "rb") as f:
                    is_zip = f.read(4) == b"PK\x03\x04"
                if is_zip:
                    code, res = restore_zip(aid, tmp)
                else:
                    code, res = restore_file(aid, tmp, q.get("name", [""])[0])
                return self._send(code, json.dumps(res))
            except Exception as e:
                return self._send(500, json.dumps(dict(error=str(e))))
            finally:
                _restoring = False
                try:
                    os.remove(tmp)
                except OSError:
                    pass
        if u.path == "/api/selfupdate":
            ok = start_selfupdate()
            return self._send(200 if ok else 409, json.dumps(dict(started=ok)))
        if u.path != "/api/update":
            return self._send(404, json.dumps(dict(error="nicht gefunden")))
        target = urllib.parse.parse_qs(u.query).get("id", ["all"])[0]
        ids = [a["id"] for a in load_apps()]
        if target != "all" and target not in ids:
            return self._send(400, json.dumps(dict(error="unbekannte Anwendung")))
        ok = start_update(target)
        self._send(200 if ok else 409, json.dumps(dict(started=ok)))


if __name__ == "__main__":
    threading.Thread(target=refresher, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
NC_CORE_EOF

# ---------------------------------------------------------------------------
# JavaScript-Ersatz fuer native Node-Module (der Router hat keinen C-Compiler).
# hap-nodejs (HomeKit2MQTT) braucht ed25519-hap und curve25519-n; beide werden
# hier mit tweetnacl nachgebildet (getestet gegen RFC 8032 / RFC 7748 und eine
# echte HomeKit-Kopplung mit hap-controller).
# ---------------------------------------------------------------------------
mkdir -p "$BASE/shims/ed25519-hap" "$BASE/shims/curve25519-n"
cat > "$BASE/shims/ed25519-hap/index.js" <<'NC_SHIM_ED_EOF'
'use strict';
// Reiner JavaScript-Ersatz fuer das native Modul "ed25519-hap" (Netzwerk-Core).
// Gleiche Schnittstelle: MakeKeypair(seed), Sign(msg, seed|privateKey|keyPair), Verify(msg, sig, pub)
// Der Router hat keinen C-Compiler, daher kommt tweetnacl (pures JS) zum Einsatz.
const nacl = require('tweetnacl');

const u8 = (b) => new Uint8Array(b.buffer, b.byteOffset, b.length);
const buf = (u) => Buffer.from(u.buffer, u.byteOffset, u.length);

function MakeKeypair(seed) {
    if (!Buffer.isBuffer(seed) || seed.length !== 32) {
        throw new Error('MakeKeypair requires a 32 byte buffer');
    }
    const kp = nacl.sign.keyPair.fromSeed(u8(seed));
    return {publicKey: buf(kp.publicKey), privateKey: buf(kp.secretKey)};
}

function Sign(message, key) {
    if (!Buffer.isBuffer(message) || key === undefined || key === null) {
        throw new Error('Sign requires (Buffer, {Buffer(32 or 64) | keyPair object})');
    }
    let secret;
    if (Buffer.isBuffer(key) && key.length === 32) {
        secret = nacl.sign.keyPair.fromSeed(u8(key)).secretKey;
    } else if (Buffer.isBuffer(key) && key.length === 64) {
        secret = u8(key);
    } else if (typeof key === 'object' && Buffer.isBuffer(key.privateKey)) {
        secret = key.privateKey.length === 32 ?
            nacl.sign.keyPair.fromSeed(u8(key.privateKey)).secretKey : u8(key.privateKey);
    } else {
        throw new Error('Sign requires (Buffer, {Buffer(32 or 64) | keyPair object})');
    }
    return buf(nacl.sign.detached(u8(message), secret));
}

function Verify(message, signature, publicKey) {
    if (!Buffer.isBuffer(message) || !Buffer.isBuffer(signature) || !Buffer.isBuffer(publicKey) ||
        signature.length !== 64 || publicKey.length !== 32) {
        throw new Error('Verify requires (Buffer, Buffer(64), Buffer(32)');
    }
    try {
        return nacl.sign.detached.verify(u8(message), u8(signature), u8(publicKey));
    } catch (err) {
        return false;
    }
}

module.exports = {MakeKeypair, Sign, Verify};
NC_SHIM_ED_EOF
cat > "$BASE/shims/ed25519-hap/package.json" <<'NC_SHIM_EDP_EOF'
{"name":"ed25519-hap","version":"0.0.5-js","main":"index.js","dependencies":{"tweetnacl":"1.0.3"}}
NC_SHIM_EDP_EOF
cat > "$BASE/shims/curve25519-n/index.js" <<'NC_SHIM_CV_EOF'
'use strict';
// Reiner JavaScript-Ersatz fuer das native Modul "curve25519-n" (Netzwerk-Core).
// X25519 ueber tweetnacl - gleiche Schnittstelle wie das Original.
const crypto = require('crypto');
const nacl = require('tweetnacl');

const u8 = (b) => new Uint8Array(b.buffer, b.byteOffset, b.length);
const buf = (u) => Buffer.from(u.buffer, u.byteOffset, u.length);

function makeSecretKey(mysecret) {
    if (!Buffer.isBuffer(mysecret)) { throw new Error('mysecret must be a Buffer'); }
    if (mysecret.length !== 32) { throw new Error('mysecret must be 32 bytes long'); }
    // hap-nodejs 0.4.x uebergibt einen LEEREN Puffer und nutzt ihn danach als geheimen
    // Schluessel (Rueckgabewert wird ignoriert). Deshalb: Puffer in-place befuellen,
    // falls er nur Nullen enthaelt, danach in-place klemmen und zurueckgeben.
    if (mysecret.every((x) => x === 0)) { crypto.randomFillSync(mysecret); }
    mysecret[0] &= 248;
    mysecret[31] &= 127;
    mysecret[31] |= 64;
    return mysecret;
}

function derivePublicKey(mysecret) {
    if (mysecret.length !== 32) { throw new Error('mysecret must be 32 bytes long'); }
    return buf(nacl.scalarMult.base(u8(mysecret)));
}

function deriveSharedSecret(mysecret, hispublic) {
    if (mysecret.length !== 32) { throw new Error('mysecret must be 32 bytes long'); }
    if (hispublic.length !== 32) { throw new Error('hispublic must be 32 bytes long'); }
    return buf(nacl.scalarMult(u8(mysecret), u8(hispublic)));
}

module.exports = {makeSecretKey, derivePublicKey, deriveSharedSecret};
NC_SHIM_CV_EOF
cat > "$BASE/shims/curve25519-n/package.json" <<'NC_SHIM_CVP_EOF'
{"name":"curve25519-n","version":"1.2.1-js","main":"index.js","dependencies":{"tweetnacl":"1.0.3"}}
NC_SHIM_CVP_EOF

# ---------------------------------------------------------------------------
# Netzwerk: Brume 2 als reiner Netzwerkteilnehmer (kein Routing)
#   nc-network.sh bridge                      LAN- und WAN-Port in eine Bridge, IP per DHCP
#   nc-network.sh dhcp-on [IP/CIDR] [GW] [DNS]  Router wird DHCP-Server (feste IP)
#   nc-network.sh dhcp-off                    zurueck zum DHCP-Client
#   nc-network.sh status | restore            Anzeige / Originalzustand wiederherstellen
# ---------------------------------------------------------------------------
cat > "$BASE/bin/nc-network.sh" <<'NC_NET_EOF'
#!/bin/sh
BASE=/root/Netzwerk-Core
BK="$BASE/backup"
log() { echo "[$(date '+%F %T')] $*"; }

find_bridge() {
    for s in $(uci show network 2>/dev/null | sed -n 's/^\(network\.[^.=]*\)=device$/\1/p'); do
        [ "$(uci -q get "$s.name")" = "br-lan" ] && { echo "$s"; return; }
    done
}
wan_dev() {
    d=$(uci -q get network.wan.device); [ -n "$d" ] || d=$(uci -q get network.wan.ifname)
    echo "$d"
}
jget() { jsonfilter -s "$1" -e "$2" 2>/dev/null; }

apply_delayed() {   # Netzwerk im Hintergrund neu starten (SSH-Sitzung kann dabei abreissen)
    uci commit network; uci commit dhcp
    ( sleep 3; /etc/init.d/network restart; sleep 8; /etc/init.d/dnsmasq restart; /etc/init.d/firewall reload ) >/dev/null 2>&1 &
}

set_alias() {   # feste Notfalladresse, falls im Netz kein DHCP-Server existiert
    fb=$(cat "$BK/fallback_ip" 2>/dev/null); [ -n "$fb" ] || fb=192.168.8.1
    uci set network.lanalias=interface
    uci set network.lanalias.proto=static
    uci set network.lanalias.device='@lan'
    uci set network.lanalias.ipaddr="$fb/24"
}

do_bridge() {
    mkdir -p "$BK"
    for f in network dhcp firewall; do [ -f "$BK/$f.orig" ] || cp "/etc/config/$f" "$BK/$f.orig"; done
    wd=$(wan_dev); br=$(find_bridge)
    [ -n "$wd" ] || { log "FEHLER: WAN-Port nicht gefunden - nichts geaendert"; return 1; }
    [ -n "$br" ] || { log "FEHLER: br-lan nicht gefunden - nichts geaendert"; return 1; }

    # Notfalladresse waehlen (nicht im Netz des Uplinks)
    wanip=$(jget "$(ubus call network.interface.wan status 2>/dev/null)" '@["ipv4-address"][0].address')
    fb=192.168.8.1; case "$wanip" in 192.168.8.*) fb=192.168.88.1 ;; esac
    echo "$fb" > "$BK/fallback_ip"

    log "WAN-Port ($wd) wird in die Bridge $br aufgenommen"
    uci -q del_list "$br.ports=$wd"; uci add_list "$br.ports=$wd"
    uci set "$br.stp=1"                    # Schutz gegen Schleifen, wenn beide Ports im selben Netz haengen
    uci -q delete network.wan; uci -q delete network.wan6
    uci set network.lan.proto=dhcp
    for o in ipaddr netmask gateway dns ip6assign ip6hint ip6addr; do uci -q delete "network.lan.$o"; done
    set_alias
    uci set dhcp.lan.ignore=1              # kein eigener DHCP-Server
    uci set dhcp.lan.dhcpv6=disabled; uci set dhcp.lan.ra=disabled
    uci -q delete dhcp.lan.dhcp_option
    apply_delayed
    log "Bridge-Modus aktiv. Der Router holt sich seine IP per DHCP (Hostname: $(uci -q get system.@system[0].hostname)). Notfalladresse: $fb"
}

do_dhcp_on() {
    j=$(ubus call network.interface.lan status 2>/dev/null)
    ip="$1"
    if [ -z "$ip" ]; then
        a=$(jget "$j" '@["ipv4-address"][0].address'); m=$(jget "$j" '@["ipv4-address"][0].mask')
        [ -n "$a" ] && ip="$a/$m"
    fi
    [ -n "$ip" ] || ip=$(uci -q get network.lanalias.ipaddr)
    [ -n "$ip" ] || ip=192.168.8.1/24
    case "$ip" in */*) ;; *) ip="$ip/24" ;; esac
    gw="$2"; [ -n "$gw" ] || gw=$(jget "$j" '@.route[@.target="0.0.0.0"].nexthop')
    dns="$3"; [ -n "$dns" ] || dns=$(jget "$j" '@["dns-server"][0]'); [ -n "$dns" ] || dns="$gw"

    log "DHCP-Server an: Router-IP $ip, Gateway ${gw:-keins}, DNS ${dns:-keins}"
    uci set network.lan.proto=static
    uci set network.lan.ipaddr="$ip"
    uci -q delete network.lan.gateway; uci -q delete network.lan.dns
    [ -n "$gw" ] && uci set network.lan.gateway="$gw"
    [ -n "$dns" ] && uci add_list network.lan.dns="$dns"
    uci -q delete network.lanalias
    uci set dhcp.lan.ignore=0
    uci set dhcp.lan.start="${NC_DHCP_START:-100}"; uci set dhcp.lan.limit="${NC_DHCP_LIMIT:-100}"
    uci -q delete dhcp.lan.dhcp_option
    [ -n "$gw" ] && uci add_list dhcp.lan.dhcp_option="3,$gw"
    [ -n "$dns" ] && uci add_list dhcp.lan.dhcp_option="6,$dns"
    apply_delayed
}

do_dhcp_off() {
    log "DHCP-Server aus, Router holt sich die IP wieder per DHCP"
    uci set network.lan.proto=dhcp
    for o in ipaddr netmask gateway dns; do uci -q delete "network.lan.$o"; done
    set_alias
    uci set dhcp.lan.ignore=1
    uci -q delete dhcp.lan.dhcp_option
    apply_delayed
}

do_restore() {
    [ -f "$BK/network.orig" ] || { log "Kein Backup vorhanden"; return 1; }
    for f in network dhcp firewall; do cp "$BK/$f.orig" "/etc/config/$f"; done
    ( sleep 3; /etc/init.d/network restart; /etc/init.d/dnsmasq restart; /etc/init.d/firewall reload ) >/dev/null 2>&1 &
    log "Originalkonfiguration (Router-Modus) wird wiederhergestellt"
}

do_status() {
    echo "Modus:        $(uci -q get network.lan.proto)"
    echo "DHCP-Server:  $([ "$(uci -q get dhcp.lan.ignore)" = 1 ] && echo aus || echo an)"
    echo "Bridge-Ports: $(uci -q get "$(find_bridge).ports")"
    echo "IP:           $(jget "$(ubus call network.interface.lan status 2>/dev/null)" '@["ipv4-address"][0].address')"
}

case "$1" in
    bridge)   do_bridge ;;
    dhcp-on)  shift; do_dhcp_on "$@" ;;
    dhcp-off) do_dhcp_off ;;
    restore)  do_restore ;;
    status)   do_status ;;
    *) echo "Aufruf: $0 bridge | dhcp-on [IP/CIDR] [GATEWAY] [DNS] | dhcp-off | status | restore"; exit 1 ;;
esac
NC_NET_EOF

# ---------------------------------------------------------------------------
# Haupt-Installation (laeuft jetzt und notfalls beim naechsten Start nochmal)
# ---------------------------------------------------------------------------
cat > "$BASE/bin/nc-install.sh" <<'NC_INSTALL_EOF'
#!/bin/sh
. /root/Netzwerk-Core/bin/nc-lib.sh
LOCK=/tmp/nc-install.lock
mkdir "$LOCK" 2>/dev/null || { echo "Installation laeuft bereits."; exit 0; }
trap 'rmdir "$LOCK"' EXIT

main() {
    log "Netzwerk-Core Installation gestartet"

    # 1) Internet abwarten (bis 15 Minuten)
    i=0
    until ping -c1 -W3 github.com >/dev/null 2>&1; do
        i=$((i+1)); [ $i -ge 90 ] && { log "Kein Internet - Installation wird beim naechsten Start fortgesetzt."; return 1; }
        [ $((i % 6)) -eq 1 ] && log "Warte auf Internet ..."
        sleep 10
    done

    # 2) Pakete
    n=0
    until opkg update; do
        n=$((n+1)); [ $n -ge 5 ] && { log "opkg update fehlgeschlagen"; return 1; }
        sleep 10
    done
    for p in nano curl ca-bundle ca-certificates python3 python3-pip python3-openssl; do
        opkg list-installed | grep -q "^$p " || opkg install "$p" || log "WARNUNG: Paket $p nicht installierbar"
    done
    if ! opkg list-installed | grep -q "^mosquitto"; then
        opkg install mosquitto-nossl mosquitto-client-nossl \
            || opkg install mosquitto-ssl mosquitto-client-ssl \
            || log "WARNUNG: mosquitto nicht installierbar"
    fi
    command -v python3 >/dev/null || { log "FEHLER: python3 fehlt"; return 1; }
    command -v curl >/dev/null || { log "FEHLER: curl fehlt"; return 1; }
    # aeltere pip-Versionen (OpenWrt 21.02) finden sonst keine fertigen Pakete
    python3 -m pip install --no-cache-dir --disable-pip-version-check --upgrade pip >/dev/null 2>&1 \
        || log "WARNUNG: pip-Update fehlgeschlagen"

    # 3) Zeitzone (Apps nutzen Router-Zeit)
    if [ "$(uci -q get system.@system[0].zonename)" = "UTC" ] || [ -z "$(uci -q get system.@system[0].zonename)" ]; then
        uci set system.@system[0].zonename='Europe/Berlin'
        uci set system.@system[0].timezone='CET-1CEST,M3.5.0,M10.5.0/3'
        uci commit system
        /etc/init.d/system reload 2>/dev/null
    fi

    # 4) Mosquitto
    mkdir -p /etc/mosquitto/data
    chown mosquitto:mosquitto /etc/mosquitto/data 2>/dev/null
    cat > /etc/mosquitto/mosquitto.conf <<MQ_EOF
listener 1883 0.0.0.0
allow_anonymous true
persistence true
persistence_location /etc/mosquitto/data/
autosave_interval 1800
log_dest syslog
MQ_EOF
    /etc/init.d/mosquitto enable
    /etc/init.d/mosquitto restart

    # 5) Anwendungen
    for id in $(active_ids); do deploy_app "$id" || log "Anwendung $id uebersprungen (siehe oben)"; done

    # 6) Statusseite (Init-Skript /etc/init.d/nc-core wird vom Hauptskript angelegt)
    /etc/init.d/nc-core enable
    /etc/init.d/nc-core restart

    touch "$BASE/.installed"
    sync
    /etc/init.d/nc-firstrun disable 2>/dev/null
    ip=$(uci -q get network.lan.ipaddr); [ -n "$ip" ] || ip=192.168.8.1
    log "FERTIG. Statusseite: http://$ip:8090/"

    # 7) Netzwerk zuletzt umstellen (Verbindung kann dabei kurz abreissen)
    if [ "${NC_SKIP_NETWORK:-0}" != "1" ] && [ ! -f "$BASE/.net_done" ]; then
        touch "$BASE/.net_done"
        log "Stelle Netzwerk auf Bridge-Modus um (LAN+WAN = Netzwerkteilnehmer, kein Routing) ..."
        /bin/sh "$BASE/bin/nc-network.sh" bridge
        log "Danach: IP des Routers (Hostname GL-MT2500) in der DHCP-Liste deines Hauptrouters nachsehen: http://<IP>:8090/"
    fi
}

{ main; } 2>&1 | tee -a "$BASE/install.log"
NC_INSTALL_EOF

chmod +x "$BASE"/bin/*.sh

# ---------------------------------------------------------------------------
# Autostart der Statusseite (auch im Update-Modus erneuert)
# ---------------------------------------------------------------------------
cat > /etc/init.d/nc-core <<CORE_EOF
#!/bin/sh /etc/rc.common
START=96
STOP=10
USE_PROCD=1
start_service() {
    # Selbstheilung: ist nc-core.py nach einem unsauberen Neustart abgeschnitten/leer,
    # wird es aus der gemerkten Skriptkopie neu erzeugt (einmal pro Systemstart)
    if ! grep -q '^if __name__' $BASE/bin/nc-core.py 2>/dev/null && [ -f $BASE/netzwerk-core-install.sh ] && [ ! -f /tmp/nc-heal-tried ]; then
        touch /tmp/nc-heal-tried
        ( sleep 5; NC_HEAL=1 NC_SELF_UPDATE=1 NC_SKIP_NETWORK=1 /bin/sh $BASE/netzwerk-core-install.sh >> $BASE/heal.log 2>&1; /etc/init.d/nc-core restart ) >/dev/null 2>&1 &
        return 0
    fi
    procd_open_instance
    procd_set_param command /usr/bin/python3 $BASE/bin/nc-core.py
    procd_set_param env NC_PORT=8090 NC_BASE=$BASE
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
CORE_EOF
chmod +x /etc/init.d/nc-core
sync


# ---------------------------------------------------------------------------
# Update-Modus: nur Hilfsskripte/Statusseite erneuern, neue Apps nachinstallieren
# (Netzwerk, Mosquitto-Konfiguration und App-Daten bleiben unberuehrt)
# ---------------------------------------------------------------------------
if [ "$SELF_UPDATE" = "1" ]; then
    . "$BASE/bin/nc-lib.sh"
    log "Update-Modus: Hilfsskripte und Statusseite erneuert"
    for id in $([ "$NC_HEAL" = "1" ] || active_ids); do
        if [ ! -f "$BASE/apps/$id/.nc_ok" ]; then
            log "Neue Anwendung: $id"
            deploy_app "$id" || log "Anwendung $id uebersprungen (siehe oben)"
        fi
    done
    # Fehlende Python-Module (webbrowser) ersetzen; bestehende Startskripte anpassen
    ensure_pyshims
    for rs in "$BASE"/run/*.sh; do
        [ -f "$rs" ] || continue
        grep -q 'pyshims' "$rs" && continue
        if grep -q 'PYTHONPATH=' "$rs"; then
            sed -i "s#PYTHONPATH=\"\([^\"]*\)\"#PYTHONPATH=\"\1:$BASE/pyshims\"#" "$rs"
            rid=$(basename "$rs" .sh)
            netstat -lnt 2>/dev/null | grep -q ":$(app_field "$rid" 4) " || { log "Starte $rid neu (Python-Ersatzmodule)"; /etc/init.d/nc-$rid restart >/dev/null 2>&1; }
        fi
    done
    # Anwendungen mit Port in der Konfigurationsdatei: Port setzen (8080 kollidiert mit der Router-Oberflaeche)
    for pid_ in $PORT_CFG_IDS; do
        [ -f "$BASE/apps/$pid_/.nc_ok" ] || continue
        wd=$(cat "$BASE/apps/$pid_/.nc_workdir" 2>/dev/null); [ -n "$wd" ] || wd="$BASE/apps/$pid_"
        if [ "$(set_app_port "$pid_" "$wd" "$(app_field "$pid_" 4)")" = "changed" ]; then
            log "$pid_: Port auf $(app_field "$pid_" 4) umgestellt"
            /etc/init.d/nc-$pid_ restart >/dev/null 2>&1
        fi
    done
    /etc/init.d/nc-core enable 2>/dev/null
    sync
    exit 0
fi

# ---------------------------------------------------------------------------
# Selbstinstallation beim Start, solange nicht abgeschlossen
# ---------------------------------------------------------------------------
cat > /etc/init.d/nc-firstrun <<'NC_FIRST_EOF'
#!/bin/sh /etc/rc.common
START=99
start() {
    [ -f /root/Netzwerk-Core/.installed ] || ( /bin/sh /root/Netzwerk-Core/bin/nc-install.sh >/dev/null 2>&1 & )
}
NC_FIRST_EOF
chmod +x /etc/init.d/nc-firstrun
/etc/init.d/nc-firstrun enable

echo "Starte Installation (Log: $BASE/install.log) ..."
exec /bin/sh "$BASE/bin/nc-install.sh"
