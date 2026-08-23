# viber-export

**Decrypt, back up, and migrate your Viber Desktop message history.**

Viber Desktop keeps your entire chat history in a local SQLite database
(`…/ViberPC/<phone-number>/viber.db`) — but that file is **encrypted**, and Viber provides
no way to export it, back it up, or move it to another computer. If you switch machines or
operating systems, your desktop history is effectively lost.

These tools fix that. They decrypt `viber.db` into an ordinary SQLite file you can read,
archive, or migrate — and they can **merge** an old archive into a current install so all your
history lives in one place again. Everything runs locally and offline; nothing is uploaded.

> **This works on your own data only.** The tools discover the key the way Viber itself does —
> by reusing Viber's own code on your own machine. They cannot decrypt someone else's database.

---

## Contents

| Command | What it does |
|---------|--------------|
| `viber-export-linux` | Decrypt a **Linux** Viber `viber.db` → plaintext SQLite |
| `viber-export-mac`   | Decrypt a **macOS** Viber `viber.db` → plaintext SQLite |
| `viber-merge`        | Merge a decrypted archive into a target install (either OS) |
| `dedup-chats.py`     | Merge duplicate 1-to-1 conversations in a decrypted db |
| `src/dump.cpp`       | Decrypt harness (uses Viber's own SQLite codec) |
| `src/encrypt.cpp`    | Re-encrypt a plaintext db back into Viber's format |
| `src/merge.py`       | The platform-independent merge (operates on decrypted dbs) |
| `lib/viber-common.sh`| Shared logic (locate Viber, build harnesses, discover the key) |
| `INTERNALS.md`       | How Viber's encryption works and how these tools defeat it |

---

## Requirements

**Linux**
- `gdb`, `g++`, `pkg-config`, `unshare` (util-linux), `sqlite3`
- Qt 6 development headers: `Qt6Sql`, `Qt6Core`
- The Viber **AppImage** installed (the tools borrow its codec and Qt libraries)

**macOS**
- Xcode command-line tools: `xcode-select --install`
- **Viber.app** installed (for its codec and Qt frameworks)
- Qt 6 headers — fetched automatically with [`aqtinstall`](https://github.com/miurahr/aqtinstall)
  (via `pip`, no admin rights) if not already present

No admin/root is required on either platform.

---

## Quick start

```bash
git clone <this-repo> viber-export
cd viber-export
```

### Export (decrypt) your history

```bash
# Linux
./viber-export-linux  ~/.ViberPC/<phone-number>/viber.db  history.db

# macOS
./viber-export-mac  "~/Library/Application Support/ViberPC/<phone-number>/viber.db"  history.db
```

`history.db` is a normal SQLite file. Browse it with any SQLite tool:

```bash
sqlite3 history.db "
  SELECT datetime(e.TimeStamp/1000,'unixepoch') AS when_utc, c.Name AS contact, m.Body
  FROM Events e
  JOIN Messages m ON m.EventID = e.EventID
  LEFT JOIN Contact c ON c.ContactID = e.ContactID
  WHERE m.Body <> ''
  ORDER BY e.TimeStamp DESC
  LIMIT 20;"
```

Useful tables: **`Events`** (one row per message/call), **`Messages`** (bodies),
**`Contact`**, **`ChatInfo`** / **`ChatRelation`** (conversations). The **`MessageInfo`** view
joins the common columns for you.

### Merge an old archive into a current install

For example, moving a macOS history into a fresh Linux Viber:

```bash
# 1) On a Mac: export the old history to a plaintext file.
./viber-export-mac  ".../ViberPC/<phone-number>/viber.db"  archive.db

# 2) On the target machine (e.g. Linux): merge it in.
./viber-merge  archive.db  ~/.ViberPC/<phone-number>/viber.db  merged.db

# 3) Apply it (the exact command is printed at the end of the run):
#    - quit Viber
#    - back up the current viber.db
#    - copy merged.db over it
#    - delete any viber.db-wal / viber.db-shm
```

`viber-merge` keeps your **current** install as the base (its schema, IDs and newest
messages), appends every message the archive has that it's missing, imports conversations that
exist only in the archive, de-duplicates chats, and re-encrypts the result **with your current
install's own key**. It works fully offline and **never modifies the live database** — it
verifies the output round-trips before finishing.

---

## How it works (in one paragraph)

The encryption key is never stored on disk; Viber derives it at startup. Rather than
re-implement that, these tools **reuse Viber's own code**: they briefly launch Viber headless
and offline under a debugger, read the exact `PRAGMA hexkey=…` it issues for `viber.db`, then
decrypt through Viber's own SQLite codec plugin. The macOS build additionally knows the key
formula and tries it first, without launching anything. The full reverse-engineering write-up —
cipher schemes, per-platform key derivation, and how to adapt the tools when Viber changes —
is in **[INTERNALS.md](INTERNALS.md)**.

---

## Troubleshooting

- **“Viber AppImage/app not found.”** Point the tool at it explicitly:
  `VIBER_APPIMAGE=/path/to/viber.appimage` (Linux) or `VIBER_APP=/path/to/Viber.app` (macOS).
- **“missing Qt6 dev headers.”** Install your distro's `qt6-base`/`qtbase6` dev package (Linux);
  macOS fetches them automatically.
- **`DECRYPT_FAIL … file is not a database`.** The key/scheme didn't match — this means a wrong
  key, not a corrupt file. Re-run; if you're decrypting a backup taken on a *different* Mac,
  pass its original login name: `VIBER_USERNAME=<name> ./viber-export-mac …`.
- **Duplicate conversations after a merge.** Run `dedup-chats.py` on a decrypted copy, or just
  re-run `viber-merge` (it de-duplicates automatically).

---

## Safety

- The source `viber.db` is **never written to** — key discovery runs against a temporary copy.
- Always **quit Viber and keep a backup** before replacing a live `viber.db`.
- Viber re-processes its database the first time it opens one (schema housekeeping, re-syncing
  recent messages from your phone); small count changes afterwards are normal.

---

## Disclaimer

Provided as-is, with no warranty. This project is not affiliated with or endorsed by Viber /
Rakuten. It decrypts **your own** local data using code already present on your own machine.
Use it in accordance with the laws and terms that apply to you.

## License

[MIT](LICENSE) © 2026 GhostingBit
