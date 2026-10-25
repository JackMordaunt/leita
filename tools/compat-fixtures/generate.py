#!/usr/bin/env python3
"""Regenerate cli/testdata/compat: every earlier on-disk format, as its code wrote it.

The files are checked in; this script is how they were made and how to add the next
format's. Run it from the repository root: python3 tools/compat-fixtures/generate.py

Baselines (LEITABL1..4) are laid out byte for byte as survey/baseline.odin wrote
them at 67625ca6 (1), 80fc6339 (2), c8b65130 (3) and a4745f64 (4). The SQLite
stores replay the SCHEMA, MONITOR_SCHEMA and column migrations of the commit that
introduced each version, read out of the repository, so a fixture is what that code
made. Licence lines of the draft leita2 prefix are the signed vectors of 5dc014b5.
"""
import os
import re
import sqlite3
import struct
import subprocess
import sys

OUT = os.path.join("cli", "testdata", "compat")
PLACE = b"/compat/place"


def vcs(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def write(name, data):
    path = os.path.join(OUT, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)


def read(name):
    with open(os.path.join(OUT, name), "rb") as f:
        return f.read()


# ---- baselines -------------------------------------------------------------

DIR = 4  # scan.Node_Flag.Directory, bit 2


def baseline(version):
    out = bytearray(b"LEITABL%d" % version)
    out += struct.pack("<B", 3)  # source: Probe
    out += struct.pack("<2Q", 0x801, 0x1)  # volume
    if version >= 3:
        out += struct.pack("<2Q", 0x77, 0x1234)  # place
    out += struct.pack("<Q", 5)  # journal
    out += struct.pack("<q", 1_700_000_000)  # position
    out += struct.pack("<q", 1_700_000_000)  # full
    if version >= 4:
        out += struct.pack("<Q", 2)  # updates
    out += struct.pack("<I", len(PLACE)) + PLACE
    nodes = [
        (0, DIR, 0, PLACE),
        (0, DIR, 4096, b"docs"),
        (1, 0, 1000, b"a.txt"),
        (0, 0, 2048, b"b.bin"),
    ]
    out += struct.pack("<II", len(nodes), 0)
    for parent, flags, disk, name in nodes:
        out += struct.pack("<IBQH", parent, flags, disk, len(name)) + name
    if version >= 2:
        out += struct.pack("<I", 1) + struct.pack("<IQQQ", 3, 0x801, 42, 0)
    return bytes(out)


def baselines():
    for v in (1, 2, 3, 4):
        write("baseline/bl%d.tree" % v, baseline(v))
    good = baseline(4)
    write("baseline/bl5-future.tree", b"LEITABL5" + good[8:])
    write("baseline/bl4-truncated.tree", good[: len(good) // 2])
    flipped = bytearray(good)
    flipped[8 + 65 + 4 + len(PLACE) + 3] ^= 0x80  # the node count's top byte
    write("baseline/bl4-bitflip.tree", bytes(flipped))
    magic = bytearray(good)
    magic[7] ^= 0x01  # LEITABL4 -> LEITABL5 by one flipped bit
    write("baseline/bl4-magic-bitflip.tree", bytes(magic))


# ---- sqlite stores -----------------------------------------------------------


def odin_block(source, name):
    m = re.search(r"^%s\s*::\s*`(.*?)`" % name, source, re.S | re.M)
    return m.group(1) if m else None


def alters(source):
    return re.findall(r'"(ALTER TABLE [^"]+)"', source)


def make_db(name, schemas, alter_sql, rows):
    path = os.path.join(OUT, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    for ext in ("", "-wal", "-shm"):
        if os.path.exists(path + ext):
            os.remove(path + ext)
    db = sqlite3.connect(path)
    db.execute("PRAGMA journal_mode = WAL")
    for s in schemas:
        db.executescript(s)
    for stmt in alter_sql:
        table, column = re.match(r"ALTER TABLE (\w+) ADD COLUMN (\w+)", stmt).groups()
        have = [r[1] for r in db.execute("SELECT * FROM pragma_table_info(?)", (table,))]
        if column not in have:
            db.execute(stmt)
    for sql in rows:
        db.execute(sql)
    db.commit()
    db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    db.close()
    for ext in ("-wal", "-shm"):
        if os.path.exists(path + ext):
            os.remove(path + ext)
    return path


def insert(db_path, statements):
    """Run statements on the store. Columns a later version added take their defaults."""
    db = sqlite3.connect(db_path)

    for q in statements:
        db.execute(q)

    db.commit()
    db.close()


def extend(src, dst, statements):
    write(dst, read(src))
    db = sqlite3.connect(os.path.join(OUT, dst))
    for s in statements:
        db.execute(s)
    db.commit()
    db.close()
    for ext in ("-wal", "-shm"):
        if os.path.exists(os.path.join(OUT, dst) + ext):
            os.remove(os.path.join(OUT, dst) + ext)


def damage(src, dst):
    data = read(src)
    write(dst + "-truncated.db", data[: len(data) // 2])
    flipped = bytearray(data)
    flipped[0] ^= 0x01  # "SQLite format 3" no longer
    write(dst + "-bitflip.db", bytes(flipped))
    inner = bytearray(data)
    inner[len(inner) // 2] ^= 0xFF  # inside a page: whatever SQLite makes of it
    write(dst + "-bitflip-body.db", bytes(inner))


def history():
    for version, commit in ((1, "819d970d"), (2, "cd369da0")):
        src = vcs("show", commit + ":history/history.odin")
        path = make_db("history/h%d.db" % version, [odin_block(src, "SCHEMA")], alters(src), [])
        rows = [
            "INSERT INTO snapshot(id, top, taken, bytes, items) VALUES (1, '/compat/place', 1700000000, 3048, 3)",
            "INSERT INTO snapshot(id, top, taken, bytes, items) VALUES (2, '/compat/place', 1700086400, 5048, 4)",
            "INSERT INTO entry VALUES (1, 'docs', 1000)",
            "INSERT INTO entry VALUES (2, 'docs', 3000)",
            "INSERT INTO action VALUES (1, 1700000100, 'trash', '/compat/place/old', '', 512, 0)",
        ]
        if version >= 2:
            rows.append("UPDATE snapshot SET disk_total = 7, disk_free = 7")
        insert(path, rows)
    # Made by a newer leita: a column and a table this one does not know, and a
    # user_version it never set.
    extend(
        "history/h2.db",
        "history/h-future.db",
        [
            "ALTER TABLE snapshot ADD COLUMN flavour TEXT NOT NULL DEFAULT 'next'",
            "CREATE TABLE tomorrow(k TEXT PRIMARY KEY, v TEXT NOT NULL)",
            "INSERT INTO tomorrow VALUES ('kept', 'yes')",
            "PRAGMA user_version = 99",
        ],
    )
    damage("history/h2.db", "history/h2")


def settings():
    steps = [
        (1, "52279103"),
        (2, "e8e304ec"),
        (3, "460ecd6e"),
        (4, "ba3dba26"),
        (5, "7e5500fe"),
        (6, "64c31908^"),
        (7, "HEAD"),
    ]
    for version, commit in steps:
        s_src = vcs("show", commit + ":settings/settings.odin")
        schemas = [odin_block(s_src, "SCHEMA")]
        alter = []
        if version >= 2:
            m_src = vcs("show", commit + ":settings/monitor.odin")
            schemas.append(odin_block(m_src, "MONITOR_SCHEMA"))
            alter = alters(m_src)
        if version >= 7:
            schemas.append(odin_block(vcs("show", commit + ":settings/webhook.odin"), "WEBHOOK_SCHEMA"))
        rows = [
            "INSERT INTO setting VALUES ('language', 'de')",
            "INSERT INTO setting VALUES ('theme', 'dark')",
        ]
        if version >= 2:
            rows.append("INSERT INTO setting VALUES ('monitor', 'on')")
        path = make_db("settings/s%d.db" % version, schemas, alter, rows)
        more = []
        if version >= 2:
            more.append("INSERT INTO watch(place, every, added) VALUES ('/compat/place', 'daily', 1700000000)")
            more.append(
                "INSERT INTO run(id, place, started, seconds, bytes, disk_total, disk_free, problem)"
                " VALUES (1, '/compat/place', 1700000100, 1.5, 3048, 7, 7, '')"
            )
        if version >= 4:
            more.append(
                "INSERT INTO raised(id, place, raised, kind, used_percent, free, total, days, grew, limit_crossed, problem)"
                " VALUES (1, '/compat/place', 1700000100, 'disk-full', 91.5, 7, 100, 0, 0, 90, '')"
            )
        if version >= 7:
            more.append(
                "INSERT INTO webhook(id, url, secret, paths, added) VALUES (1, 'https://hooks.example/leita', 'ab12', 1, 1700000000)"
            )
            more.append(
                "INSERT INTO delivery(id, hook, event, body, created, next_at)"
                " VALUES (1, 1, 'alert', '{}', 1700000100, 1700000200)"
            )
        insert(path, more)
    extend(
        "settings/s7.db",
        "settings/s-future.db",
        [
            "ALTER TABLE watch ADD COLUMN quiet_hours TEXT NOT NULL DEFAULT ''",
            "CREATE TABLE tomorrow(k TEXT PRIMARY KEY, v TEXT NOT NULL)",
            "PRAGMA user_version = 99",
        ],
    )
    damage("settings/s7.db", "settings/s7")


# ---- licence, receipt, first use, journal ----------------------------------------


def small():
    for n in (1, 2):  # draft leita2 lines, signed with the throwaway key, never issued
        write("licence/draft-leita2-vector-%d.line" % n, vcs("show", "5dc014b5:licence/testdata/throwaway/vector-%d.line" % n))
    with open("licence/testdata/throwaway/vector-1.line") as f:
        cur = f.read()
    write("licence/current.line", cur)
    write("licence/current-truncated.line", cur[: len(cur) // 2])
    body = bytearray(cur.encode())
    body[40] ^= 0x01
    write("licence/current-bitflip.line", bytes(body))
    write("licence/future-prefix.line", "leita3." + cur[len("leita.") :])
    write("firstuse/first-use", "1790000000\n")
    write("firstuse/first-use-garbled", "17900x0000\n")
    write("receipt/licence-key", "ABCD-1234-EFGH-5678\n")
    write("receipt/licence-key-garbled", b"ABCD 1234\n\x00\x00")
    write("receipt/licence-key-long", "K" * 200 + "\n")
    mount = b"/home"
    hdr = b"LEITAJL1" + struct.pack("<H", len(mount)) + mount
    rec = struct.pack("<BqQ", 0, 1_700_000_000_000_000_000, 7)
    log = hdr + rec + rec
    write("journal/current.log", log)
    write("journal/future.log", b"LEITAJL2" + log[8:])
    write("journal/truncated.log", log[: len(hdr) - 2])
    flipped = bytearray(log)
    flipped[8] = 0xFF  # a length that runs past the header's bound
    flipped[9] = 0xFF
    write("journal/bitflip.log", bytes(flipped))


if __name__ == "__main__":
    if not os.path.exists(".git"):
        sys.exit("run from the repository root")
    baselines()
    history()
    settings()
    small()
