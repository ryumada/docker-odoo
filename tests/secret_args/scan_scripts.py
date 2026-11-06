#!/usr/bin/env python3
# Category: Test
# Description: Finds secrets passed as command-line arguments in the repository's shell scripts (visible to every
#              user through ps and /proc/*/cmdline), and checks that the safe forms are wired up correctly.
# Usage: scan_scripts.py REPO_ROOT   (prints one "file:line: problem" per finding; exit 1 when there are any)
# Dependencies: python3
import os, re, sys

root = sys.argv[1]
SECRET_VAR = r'\$\{?[A-Za-z_]*(?:PASSWD|PASSWORD|PASS|TOKEN|SECRET|_pass|_passwd|_password|_token|token|jwt|assertion)\}?\b'

# Secret values written straight into an argument
FORBIDDEN = [
    (r'-e "?PGPASSWORD=', 'PGPASSWORD value on the docker command line (use PGPASSWORD="$x" docker ... -e PGPASSWORD)'),
    (r'-e "?[A-Z_]*(?:PASSWORD|PASSWD|TOKEN|SECRET)[A-Z_]*=\$', 'secret value on the docker command line'),
    (r'master_pwd=\$', 'Odoo master password on the curl command line'),
    (r'Authorization: Bearer \$', 'bearer token on the curl command line (use -H @<(printf ...))'),
    (r'tokeninfo\?access_token=', 'access token in a URL (send it in the POST body)'),
    (r'assertion=\$', 'signed service-account assertion on the curl command line'),
    (r'(?:^|\s)(?:-F|--form|--form-string|-d|--data|--data-raw|--data-binary|--data-urlencode|-H|--header|-u|--user)\s+"[^"]*' + SECRET_VAR,
     'secret variable inside a curl argument'),
    (r'sshpass\s+-p', 'password on the sshpass command line'),
]

def files():
    for top in ("setup.sh", "entrypoint.sh", "scripts"):
        path = os.path.join(root, top)
        if os.path.isfile(path):
            yield path
        for d, dirs, names in os.walk(path):
            dirs[:] = [x for x in dirs if x not in (".git", "graphify-out", "node_modules")]
            for n in names:
                if n.endswith((".sh", ".sh.example")):
                    yield os.path.join(d, n)

def command_start(lines, i):
    # Walks back over "\" continuations to the line where this command begins
    while i > 0 and lines[i - 1].rstrip().endswith("\\"):
        i -= 1
    return i

problems = []
for path in sorted(set(files())):
    rel = os.path.relpath(path, root)
    lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    for i, line in enumerate(lines):
        code = line.split(" #", 1)[0] if not line.lstrip().startswith("#") else ""
        if not code.strip():
            continue
        for pattern, why in FORBIDDEN:
            if re.search(pattern, code):
                problems.append("%s:%d: %s" % (rel, i + 1, why))
                break
        # -F "master_pwd=<-" reads curl's stdin: the value must be piped in, or curl would wait on the terminal
        if '-F "master_pwd=<-"' in code:
            start = command_start(lines, i)
            text = "\n".join(lines[start:i + 1])
            if "curl" in text and not re.search(r"printf '%s' \"\$\{?\w+\}?\" \| curl", text):
                problems.append("%s:%d: master_pwd=<- without the password piped into curl" % (rel, i + 1))
            if "curl" not in text:  # inside an argument array: the curl call using it must have the pipe
                whole = "\n".join(lines)
                arrays = re.findall(r"(\w+)=\(\s*$", "\n".join(lines[max(0, i - 6):i]), re.M)
                if not arrays or not re.search(r"printf '%s' \"\$\{?\w+\}?\" \| curl \"\$\{" + arrays[-1] + r"\[@\]\}\"", whole):
                    problems.append("%s:%d: master_pwd=<- in an argument array whose curl call is not fed the password" % (rel, i + 1))
        # docker -e PGPASSWORD (no value) takes the value from the environment: it must be set on that command
        if re.search(r'-e PGPASSWORD(\s|$)', code) and "docker" in code:
            if not re.search(r'PGPASSWORD="[^"]*" docker ', code):
                problems.append("%s:%d: docker -e PGPASSWORD without PGPASSWORD=... set for that command" % (rel, i + 1))

for p in problems:
    print(p)
sys.exit(1 if problems else 0)
