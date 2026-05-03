
#!/bin/bash
# =================================================================
# ZIVPN UDP Panel - Complete Installer (CLI + Web Panel)
# Author: @ARDVAK (Telegram)
# Version: 4.0 - All-in-One
# GitHub: github.com/autobot-sys/ziudp
# =================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

clear
echo -e "${CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║              🛡️  ZIVPN UDP PANEL - COMPLETE INSTALLER  🛡️              ║"
echo "║                    CLI + Web Panel + User Management                  ║"
echo "╠══════════════════════════════════════════════════════════════════════╣"
echo -e "║  👤 Author     : @ARDVAK (Telegram)                                ║"
echo -e "║  📦 GitHub     : github.com/autobot-sys/ziudp                      ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Check root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ This script must be run as root!${NC}" 
   exit 1
fi

# --- Update system & install dependencies ---
echo -e "${YELLOW}[1/8] Updating system and installing dependencies...${NC}"
apt update -y && apt upgrade -y
apt install -y \
    sqlite3 python3 python3-pip python3-flask python3-psutil \
    curl wget net-tools ntp ntpdate dos2unix speedtest-cli jq ufw

pip3 install --upgrade pip flask-cors

# --- Fix hostname warning ---
echo -e "${YELLOW}[2/8] Configuring system hostname...${NC}"
if ! grep -q "zivpn" /etc/hosts; then
    echo "127.0.0.1 zivpn" >> /etc/hosts
fi
hostname zivpn

# --- Sync time ---
echo -e "${YELLOW}[3/8] Syncing system time...${NC}"
ntpdate pool.ntp.org || true
systemctl enable ntp && systemctl start ntp

# --- Create directories ---
echo -e "${YELLOW}[4/8] Creating directories...${NC}"
mkdir -p /opt/zivpn/{logs,pids,backups,webpanel/templates}
mkdir -p /root/zivpn-cli

# --- Create CLI dashboard (ziudp.sh) ---
echo -e "${YELLOW}[5/8] Installing CLI dashboard...${NC}"
cat > /root/ziudp.sh << 'EOFCLI'
#!/bin/bash
# =================================================================
# ZIVPN UDP Panel - User Management Dashboard (CLI)
# Version: 3.2
# =================================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
INSTALL_DIR="/opt/zivpn"; DB_FILE="$INSTALL_DIR/users.db"; CONFIG_FILE="$INSTALL_DIR/config.json"
LOG_DIR="$INSTALL_DIR/logs"; AUTH_LOG="$LOG_DIR/auth.log"; PROXY_LOG="$LOG_DIR/proxy.log"
PID_DIR="$INSTALL_DIR/pids"; AUTH_PID="$PID_DIR/auth.pid"
mkdir -p "$INSTALL_DIR" "$LOG_DIR" "$PID_DIR"

DEFAULT_LISTEN_PORT=7300; DEFAULT_BACKEND_HOST="127.0.0.1"; DEFAULT_BACKEND_PORT=5400; DEFAULT_MAX_SESSIONS=3

init_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" <<EOF
{
  "listen_port": $DEFAULT_LISTEN_PORT,
  "backend_host": "$DEFAULT_BACKEND_HOST",
  "backend_port": $DEFAULT_BACKEND_PORT,
  "max_sessions_per_user": $DEFAULT_MAX_SESSIONS,
  "version": "3.2"
}
EOF
    fi
}
read_config() { python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('$1', ''))" 2>/dev/null; }
write_config() { python3 -c "import json; d=json.load(open('$CONFIG_FILE')); d['$1']=$2; json.dump(d,open('$CONFIG_FILE','w'),indent=2)" 2>/dev/null; }
load_settings() { LISTEN_PORT=$(read_config "listen_port" || echo "$DEFAULT_LISTEN_PORT"); BACKEND_HOST=$(read_config "backend_host" || echo "$DEFAULT_BACKEND_HOST"); BACKEND_PORT=$(read_config "backend_port" || echo "$DEFAULT_BACKEND_PORT"); MAX_SESSIONS_PER_USER=$(read_config "max_sessions_per_user" || echo "$DEFAULT_MAX_SESSIONS"); }
init_database() { sqlite3 "$DB_FILE" "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL, password TEXT NOT NULL, expiry INTEGER NOT NULL, data_limit INTEGER NOT NULL, data_used INTEGER DEFAULT 0, device_id TEXT, is_active INTEGER DEFAULT 1, created_at INTEGER DEFAULT (strftime('%s','now')), session_count INTEGER DEFAULT 0, last_seen INTEGER DEFAULT 0); CREATE INDEX IF NOT EXISTS idx_username ON users(username);"; }
log() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$AUTH_LOG"; }
get_server_ip() { curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 icanhazip.com 2>/dev/null || echo "unknown"; }
get_geo_info() { curl -s "https://ipapi.co/json/" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d.get('city','Unknown')}, {d.get('country_name','Unknown')}\")" 2>/dev/null || echo "Geo unavailable"; }
show_header() { clear; server_ip=$(get_server_ip); geo=$(get_geo_info); datetime=$(date "+%A, %d %B %Y  %H:%M:%S"); echo -e "${CYAN}${BOLD}"; echo "╔══════════════════════════════════════════════════════════════════════╗"; echo "║                     🛡️  NOOBS UDP PANEL  v3.2  🛡️                      ║"; echo "║                         User Management Dashboard                     ║"; echo "╠══════════════════════════════════════════════════════════════════════╣"; echo -e "║  🌍 Server IP : $server_ip                                          ║"; echo -e "║  📍 Location  : $geo                                                ║"; echo -e "║  🕒 System Time: $datetime                                         ║"; echo -e "║  👤 Author     : @ARDVAK (Telegram)                                ║"; echo "╚══════════════════════════════════════════════════════════════════════╝"; echo -e "${NC}"; }

