#!/bin/sh
# ============================================================================
#  Netzwerk-Core Installer fuer GL.iNet Brume 2 (GL-MT2500 / OpenWrt)
#
#  Einmal per SSH ausfuehren:   sh netzwerk-core-install.sh
#
#  Stellt den Router zuletzt auf "Netzwerkteilnehmer ohne Routing" um (LAN- und
#  WAN-Port in einer Bridge, IP per DHCP, DHCP-Server aus; per Statusseite oder
#  "sh /root/Netzwerk-Core/bin/nc-network.sh dhcp-on" wieder einschaltbar).
#  Mit  NC_SKIP_NETWORK=1 sh netzwerk-core-install.sh  wird die Umstellung ausgelassen.
#
#  Installiert: nano, mosquitto, 7 Anwendungen aus GitHub (Scorch1262),
#  je Anwendung einen Autostart (procd) und die Statusseite "Netzwerk-Core"
#  (Port 8090) mit Kacheln und Update-Buttons.
#  Schlaegt etwas wegen fehlendem Internet fehl, laeuft die Installation beim
#  naechsten Routerstart automatisch weiter (nc-firstrun).
# ============================================================================
BASE=/root/Netzwerk-Core

[ "$(id -u)" = "0" ] || { echo "Bitte als root ausfuehren."; exit 1; }
mkdir -p "$BASE/bin" "$BASE/apps" "$BASE/run"

# ---------------------------------------------------------------------------
# App-Liste:  id|Name|Repo|Port|Startdatei|Unterordner|Umgebung|Beschreibung
# ---------------------------------------------------------------------------
cat > "$BASE/apps.conf" <<'NC_APPS_EOF'
# id|Name|GitHub-Repo|Port|Startdatei (auto = automatisch)|Unterordner|Umgebungsvariablen|Beschreibung
flow|MQTT Flow-Planer|MQTT-Flow-Planer-MK1|8020|app.py|||MQTT-Ablaeufe als Blockschaltbild entwerfen
dashboard|MQTT-Dashboard|MQTT-Dashboard-MK3|5001|auto|Programme (py)||Graphen, Status-Anzeigen, Schalter und Slider
makro|MQTT Makro-Zentrale|MQTT-Makro-Zentrale-MK1|8010|app.py|||MQTT-Makro-Ketten verwalten und ausfuehren
diagram|MQTT-Diagram|MQTT-Diagram-MK1|5000|main.py||DASHBOARD_HOST=0.0.0.0 DASHBOARD_PORT=5000 DASHBOARD_OPEN_BROWSER=0|Live-Mindmap aller MQTT-Topics
netzwerkplan|Netzwerkplaner|Netzwerkplaner-MK1|8080|app.py|||Netzwerkplanung und Dokumentation
bambu|Drucker-Dashboard|BambuLab-MQTT-Dashboard-MK6|8000|app.py|||Bambu Lab / Ultimaker / OctoPrint / Formlabs
outfit|Wetter-Outfit|Wetter-Outfit-Dashboard-MK1|8095|app.py|||Outfit-Vorschlaege nach Wetter und Aktivitaet
NC_APPS_EOF

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

remote_sha() {
    for br in main master; do
        s=$(gh_curl -H "Accept: application/vnd.github.sha" \
            "https://api.github.com/repos/$OWNER/$1/commits/$br" 2>/dev/null | head -c 40)
        case "$s" in
            [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) echo "$s"; return 0 ;;
        esac
    done
    return 1
}

fetch_repo() {   # repo tmpdir
    for br in main master; do
        if gh_curl -o "$2/src.tgz" "https://codeload.github.com/$OWNER/$1/tar.gz/refs/heads/$br"; then
            mkdir -p "$2/x" && tar -xzf "$2/src.tgz" -C "$2/x" && return 0
        fi
    done
    return 1
}

