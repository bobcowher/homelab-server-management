#!/usr/bin/env python3
"""Force declared values into Open WebUI's persisted config.

Open WebUI treats many settings as PersistentConfig: the environment variable
seeds the value on FIRST start only, and from then on the copy in webui.db
wins. Compose env vars are therefore not authoritative, and a setting can drift
from what Ansible declares without anything reporting a change. That is not
theoretical -- it is how a hard-coded 192.168.1.30 survived the DHCP audit, and
how ENABLE_OLLAMA_API=false silently did nothing.

Desired values come from a JSON file rendered by Ansible, so this script holds
no policy of its own. Values are compared as parsed JSON, not as text, so
formatting differences do not read as drift.

Prints "changed" if it wrote anything, so Ansible reports accurately and
restarts the container only when needed.

  openwebui_persistent_config.py <desired.json> [webui.db]
"""
import json
import sqlite3
import sys

DEFAULT_DB = "/data/open-webui/webui.db"


def main(argv):
    if len(argv) < 2:
        print("usage: openwebui_persistent_config.py <desired.json> [db]")
        return 2

    with open(argv[1]) as fh:
        wanted = json.load(fh)

    db = argv[2] if len(argv) > 2 else DEFAULT_DB

    try:
        conn = sqlite3.connect(db)
        conn.execute("select 1 from config limit 1")
    except sqlite3.Error as exc:
        # A fresh install has no database until the container first starts.
        # Nothing to correct yet; compose env seeds the initial values.
        print("skipped: %s not usable yet (%s)" % (db, exc))
        return 0

    changed = []
    with conn:
        for key, value in wanted.items():
            row = conn.execute(
                "select value from config where key = ?", (key,)
            ).fetchone()
            if row is None:
                # Key absent means Open WebUI has not seeded it. Do not invent
                # schema; a version that wants this key will create it.
                continue
            try:
                current = json.loads(row[0])
            except (TypeError, ValueError):
                current = row[0]
            if current == value:
                continue
            conn.execute(
                "update config set value = ? where key = ?",
                (json.dumps(value), key),
            )
            changed.append("%s: %r -> %r" % (key, current, value))

    conn.close()
    if changed:
        print("changed")
        for line in changed:
            print("  " + line)
    else:
        print("ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