create_python_proxy() { cat > "$INSTALL_DIR/udp_auth_proxy.py" <<'EOFPY'
#!/usr/bin/env python3
import socket, threading, sqlite3, time, json, sys
from datetime import datetime
CONFIG_PATH = "/opt/zivpn/config.json"; DB_PATH = "/opt/zivpn/users.db"; LOG_FILE = "/opt/zivpn/logs/auth.log"
def load_config(): return json.load(open(CONFIG_PATH))
def log(msg): timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S"); open(LOG_FILE, "a").write(f"{timestamp} - {msg}\n"); print(f"{timestamp} - {msg}")
def check_user(username, password, device_id, client_ip):
    conn = sqlite3.connect(DB_PATH); c = conn.cursor(); now = int(time.time())
    c.execute("SELECT expiry, data_limit, data_used, device_id, session_count FROM users WHERE username=? AND password=? AND is_active=1", (username, password)); row = c.fetchone()
    if not row: conn.close(); return False, "Invalid credentials"
    expiry, limit, used, bound_device, sessions = row; config = load_config(); max_sessions = config.get("max_sessions_per_user", 3)
    if now > expiry: conn.close(); return False, "Account expired"
    if limit > 0 and used >= limit: conn.close(); return False, "Data quota exhausted"
    if bound_device and bound_device != device_id: conn.close(); return False, "Device not bound"
    if sessions >= max_sessions: conn.close(); return False, "Session limit reached"
    c.execute("UPDATE users SET session_count = session_count+1, last_seen = ? WHERE username=?", (now, username)); conn.commit(); conn.close(); return True, "OK"
def update_usage(username, bytes_sent):
    conn = sqlite3.connect(DB_PATH); c = conn.cursor()
    c.execute("UPDATE users SET data_used = data_used + ? WHERE username=?", (bytes_sent, username)); conn.commit(); conn.close()
class AuthProxy:
    def __init__(self): config = load_config(); self.listen_port = config["listen_port"]; self.backend_host = config["backend_host"]; self.backend_port = config["backend_port"]; self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); self.sock.bind(("0.0.0.0", self.listen_port)); self.backend = (self.backend_host, self.backend_port); self.clients = {}; log(f"Proxy listening on {self.listen_port}, forwarding to {self.backend_host}:{self.backend_port}")
    def run(self):
        while True:
            data, client_addr = self.sock.recvfrom(65535); threading.Thread(target=self.handle_packet, args=(data, client_addr), daemon=True).start()
    def handle_packet(self, data, client_addr):
        if client_addr not in self.clients:
            try: msg = data.decode().strip()
            except: self.sock.sendto(b"FAIL:Invalid auth", client_addr); return
            if msg.startswith("USER:"):
                parts = msg.split(); user_part = parts[0][5:]; pass_part = parts[1][5:] if len(parts)>1 else ""; dev_part = ""
                for p in parts:
                    if p.startswith("DEVICE:"): dev_part = p[7:]
                ok, reason = check_user(user_part, pass_part, dev_part, client_addr[0])
                if ok: self.clients[client_addr] = (self.backend, user_part); self.sock.sendto(b"OK", client_addr); log(f"AUTH OK: {user_part} from {client_addr[0]}:{client_addr[1]}")
                else: self.sock.sendto(f"FAIL:{reason}".encode(), client_addr); log(f"AUTH FAIL: {user_part} from {client_addr[0]}:{client_addr[1]} - {reason}")
                return
            else: self.sock.sendto(b"FAIL:Send USER:PASS first", client_addr); return
        backend_addr, username = self.clients[client_addr]; self.sock.sendto(data, backend_addr); update_usage(username, len(data))