# Dateien, die beim Update NICHT ueberschrieben werden (Nutzerdaten)
is_preserved() {
    case "$1" in
        config.json|*/config.json|markers.json|*/markers.json) return 0 ;;
        *.db|*.sqlite|*.sqlite3) return 0 ;;
        data/*|*/data/*|daten/*|*/daten/*|uploads/*|*/uploads/*) return 0 ;;
        print_history/*|*/print_history/*) return 0 ;;
    esac
    return 1
}

# Dateien, die auf dem Router nicht gebraucht werden (Windows/Mac-Builds)
is_skipped() {
    case "$1" in
        .github/*|Release/*|"Programme (exe)"/*|packaging/*|*/Entwürfe/*|*/build/*) return 0 ;;
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

# Anwendung installieren bzw. aktualisieren
deploy_app() {   # id
    id="$1"
    name=$(app_field "$id" 2); repo=$(app_field "$id" 3); port=$(app_field "$id" 4)
    entry=$(app_field "$id" 5); subdir=$(app_field "$id" 6); envs=$(app_field "$id" 7)
    [ -n "$repo" ] || { log "Unbekannte Anwendung: $id"; return 1; }
    appdir="$BASE/apps/$id"
    log "=== $name ($repo) ==="

    tmp=$(mktemp -d /tmp/nc.XXXXXX)
    sha=$(remote_sha "$repo")
    if ! fetch_repo "$repo" "$tmp"; then
        log "FEHLER: Repo $OWNER/$repo nicht ladbar (privat oder Name falsch?). Bei privaten Repos Token in $BASE/github_token ablegen."
        rm -rf "$tmp"; return 1
    fi
    src=$(ls -d "$tmp"/x/*/ 2>/dev/null | head -n1); src=${src%/}
    [ -d "$src" ] || { log "FEHLER: Archiv leer"; rm -rf "$tmp"; return 1; }

    mkdir -p "$appdir"
    (cd "$src" && find . -type f) | while read -r f; do
        f=${f#./}
        is_skipped "$f" && continue
        dest="$appdir/$f"
        if [ -e "$dest" ] && is_preserved "$f"; then continue; fi
        mkdir -p "$(dirname "$dest")"
        cp -f "$src/$f" "$dest"
    done

    workdir="$appdir"; [ -n "$subdir" ] && workdir="$appdir/$subdir"
    workdir=$(pick_workdir "$workdir")
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

    # Python-Abhaengigkeiten je Anwendung isoliert in .pylibs
    reqsrc="$workdir/requirements.txt"; [ -f "$reqsrc" ] || reqsrc="$appdir/requirements.txt"
    if [ -f "$reqsrc" ]; then
        grep -v -i -E '^[[:space:]]*(pyinstaller|#|$)' "$reqsrc" > "$tmp/req.txt"
    elif [ -f "$workdir/Python.txt" ]; then
        # Zeilen wie "py -3.11 -m pip install flask==3.0" -> "flask==3.0"
        tr -d '\r' < "$workdir/Python.txt" | sed -n 's/.*pip install //p' | grep -v -i pyinstaller > "$tmp/req.txt"
    else
        printf 'flask\npaho-mqtt\n' > "$tmp/req.txt"
    fi
    sum=$(md5sum "$tmp/req.txt" | cut -d' ' -f1)
    if [ "$sum" != "$(cat "$appdir/.nc_req" 2>/dev/null)" ] || [ ! -d "$appdir/.pylibs" ]; then
        log "Installiere Python-Pakete ..."
        if python3 -m pip install --no-cache-dir --disable-pip-version-check --upgrade \
              --target "$appdir/.pylibs" -r "$tmp/req.txt"; then
            echo "$sum" > "$appdir/.nc_req"
        else
            log "FEHLER: pip-Installation fehlgeschlagen"; rm -rf "$tmp"; return 1
        fi
    fi

    # Startskript + Autostart (procd)
    cat > "$BASE/run/$id.sh" <<RUN_EOF
#!/bin/sh
cd "$workdir" || exit 1
[ -r /etc/TZ ] && export TZ="\$(cat /etc/TZ)"
export PYTHONPATH="$appdir/.pylibs" PYTHONUNBUFFERED=1
exec env $envs /usr/bin/python3 "$entry"
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
    for id in $(app_ids); do deploy_app "$id"; done
else
    deploy_app "$target"
fi
log "Update beendet."
NC_UPDATE_EOF

# ---------------------------------------------------------------------------
# Statusseite "Netzwerk-Core" (nur Python-Standardbibliothek)
# ---------------------------------------------------------------------------
cat > "$BASE/bin/nc-core.py" <<'NC_CORE_EOF'
#!/usr/bin/env python3
"""Netzwerk-Core - Statusseite mit Kacheln und Update-Button."""
import json, os, re, socket, subprocess, threading, time, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NC_VERSION = "1.0.0"
BASE = os.environ.get("NC_BASE", "/root/Netzwerk-Core")
PORT = int(os.environ.get("NC_PORT", "8090"))
OWNER = "Scorch1262"
CONF = os.path.join(BASE, "apps.conf")
APPS_DIR = os.path.join(BASE, "apps")
LOG = os.path.join(BASE, "update.log")
UPDATE = os.path.join(BASE, "bin", "nc-update.sh")

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


def app_version(wd):
    for n in ("VERSION", "version.txt"):
        v = read(os.path.join(wd, n), 50)
        if v and len(v) < 30:
            return v
    try:
        files = sorted(f for f in os.listdir(wd) if f.endswith(".py"))
    except OSError:
        return ""
    for f in files:
        m = re.search(r'APP_VERSION\s*=\s*["\']([^"\']+)', read(os.path.join(wd, f)))
        if m:
            return m.group(1)
    return ""


def app_status(a):
    d = os.path.join(APPS_DIR, a["id"])
    installed = os.path.exists(os.path.join(d, ".nc_ok"))
    wd = read(os.path.join(d, ".nc_workdir"), 500) or (os.path.join(d, a["subdir"]) if a["subdir"] else d)
    local = read(os.path.join(d, ".nc_sha"), 60)
    remote = REMOTE.get(a["repo"], "")
    return dict(id=a["id"], name=a["name"], desc=a["desc"], port=a["port"],
                web=True, manage=True, installed=installed,
                up=port_up(a["port"]),
                version=app_version(wd) if installed else "",
                update=bool(installed and local and remote and local != remote))


def all_status():
    apps = [app_status(a) for a in load_apps()]
    apps.append(dict(id="mosquitto", name="Mosquitto Broker",
                     desc="MQTT-Broker dieses Routers", port=1883, web=False,
                     manage=False, installed=True, up=port_up(1883),
                     version="", update=False))
    return apps


NET = os.path.join(BASE, "bin", "nc-network.sh")


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
                "https://api.github.com/repos/%s/%s/commits/%s" % (OWNER, repo, br), headers=hdr)
            with urllib.request.urlopen(req, timeout=10) as r:
                s = r.read().decode().strip()
            if re.fullmatch(r"[0-9a-f]{40}", s):
                return s
        except Exception:
            continue
    return ""


