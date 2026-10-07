"""Grant TCC permissions to app bundles on a disposable CI Mac by writing the TCC databases.

Usage: sudo python3 grant-tcc.py <bundle-id>=<path-to-.app> ...
Only for GitHub Actions macOS runners, which are thrown away after the job.
"""
import os
import sqlite3
import subprocess
import sys
import tempfile
import time

SERVICES = [
    "kTCCServiceAccessibility",
    "kTCCServicePostEvent",
    "kTCCServiceListenEvent",
    "kTCCServiceScreenCapture",
]
DATABASES = [
    "/Library/Application Support/com.apple.TCC/TCC.db",
    os.path.expanduser("~runner/Library/Application Support/com.apple.TCC/TCC.db"),
]


def code_requirement(app_path):
    result = subprocess.run(["codesign", "-d", "-r-", app_path], capture_output=True, text=True)
    line = next(l for l in (result.stdout + "\n" + result.stderr).splitlines() if "designated =>" in l)
    text = line.split("designated =>", 1)[1].strip()
    print(f"{app_path}: {text}")
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as out:
        path = out.name
    subprocess.run(["csreq", "-r-", "-b", path], input=text, text=True, check=True)
    with open(path, "rb") as blob:
        return blob.read()


def grant(db_path, client, blob):
    if not os.path.exists(db_path):
        print(f"skip missing {db_path}")
        return
    db = sqlite3.connect(db_path)
    columns = [row[1] for row in db.execute("PRAGMA table_info(access)")]
    for service in SERVICES:
        values = {
            "service": service, "client": client, "client_type": 0, "auth_value": 2,
            "auth_reason": 4, "auth_version": 1, "csreq": blob, "policy_id": None,
            "indirect_object_identifier_type": 0, "indirect_object_identifier": "UNUSED",
            "indirect_object_code_identity": None, "flags": 0, "last_modified": int(time.time()),
            "pid": None, "pid_version": None, "boot_uuid": "UNUSED", "last_reminded": 0,
        }
        row = [values.get(name) for name in columns]
        placeholders = ",".join("?" for _ in columns)
        db.execute(f"INSERT OR REPLACE INTO access ({','.join(columns)}) VALUES ({placeholders})", row)
    db.commit()
    db.close()
    print(f"granted {client} in {db_path}")


for argument in sys.argv[1:]:
    client, app_path = argument.split("=", 1)
    blob = code_requirement(app_path)
    for database in DATABASES:
        try:
            grant(database, client, blob)
        except sqlite3.Error as error:
            print(f"cannot write {database}: {error}")