if __name__ == "__main__": proxy = AuthProxy(); proxy.run()
EOFPY
    chmod +x "$INSTALL_DIR/udp_auth_proxy.py"
}
start_zivpn() { if pgrep -f "udp_auth_proxy.py" > /dev/null; then echo -e "${YELLOW}⚠️  Already running${NC}"; return; fi; pkill -f "udp_auth_proxy.py" 2>/dev/null || true; python3 "$INSTALL_DIR/udp_auth_proxy.py" > "$PROXY_LOG" 2>&1 & echo $! > "$AUTH_PID"; sleep 2; if pgrep -f "udp_auth_proxy.py" > /dev/null; then echo -e "${GREEN}✅ ZIVPN started on port $(read_config listen_port)${NC}"; log "Service started"; else echo -e "${RED}❌ Failed to start${NC}"; fi; }
stop_zivpn() { if pgrep -f "udp_auth_proxy.py" > /dev/null; then pkill -f "udp_auth_proxy.py"; rm -f "$AUTH_PID"; echo -e "${GREEN}🛑 Stopped${NC}"; log "Service stopped"; else echo -e "${YELLOW}⚠️ Not running${NC}"; fi; }
restart_zivpn() { stop_zivpn; sleep 2; start_zivpn; }
status_zivpn() { if pgrep -f "udp_auth_proxy.py" > /dev/null; then echo -e "${GREEN}● RUNNING${NC}"; echo "Port: $(read_config listen_port) | Backend: $(read_config backend_host):$(read_config backend_port)"; else echo -e "${RED}● STOPPED${NC}"; fi; }
add_user() { read -p "Username: " username; read -sp "Password: " password; echo; read -p "Days: " days; read -p "Quota (e.g. 1GB): " quota_raw; quota_bytes=$(echo "$quota_raw" | awk '/[0-9]+GB$/ {print $1*1024*1024*1024} /[0-9]+MB$/ {print $1*1024*1024} /[0-9]+$/ {print $1}'); if [[ -z "$quota_bytes" ]]; then echo -e "${RED}Invalid quota${NC}"; return; fi; expiry=$(date -d "+$days days" +%s); read -p "Device ID (optional): " device_id; sqlite3 "$DB_FILE" "INSERT INTO users (username, password, expiry, data_limit, device_id) VALUES ('$username', '$password', $expiry, $quota_bytes, '$device_id');"; echo -e "${GREEN}✅ User $username added${NC}"; log "User added: $username"; }
delete_user() { read -p "Username: " username; sqlite3 "$DB_FILE" "DELETE FROM users WHERE username='$username';"; echo -e "${GREEN}✅ Deleted${NC}"; }
list_users() { sqlite3 -table "$DB_FILE" "SELECT username, datetime(expiry,'unixepoch') as expiry, printf('%.2f MB / %.2f MB', data_used/1024.0/1024.0, data_limit/1024.0/1024.0) as quota, coalesce(device_id,'-') as device FROM users;"; }
extend_user() { read -p "Username: " username; read -p "Extra days: " days; sqlite3 "$DB_FILE" "UPDATE users SET expiry = expiry + ($days*86400) WHERE username='$username';"; echo -e "${GREEN}✅ Extended${NC}"; }
reset_bandwidth() { read -p "Username: " username; sqlite3 "$DB_FILE" "UPDATE users SET data_used=0 WHERE username='$username';"; echo -e "${GREEN}✅ Reset${NC}"; }
test_user() { read -p "Minutes (1-60): " minutes; test_user="test_$(date +%s)"; test_pass=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8); expiry=$(date -d "+$minutes minutes" +%s); sqlite3 "$DB_FILE" "INSERT INTO users (username, password, expiry, data_limit) VALUES ('$test_user', '$test_pass', $expiry, 104857600);"; echo -e "${GREEN}🧪 Test user: $test_user / $test_pass (expires in $minutes min)${NC}"; }
cleanup_expired() { now=$(date +%s); deleted=$(sqlite3 "$DB_FILE" "DELETE FROM users WHERE expiry < $now; SELECT changes();"); echo -e "${GREEN}✅ Cleaned up $deleted expired users${NC}"; }
backup_data() { backup_file="/opt/zivpn/backups/backup_$(date +%Y%m%d_%H%M%S).tar.gz"; tar czf "$backup_file" -C /opt/zivpn users.db config.json; echo -e "${GREEN}💾 Backup: $backup_file${NC}"; }
restore_backup() { read -p "Backup file path: " backup_file; if [[ -f "$backup_file" ]]; then stop_zivpn; tar xzf "$backup_file" -C /opt/zivpn; echo -e "${GREEN}✅ Restored. Restart service.${NC}"; else echo -e "${RED}Not found${NC}"; fi; }
change_port() { read -p "New listen port: " new_port; write_config "listen_port" $new_port; echo -e "${GREEN}✅ Port updated. Restart ZIVPN.${NC}"; }
set_connection_limit() { read -p "Max sessions per user: " new_max; write_config "max_sessions_per_user" $new_max; echo -e "${GREEN}✅ Limit set to $new_max${NC}"; }
show_menu() { show_header; echo -e "${CYAN}${BOLD}        ╔════════════════════════════════════════════════════════════╗${NC}"; echo -e "        ║  ${GREEN}1) Start    2) Stop    3) Restart    4) Status${NC}                  ║"; echo -e "        ║  ${GREEN}5) List Users    6) Add User    7) Remove User${NC}                 ║"; echo -e "        ║  ${GREEN}8) Extend User   9) Cleanup Expired   10) Reset Bandwidth${NC}       ║"; echo -e "        ║  ${GREEN}11) Test User    12) Backup    13) Restore Backup${NC}             ║"; echo -e "        ║  ${GREEN}14) Change Port  15) Connection Limit  16) Live Logs${NC}          ║"; echo -e "        ║  ${RED}99) UNINSTALL       0) Exit${NC}                                      ║"; echo -e "${CYAN}        ╚════════════════════════════════════════════════════════════╝${NC}"; echo -ne "${BOLD}Choose: ${NC}"; }
uninstall() { read -p "Type 'YES I AM SURE' to uninstall: " confirm; if [[ "$confirm" == "YES I AM SURE" ]]; then stop_zivpn; rm -rf /opt/zivpn /root/ziudp.sh /usr/local/bin/zivpn; systemctl disable zivpn-web 2>/dev/null; rm -f /etc/systemd/system/zivpn-web.service; echo -e "${RED}Removed.${NC}"; exit 0; fi; }
main() { init_config; load_settings; init_database; create_python_proxy; while true; do show_menu; read choice; case $choice in 1) start_zivpn;; 2) stop_zivpn;; 3) restart_zivpn;; 4) status_zivpn;; 5) list_users;; 6) add_user;; 7) delete_user;; 8) extend_user;; 9) cleanup_expired;; 10) reset_bandwidth;; 11) test_user;; 12) backup_data;; 13) restore_backup;; 14) change_port;; 15) set_connection_limit;; 16) tail -f "$AUTH_LOG";; 99) uninstall;; 0) exit 0;; *) echo -e "${RED}Invalid${NC}";; esac; echo -e "\n${YELLOW}Press Enter...${NC}"; read; done; }
main
EOFCLI
chmod +x /root/ziudp.sh
ln -sf /root/ziudp.sh /usr/local/bin/zivpn