def refresher():
    while True:
        for a in load_apps():
            s = fetch_sha(a["repo"])
            if s:
                REMOTE[a["repo"]] = s
        time.sleep(1800)


def running():
    return _proc is not None and _proc.poll() is None


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
</style></head><body>
<header>
 <div><h1>Netzwerk-Core</h1><div class="sub" id="info"></div></div>
 <div><button id="all" class="sec">Alle aktualisieren</button></div>
</header>
<main>
 <div id="err"></div>
 <div class="tile" id="net" style="margin-bottom:14px" hidden></div>
 <div class="grid" id="grid"></div>
 <pre id="log" hidden></pre>
</main>
<script>
const $=s=>document.querySelector(s);
let busy=false;
function el(t,c,x){const e=document.createElement(t);if(c)e.className=c;if(x!==undefined)e.textContent=x;return e;}
function render(d){
  $('#info').textContent='Version '+d.version+' \u00b7 '+location.hostname;
  busy=d.running;
  renderNet(d.net);
  const g=$('#grid');g.replaceChildren();
  d.apps.forEach(a=>{
    const t=el('div','tile'),h=el('div','head');
    h.append(el('span','dot '+(a.up?'up':'down')),el('h3',null,a.name));
    t.append(h,el('p','desc',a.desc));
    const m=el('div','meta');
    let txt='Port '+a.port+' \u00b7 '+(a.up?'l\u00e4uft':(a.installed?'gestoppt':'nicht installiert'));
    if(a.version)txt+=' \u00b7 v'+a.version;
    m.append(txt);
    if(a.update){m.append(' ');m.append(el('span','badge','Update verf\u00fcgbar'));}
    t.append(m);
    const r=el('div','row');
    if(a.web){
      const l=el('a','btn'+(a.up?'':' off'),'\u00d6ffnen');
      l.href='http://'+location.hostname+':'+a.port+'/';l.target='_blank';r.append(l);
    }
    if(a.manage){
      const b=el('button','sec',a.installed?'Update':'Installieren');
      b.disabled=busy;b.onclick=()=>upd(a.id);r.append(b);
    }
    t.append(r);g.append(t);
  });
  $('#all').disabled=busy;
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
async function upd(id){
  await fetch('/api/update?id='+encodeURIComponent(id),{method:'POST'});
  $('#log').hidden=false;load();
}
$('#all').onclick=()=>upd('all');
load();setInterval(load,4000);
</script></body></html>
"""


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

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/":
            self._send(200, INDEX, "text/html")
        elif path == "/api/status":
            self._send(200, json.dumps(dict(version=NC_VERSION, running=running(),
                                            net=net_status(), apps=all_status())))
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
    for id in $(app_ids); do deploy_app "$id" || log "Anwendung $id uebersprungen (siehe oben)"; done

    # 6) Statusseite
    cat > /etc/init.d/nc-core <<CORE_EOF
#!/bin/sh /etc/rc.common
START=96
STOP=10
USE_PROCD=1
start_service() {
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
    /etc/init.d/nc-core enable
    /etc/init.d/nc-core restart

    touch "$BASE/.installed"
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
