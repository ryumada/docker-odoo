#!/usr/bin/env python3
# Category: Test
# Description: Stand-in odoo-bin for the validator's boot check tests, committed as odoo-bin in the fixture
#              odoo-base repository. It reads the configuration Odoo would read, looks the installed modules
#              up in the restored database (psql) and in addons_path, logs the lines real Odoo logs for what
#              it finds, and serves /web/login.
# Usage: python3 odoo-bin [neutralize] -c CONF -d DB   (started by the fake docker; never on its own)
# Dependencies: python3, psql (PG_BIN)
#
# Module manifests may carry "fake_behavior": import_error (CRITICAL "Couldn't load module"), log_error (an ERROR
# line, Odoo still runs), http_500 (/web/login answers 500), crash (exits before the registry is ready).
# Every run is appended to $FAKE_DOCKER_STATE/odoo-events.log with the settings that matter for safety.
import ast, configparser, datetime, http.server, os, subprocess, sys, time

args = sys.argv[1:]
command = "server"
if args and not args[0].startswith("-"):
    command = args.pop(0)
conf_file, db = None, None
i = 0
while i < len(args):
    if args[i] == "-c":
        conf_file = args[i + 1]; i += 2
    elif args[i] == "-d":
        db = args[i + 1]; i += 2
    else:
        i += 1
c = configparser.ConfigParser(interpolation=None)
c.read(conf_file)
o = c["options"]
db = db or o.get("db_name")


def log(level, logger, msg):
    now = datetime.datetime.now()
    print("%s,%03d %d %s %s %s: %s" % (now.strftime("%Y-%m-%d %H:%M:%S"), now.microsecond // 1000, os.getpid(),
                                       level, db or "?", logger, msg), flush=True)


def psql(sql):
    r = subprocess.run([os.path.join(os.environ["PG_BIN"], "psql"), "-h", o["db_host"], "-p", o["db_port"],
                        "-U", o["db_user"], "-d", db, "-X", "-tA", "-c", sql],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr.strip())
    return [l for l in r.stdout.splitlines() if l]


state = os.environ.get("FAKE_DOCKER_STATE", "")
with open(os.path.join(state, "odoo-events.log"), "a") as f:
    f.write("%s db=%s workers=%s max_cron_threads=%s server_wide_modules=%s list_db=%s db_user=%s\n" % (
        command, db, o.get("workers"), o.get("max_cron_threads"), o.get("server_wide_modules"),
        o.get("list_db"), o.get("db_user")))

log("INFO", "odoo", "Odoo version 17.0 (fake)")
if command == "neutralize":
    if os.environ.get("FAKE_NEUTRALIZE_FAIL") == "1":
        log("CRITICAL", "odoo.cli.neutralize", "An error occurred during the neutralization (fake)")
        sys.exit(1)
    try:
        psql("SELECT 1")
    except RuntimeError as e:
        log("ERROR", "odoo.sql_db", "bad query: %s" % e)
        sys.exit(1)
    log("INFO", "odoo.cli.neutralize", "Neutralizing database %s" % db)
    log("INFO", "odoo.cli.neutralize", "Neutralization finished")
    sys.exit(0)

paths = [p for p in o.get("addons_path", "").split(",") if p]
behaviors, missing = set(), []
log("INFO", "odoo.service.server", "HTTP service (werkzeug) running on 0.0.0.0:%s" % o["http_port"])
try:
    installed = psql("SELECT name FROM ir_module_module WHERE state = 'installed' ORDER BY name")
except RuntimeError as e:
    installed = None
    log("CRITICAL", "odoo.service.server", "Failed to initialize database `%s`." % db)
    print("Traceback (most recent call last):\npsycopg2.errors.UndefinedTable: %s" % e, flush=True)
for name in installed or []:
    manifest = next((os.path.join(p, name, "__manifest__.py") for p in paths
                     if os.path.isfile(os.path.join(p, name, "__manifest__.py"))), None)
    if not manifest:
        missing.append(name); continue
    m = ast.literal_eval(open(manifest).read())
    if m.get("installable", True) is False:
        log("WARNING", "odoo.modules.loading", "module %s: not installable, skipped" % name)
        missing.append(name); continue
    b = m.get("fake_behavior")
    if b == "import_error":
        log("CRITICAL", "odoo.modules.module", "Couldn't load module %s" % name)
        print("Traceback (most recent call last):\nModuleNotFoundError: No module named 'paramiko'", flush=True)
        missing.append(name); continue
    if b:
        behaviors.add(b)
    if b == "log_error":
        log("ERROR", "odoo.addons.%s.models.sftp" % name, "Could not connect to SFTP server sftp.example.invalid: [Errno -3] Temporary failure in name resolution")
if missing:
    log("ERROR", "odoo.modules.loading", "Some modules are not loaded, some dependencies or manifest may be missing: %s" % sorted(missing))
if "crash" in behaviors:
    log("CRITICAL", "odoo", "Segmentation fault in a C extension (fake)")
    sys.exit(139)
if installed is not None:
    log("INFO", "odoo.modules.loading", "%d modules loaded in 0.05s, 0 queries" % len(installed))
    log("INFO", "odoo.modules.loading", "Modules loaded.")
    log("INFO", "odoo.modules.registry", "Registry loaded in 0.123s")


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = installed is not None and "http_500" not in behaviors and self.path.startswith("/web/login")
        body = b"<html><form class='oe_login_form'></form></html>" if ok else b"Internal Server Error"
        self.send_response(200 if ok else 500)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        log("INFO", "werkzeug", '127.0.0.1 - - "GET %s HTTP/1.1" %d' % (self.path, 200 if ok else 500))

    def log_message(self, *a):
        pass


http.server.HTTPServer(("127.0.0.1", int(o["http_port"])), H).serve_forever()