# --- Create Web Panel files ---
echo -e "${YELLOW}[6/8] Installing Web Panel...${NC}"
cat > /opt/zivpn/webpanel/app.py << 'EOFWEB'
#!/usr/bin/env python3
from flask import Flask, render_template, request, jsonify, session, redirect, url_for
from flask_cors import CORS
import sqlite3, json, os, subprocess, time, psutil, hashlib, functools
from datetime import datetime
app = Flask(__name__)
app.secret_key = os.urandom(24)
CORS(app)
DB_PATH = "/opt/zivpn/users.db"
CONFIG_PATH = "/opt/zivpn/config.json"
AUTH_LOG = "/opt/zivpn/logs/auth.log"
PROXY_PID_FILE = "/opt/zivpn/pids/auth.pid"
ADMIN_USERNAME = "admin"
ADMIN_PASSWORD_HASH = hashlib.sha256("admin123".encode()).hexdigest()
def login_required(f):
    @functools.wraps(f)
    def decorated_function(*args, **kwargs):
        if not session.get('logged_in'):
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function
def get_db(): conn = sqlite3.connect(DB_PATH); conn.row_factory = sqlite3.Row; return conn
def load_config(): return json.load(open(CONFIG_PATH))
def save_config(config): json.dump(config, open(CONFIG_PATH, 'w'), indent=2)
def is_zivpn_running(): return os.path.exists(PROXY_PID_FILE) and psutil.pid_exists(int(open(PROXY_PID_FILE).read()))
@app.route('/')
@login_required
def index(): return render_template('index.html')
@app.route('/login', methods=['GET','POST'])
def login():
    if request.method == 'POST':
        username = request.form['username']
        password = request.form['password']
        if username == ADMIN_USERNAME and hashlib.sha256(password.encode()).hexdigest() == ADMIN_PASSWORD_HASH:
            session['logged_in'] = True
            return redirect(url_for('index'))
        else:
            return render_template('login.html', error="Invalid credentials")
    return render_template('login.html')
@app.route('/logout')
def logout(): session.pop('logged_in', None); return redirect(url_for('login'))
@app.route('/api/server_info')
@login_required
def server_info():
    ip = subprocess.getoutput("curl -s -4 ifconfig.me").strip()
    geo = subprocess.getoutput("curl -s https://ipapi.co/json/ | python3 -c \"import sys,json; d=json.load(sys.stdin); print(f\\\"{d.get('city','Unknown')}, {d.get('country_name','Unknown')}\\\")\"")
    cpu = psutil.cpu_percent(); mem = psutil.virtual_memory().percent; disk = psutil.disk_usage('/').percent
    uptime = subprocess.getoutput("uptime -p").strip()
    return jsonify({'ip':ip, 'geo':geo, 'cpu':cpu, 'mem':mem, 'disk':disk, 'uptime':uptime, 'zivpn_running':is_zivpn_running(), 'datetime':datetime.now().strftime("%A, %d %B %Y %H:%M:%S")})
