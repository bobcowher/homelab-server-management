#!/usr/bin/env python3
"""Force values into Open WebUI's persisted config.

Open WebUI treats many settings as PersistentConfig: the environment variable
seeds the value on FIRST start only, and from then on the copy in webui.db
wins. Compose env vars are therefore not authoritative, and a setting can drift
from what Ansible declares without anything reporting a change.

Two settings here are load-bearing:

  ollama.enable          -- with no Ollama on this host, get_all_models() still
                            fanned out to it and blocked ~10s per page load
                            before the connection failed. ENABLE_OLLAMA_API=false
                            in compose did NOT fix it, because of the above.

  openai.api_base_urls   -- had a hard-coded 192.168.1.30 baked in. The LAN is
                            DHCP, so that is a landmine: it works until the
                            lease changes, then every model fetch hangs.
                            host.docker.internal survives an address change.

Prints "changed" if it wrote anything, so Ansible can report accurately and
restart the container only when needed.
"""
import json
import sqlite3
import sys

DB = "/data/open-webui/webui.db"

WANTED = {
    "ollama.enable": json.dumps(False),
    "openai.api_base_urls": json.dumps(["http://host.docker.internal:8080/v1"]),
}


def main():
    try:
        conn = sqlite3.connect(DB)
    except sqlite3.Error as exc:
        # A fresh install has no database until the container first starts.
        # Nothing to correct yet, and the compose env seeds it correctly.
        print("skipped: cannot open %s (%s)" % (DB, exc))
        return 0

    changed = []
    with conn:
        for key, value in WANTED.items():
            row = conn.execute(
                "select value from config where key = ?", (key,)
            ).fetchone()
            if row is None:
                # Key absent means Open WebUI has not seeded it; leave it alone
                # rather than inventing schema.
                continue
            if row[0] == value:
                continue
            conn.execute(
                "update config set value = ? where key = ?", (value, key)
            )
            changed.append("%s: %s -> %s" % (key, row[0], value))

    conn.close()
    if changed:
        print("changed")
        for line in changed:
            print("  " + line)
    else:
        print("ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