@app.route('/api/users')
@login_required
def get_users():
    conn = get_db(); users = conn.execute("SELECT id, username, password, expiry, data_limit, data_used, device_id, session_count, last_seen FROM users").fetchall(); conn.close()
    user_list = []
    for u in users:
        user_list.append({'id':u['id'], 'username':u['username'], 'password':u['password'], 'expiry':datetime.fromtimestamp(u['expiry']).strftime("%Y-%m-%d %H:%M:%S"), 'data_limit_mb':round(u['data_limit']/(1024*1024),2), 'data_used_mb':round(u['data_used']/(1024*1024),2), 'usage_percent':round(u['data_used']*100/u['data_limit'],1) if u['data_limit']>0 else 0, 'device_id':u['device_id'] or 'Not bound', 'sessions':u['session_count'], 'last_seen':datetime.fromtimestamp(u['last_seen']).strftime("%Y-%m-%d %H:%M:%S") if u['last_seen'] else 'Never'})
    return jsonify(user_list)
@app.route('/api/add_user', methods=['POST'])
@login_required
def add_user():
    data = request.json; username = data.get('username'); password = data.get('password'); days = int(data.get('days',30)); quota_gb = float(data.get('quota_gb',1)); device_id = data.get('device_id','')
    expiry = int(time.time()) + days*86400; data_limit = int(quota_gb*1024*1024*1024)
    conn = get_db()
    try: conn.execute("INSERT INTO users (username, password, expiry, data_limit, device_id) VALUES (?,?,?,?,?)", (username, password, expiry, data_limit, device_id)); conn.commit(); return jsonify({'success':True, 'message':'User added'})
    except sqlite3.IntegrityError: return jsonify({'success':False, 'message':'Username exists'}),400
    finally: conn.close()
@app.route('/api/delete_user', methods=['POST'])
@login_required
def delete_user(): username = request.json.get('username'); conn=get_db(); conn.execute("DELETE FROM users WHERE username=?", (username,)); conn.commit(); conn.close(); return jsonify({'success':True})
@app.route('/api/extend_user', methods=['POST'])
@login_required
def extend_user(): username = request.json.get('username'); extra_days = int(request.json.get('extra_days',0)); conn=get_db(); conn.execute("UPDATE users SET expiry = expiry + ? WHERE username=?", (extra_days*86400, username)); conn.commit(); conn.close(); return jsonify({'success':True})
@app.route('/api/reset_bandwidth', methods=['POST'])
@login_required
def reset_bandwidth(): username = request.json.get('username'); conn=get_db(); conn.execute("UPDATE users SET data_used=0 WHERE username=?", (username,)); conn.commit(); conn.close(); return jsonify({'success':True})
@app.route('/api/cleanup_expired', methods=['POST'])
@login_required
def cleanup_expired(): now=int(time.time()); conn=get_db(); deleted=conn.execute("DELETE FROM users WHERE expiry < ?", (now,)).rowcount; conn.commit(); conn.close(); return jsonify({'success':True, 'message':f'Cleaned up {deleted} users'})
@app.route('/api/start_zivpn', methods=['POST'])
@login_required
def start_zivpn(): subprocess.Popen(["/root/ziudp.sh", "start"], shell=True); return jsonify({'success':True})
@app.route('/api/stop_zivpn', methods=['POST'])
@login_required
def stop_zivpn(): subprocess.Popen(["/root/ziudp.sh", "stop"], shell=True); return jsonify({'success':True})
@app.route('/api/restart_zivpn', methods=['POST'])
@login_required
def restart_zivpn(): subprocess.Popen(["/root/ziudp.sh", "restart"], shell=True); return jsonify({'success':True})
@app.route('/api/change_port', methods=['POST'])
@login_required
def change_port(): listen_port = request.json.get('listen_port'); backend_port = request.json.get('backend_port'); config = load_config(); if listen_port: config['listen_port'] = int(listen_port); if backend_port: config['backend_port'] = int(backend_port); save_config(config); return jsonify({'success':True})
@app.route('/api/set_connection_limit', methods=['POST'])
@login_required
def set_connection_limit(): limit = int(request.json.get('limit',3)); config = load_config(); config['max_sessions_per_user'] = limit; save_config(config); return jsonify({'success':True})
@app.route('/api/create_test_user', methods=['POST'])
@login_required
def create_test_user(): minutes = int(request.json.get('minutes',30)); test_user = f"test_{int(time.time())}"; test_pass = subprocess.getoutput("tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8"); expiry = int(time.time()) + minutes*60; conn=get_db(); conn.execute("INSERT INTO users (username, password, expiry, data_limit) VALUES (?,?,?,?)", (test_user, test_pass, expiry, 100*1024*1024)); conn.commit(); conn.close(); return jsonify({'success':True, 'username':test_user, 'password':test_pass, 'expiry_minutes':minutes})
@app.route('/api/backup', methods=['POST'])
@login_required
def backup(): backup_file = f"/opt/zivpn/backups/backup_{datetime.now().strftime('%Y%m%d_%H%M%S')}.tar.gz"; os.makedirs("/opt/zivpn/backups", exist_ok=True); subprocess.call(f"tar czf {backup_file} -C /opt/zivpn users.db config.json", shell=True); return jsonify({'success':True, 'message':f'Backup: {backup_file}'})
if __name__ == '__main__': app.run(host='0.0.0.0', port=5000, debug=False)
EOFWEB

cat > /opt/zivpn/webpanel/templates/index.html << 'EOFHTML'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>ZIVPN UDP Panel</title><style>
*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);min-height:100vh;padding:20px}.container{max-width:1400px;margin:0 auto}.header{background:rgba(0,0,0,0.8);color:white;padding:20px;border-radius:15px;margin-bottom:20px;text-align:center}.header h1{font-size:2.5em;letter-spacing:2px}.stats-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:15px;margin-bottom:20px}.stat-card{background:white;border-radius:10px;padding:15px;box-shadow:0 4px 6px rgba(0,0,0,0.1);text-align:center}.stat-card h3{color:#667eea;margin-bottom:10px}.stat-card .value{font-size:1.8em;font-weight:bold;color:#333}.action-buttons{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:20px;justify-content:center}.btn{padding:10px 20px;border:none;border-radius:5px;cursor:pointer;font-weight:bold;transition:transform 0.2s}.btn:hover{transform:translateY(-2px)}.btn-primary{background:#28a745;color:white}.btn-danger{background:#dc3545;color:white}.btn-warning{background:#ffc107;color:#333}.btn-info{background:#17a2b8;color:white}.btn-secondary{background:#6c757d;color:white}.user-table{background:white;border-radius:10px;overflow-x:auto;box-shadow:0 4px 6px rgba(0,0,0,0.1)}table{width:100%;border-collapse:collapse}th,td{padding:12px;text-align:left;border-bottom:1px solid #ddd}th{background:#667eea;color:white}tr:hover{background:#f5f5f5}.modal{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.5);justify-content:center;align-items:center;z-index:1000}.modal-content{background:white;padding:30px;border-radius:10px;width:400px;max-width:90%}.modal-content input,.modal-content select{width:100%;padding:10px;margin:10px 0;border:1px solid #ddd;border-radius:5px}.modal-buttons{display:flex;justify-content:flex-end;gap:10px;margin-top:20px}.service-status{display:inline-block;padding:5px 10px;border-radius:20px;font-size:0.9em}.status-running{background:#28a745;color:white}.status-stopped{background:#dc3545;color:white}@media (max-width:768px){th,td{font-size:12px;padding:8px}.btn{padding:8px 12px;font-size:12px}}
</style></head>
<body><div class="container"><div class="header"><h1>🛡️ ZIVPN UDP PANEL</h1><p>User Management Dashboard | <a href="/logout" style="color:white">Logout</a></p></div><div class="stats-grid" id="statsGrid"></div><div class="action-buttons"><button class="btn btn-primary" onclick="startZIVPN()">▶ Start ZIVPN</button><button class="btn btn-danger" onclick="stopZIVPN()">⏹ Stop ZIVPN</button><button class="btn btn-warning" onclick="restartZIVPN()">🔄 Restart ZIVPN</button><button class="btn btn-info" onclick="showAddUserModal()">➕ Add User</button><button class="btn btn-secondary" onclick="cleanupExpired()">🧹 Cleanup Expired</button><button class="btn btn-secondary" onclick="showTestUserModal()">🧪 Test User</button><button class="btn btn-secondary" onclick="backupData()">💾 Backup</button><button class="btn btn-secondary" onclick="showSettingsModal()">⚙ Settings</button></div><div class="user-table"><table id="userTable"><thead><tr><th>Username</th><th>Password</th><th>Expiry</th><th>Used/Total (MB)</th><th>Usage %</th><th>Device ID</th><th>Sessions</th><th>Actions</th></tr></thead><tbody id="userTableBody"></tbody></table></div></div><div id="addUserModal" class="modal"><div class="modal-content"><h2>Add User</h2><input type="text" id="newUsername" placeholder="Username" required><input type="text" id="newPassword" placeholder="Password" required><input type="number" id="newDays" placeholder="Days" value="30"><input type="number" id="newQuota" placeholder="Quota (GB)" value="1" step="0.5"><input type="text" id="newDeviceId" placeholder="Device ID (optional)"><div class="modal-buttons"><button class="btn btn-primary" onclick="addUser()">Add</button><button class="btn btn-secondary" onclick="closeModal('addUserModal')">Cancel</button></div></div></div><div id="testUserModal" class="modal"><div class="modal-content"><h2>Test User</h2><input type="number" id="testMinutes" placeholder="Minutes (1-60)" value="30" min="1" max="60"><div class="modal-buttons"><button class="btn btn-primary" onclick="createTestUser()">Create</button><button class="btn btn-secondary" onclick="closeModal('testUserModal')">Cancel</button></div></div></div><div id="settingsModal" class="modal"><div class="modal-content"><h2>Settings</h2><label>Listen Port:</label><input type="number" id="listenPort" placeholder="Current port"><label>Backend Port:</label><input type="number" id="backendPort" placeholder="Current backend port"><label>Max Sessions/User:</label><input type="number" id="maxSessions" placeholder="Limit"><div class="modal-buttons"><button class="btn btn-primary" onclick="saveSettings()">Save</button><button class="btn btn-secondary" onclick="closeModal('settingsModal')">Cancel</button></div></div></div><script>
async function fetchServerInfo(){const res=await fetch('/api/server_info');const data=await res.json();document.getElementById('statsGrid').innerHTML=`<div class="stat-card"><h3>🌍 Server IP</h3><div class="value">${data.ip}</div></div><div class="stat-card"><h3>📍 Location</h3><div class="value">${data.geo}</div></div><div class="stat-card"><h3>💻 CPU</h3><div class="value">${data.cpu}%</div></div><div class="stat-card"><h3>🧠 RAM</h3><div class="value">${data.mem}%</div></div><div class="stat-card"><h3>💾 Disk</h3><div class="value">${data.disk}%</div></div><div class="stat-card"><h3>⏱ Uptime</h3><div class="value">${data.uptime}</div></div><div class="stat-card"><h3>🕒 Time</h3><div class="value">${data.datetime}</div></div><div class="stat-card"><h3>🔌 ZIVPN</h3><div class="value"><span class="service-status ${data.zivpn_running?'status-running':'status-stopped'}">${data.zivpn_running?'RUNNING':'STOPPED'}</span></div></div>`;}
async function fetchUsers(){const res=await fetch('/api/users');const users=await res.json();const tbody=document.getElementById('userTableBody');tbody.innerHTML='';users.forEach(u=>{const row=tbody.insertRow();row.insertCell(0).innerText=u.username;row.insertCell(1).innerText=u.password;row.insertCell(2).innerText=u.expiry;row.insertCell(3).innerText=`${u.data_used_mb} / ${u.data_limit_mb}`;row.insertCell(4).innerHTML=`<progress value="${u.usage_percent}" max="100" style="width:80px"></progress> ${u.usage_percent}%`;row.insertCell(5).innerText=u.device_id;row.insertCell(6).innerText=u.sessions;const actions=row.insertCell(7);actions.innerHTML=`<button class="btn btn-warning" style="padding:5px 10px; margin:2px;" onclick="extendUser('${u.username}')">Extend</button><button class="btn btn-info" style="padding:5px 10px; margin:2px;" onclick="resetBandwidth('${u.username}')">Reset</button><button class="btn btn-danger" style="padding:5px 10px; margin:2px;" onclick="deleteUser('${u.username}')">Delete</button>`;});}
async function startZIVPN(){await fetch('/api/start_zivpn',{method:'POST'});alert('Start command sent');fetchServerInfo();}
async function stopZIVPN(){await fetch('/api/stop_zivpn',{method:'POST'});alert('Stop command sent');fetchServerInfo();}
async function restartZIVPN(){await fetch('/api/restart_zivpn',{method:'POST'});alert('Restart command sent');fetchServerInfo();}
async function cleanupExpired(){await fetch('/api/cleanup_expired',{method:'POST'});alert('Expired users cleaned');fetchUsers();}
async function backupData(){const res=await fetch('/api/backup',{method:'POST'});const data=await res.json();alert(data.message);}
function showAddUserModal(){document.getElementById('addUserModal').style.display='flex';}
function showTestUserModal(){document.getElementById('testUserModal').style.display='flex';}
function showSettingsModal(){document.getElementById('settingsModal').style.display='flex';}
function closeModal(id){document.getElementById(id).style.display='none';}
async function addUser(){const username=document.getElementById('newUsername').value;const password=document.getElementById('newPassword').value;const days=document.getElementById('newDays').value;const quota_gb=document.getElementById('newQuota').value;const device_id=document.getElementById('newDeviceId').value;const res=await fetch('/api/add_user',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username,password,days:parseInt(days),quota_gb:parseFloat(quota_gb),device_id})});const data=await res.json();alert(data.message);if(data.success){closeModal('addUserModal');fetchUsers();}}
async function deleteUser(username){if(confirm(`Delete ${username}?`)){await fetch('/api/delete_user',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username})});fetchUsers();}}
async function extendUser(username){let days=prompt('Extra days:');if(days){await fetch('/api/extend_user',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username,extra_days:parseInt(days)})});fetchUsers();}}
async function resetBandwidth(username){if(confirm(`Reset bandwidth for ${username}?`)){await fetch('/api/reset_bandwidth',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username})});fetchUsers();}}
async function createTestUser(){const minutes=document.getElementById('testMinutes').value;const res=await fetch('/api/create_test_user',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({minutes:parseInt(minutes)})});const data=await res.json();if(data.success){alert(`Test user created:\nUsername: ${data.username}\nPassword: ${data.password}\nExpires in ${data.expiry_minutes} minutes`);closeModal('testUserModal');fetchUsers();}}
async function saveSettings(){const listen_port=document.getElementById('listenPort').value;const backend_port=document.getElementById('backendPort').value;const max_sessions=document.getElementById('maxSessions').value;if(listen_port) await fetch('/api/change_port',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({listen_port,backend_port})});if(max_sessions) await fetch('/api/set_connection_limit',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({limit:parseInt(max_sessions)})});alert('Settings saved. Restart ZIVPN to apply port changes.');closeModal('settingsModal');}
setInterval(()=>{fetchServerInfo();fetchUsers();},10000);fetchServerInfo();fetchUsers();
</script></body></html>
EOFHTML

cat > /opt/zivpn/webpanel/templates/login.html << 'EOFLOGIN'
<!DOCTYPE html>
<html><head><title>ZIVPN Login</title><style>body{font-family:Arial;background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);height:100vh;display:flex;justify-content:center;align-items:center;margin:0}.login-box{background:white;padding:40px;border-radius:10px;width:350px;box-shadow:0 0 20px rgba(0,0,0,0.2);text-align:center}.login-box h2{margin-bottom:20px;color:#667eea}.login-box input{width:100%;padding:12px;margin:10px 0;border:1px solid #ddd;border-radius:5px}.login-box button{width:100%;padding:12px;background:#28a745;color:white;border:none;border-radius:5px;cursor:pointer;font-size:16px}.error{color:red;margin-top:10px}</style></head><body><div class="login-box"><h2>🔐 ZIVPN Admin Login</h2><form method="POST"><input type="text" name="username" placeholder="Username" required><input type="password" name="password" placeholder="Password" required><button type="submit">Login</button>{% if error %}<div class="error">{{ error }}</div>{% endif %}</form></div></body></html>
EOFLOGIN

# --- Create systemd service for Web Panel ---
echo -e "${YELLOW}[7/8] Creating systemd service for Web Panel...${NC}"
cat > /etc/systemd/system/zivpn-web.service << 'EOFSVC'
[Unit]
Description=ZIVPN Web Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/zivpn/webpanel
ExecStart=/usr/bin/python3 /opt/zivpn/webpanel/app.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOFSVC

systemctl daemon-reload
systemctl enable zivpn-web
systemctl start zivpn-web

# --- Configure firewall (optional) ---
echo -e "${YELLOW}[8/8] Configuring firewall...${NC}"
if command -v ufw &> /dev/null; then
    ufw allow 5000/tcp comment 'ZIVPN Web Panel'
    ufw allow 7300/udp comment 'ZIVPN UDP Port'
    ufw reload || true
fi

# --- Final message ---
SERVER_IP=$(curl -s -4 ifconfig.me || echo "your-server-ip")
echo -e "${GREEN}${BOLD}"
echo "════════════════════════════════════════════════════════════════════"
echo "✅ INSTALLATION COMPLETE!"
echo "════════════════════════════════════════════════════════════════════"
echo -e "${NC}"
echo -e "${CYAN}📱 CLI Dashboard:${NC}"
echo -e "   Run: ${GREEN}zivpn${NC} or ${GREEN}/root/ziudp.sh${NC}"
echo ""
echo -e "${CYAN}🌐 Web Panel:${NC}"
echo -e "   URL: ${GREEN}http://$SERVER_IP:5000${NC}"
echo -e "   Login: ${GREEN}admin${NC} / ${GREEN}admin123${NC}"
echo -e "   ${YELLOW}⚠️  Change password in /opt/zivpn/webpanel/app.py${NC}"
echo ""
echo -e "${CYAN}🔌 ZIVPN Connection:${NC}"
echo -e "   Server IP: ${GREEN}$SERVER_IP${NC}"
echo -e "   Port: ${GREEN}7300${NC} (default, can be changed)"
echo -e "   Use ZIVPN Android app with username/password you create"
echo ""
echo -e "${CYAN}📝 Quick Start:${NC}"
echo -e "   1. Start ZIVPN: ${GREEN}zivpn${NC} → option 1"
echo -e "   2. Add a user: ${GREEN}zivpn${NC} → option 6"
echo -e "   3. Or use web panel to manage users"
echo ""
echo -e "${YELLOW}💡 Tip: Run 'zivpn' anytime to open CLI dashboard${NC}"
echo ""
