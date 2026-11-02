# INTERNALS — how Viber Desktop encryption works and how these tools defeat it

Reference for maintainers and contributors: how Viber Desktop encrypts its message database,
and how these tools decrypt it. Reverse-engineered from Viber Desktop v27 (Linux AppImage and
the macOS build); the discovery technique is version-independent, but specific offsets/versions
may drift — this document explains what to check when they do.

## 1. What is encrypted

A Viber profile lives at:
* Linux: `~/.ViberPC/<phone>/`
* macOS: `~/Library/Application Support/ViberPC/<phone>/`

Only **`viber.db`** (messages, contacts, chats) is encrypted. `config.db` (account +
`DeviceKey`) and `data.db` (a lightly-obfuscated key/value store) are **plaintext** SQLite.
So the first byte of an encrypted `viber.db` is random; a plaintext one starts `SQLite format 3`.

## 2. The codec

Viber ships a **custom `SQLITE_HAS_CODEC` build of the Qt SQLite driver plugin**:
* Linux: `<appimage>/squashfs-root/usr/plugins/sqldrivers/libqsqlite.so`
* macOS: `Viber.app/Contents/PlugIns/sqldrivers/libqsqlite.dylib`

It only exports Qt plugin symbols (`qt_plugin_instance`), **not** the `sqlite3_*` C API — so
you cannot dlopen it directly; you must go through Qt's `QSqlDatabase`/`QSqlQuery`. The
plugin links Viber's own Qt frameworks (`@rpath`/`@loader_path` → `Frameworks/QtCore`,`QtSql`).

The codec understands the pragmas `hexkey`, `hexrekey`, `textkey`, `textrekey`, and supports
cipher schemes: `rc4, aes128, aes256, aes128ofb, aes256ofb, aes256gcm`, and a ChaCha20-based
default. The **scheme is chosen by a prefix inside the (hex-decoded) key string**, e.g. a key
whose bytes are `aes128:<passphrase>` selects AES-128. A plain 64-hex key (no prefix) uses the
default scheme. Per-page overhead ("reserved bytes", byte 20 of page 1, which stays in clear):
default/aes*=**12**, rc4=4, and the macOS aes128 variant here observed **0**.

`PRAGMA hexkey='X'` hex-decodes `X` to bytes and (if they start with `scheme:`) splits off the
scheme. So the *value* passed to hexkey is itself hex; e.g. Viber passes
`PRAGMA hexkey='6165733132383a…'` where `6165733132383a` = `"aes128:"`.

## 3. Key derivation (the important part)

The key is **not stored**; Viber derives it at runtime and calls `PRAGMA hexkey`.

Viber (on **both** Linux and macOS) has two candidate keys and tries them in order, using
whichever decrypts:

1. **Main key** — a 64-hex string (default scheme), derived from the profile: the account id +
   `config.db` `DeviceKey`, hashed with SHA-256. It is **uid-independent** (same value for the
   same account regardless of OS user). The exact transform was not fully reversed, so the tool
   **captures** it rather than computing it.
2. **Username key** — `key = "aes128:" + reverse(login-username)`. Deterministic: reverse the
   *entire* login name, character by character, preserving case. Example: login `dmitry` →
   `aes128:yrtimd`; login `j.doe` → `aes128:eod.j`. Hex-encoded and passed to `hexkey`.

**This profile's db was encrypted with the username key, not the main key** — the 64-hex main
key does *not* open it. So on Linux the username key is not just a fallback: it can be the
*primary* key. The export tool therefore computes the username key directly (no runtime capture
needed when you know the login name) and also captures the main key as a fallback. For a foreign
backup the tool must know the *original* login name (`VIBER_USERNAME`).

> **Gotcha — reverse the whole name, in full.** The username key is the *complete* reversal of
> the login name. `dmitry` → `yrtimd` (works). A partial or case-mangled reversal (e.g. `rytmiD`)
> will *not* decrypt — it feeds the wrong bytes to the AES key.

Reverse-engineering notes for the main key (Linux binary): the QString the app hands to
`PRAGMA hexkey='%1'` is built in a helper that does `hexkey = toHex(SHA256(utf8(seed)))`
(Qt `QCryptographicHash::Sha256`, algo id 4); `seed` comes from an `OriginNumber_<id>` lookup
+ the default Account struct. If you need to compute the main key offline, start there.

## 4. Discovering the key at runtime (version-independent)

The tool hooks **`QSqlQuery::exec(const QString&)`** — mangled `_ZN9QSqlQuery4execERK7QString`,
an *exported* Qt symbol, so it survives version changes. The hook is an **LD_PRELOAD interposer**
(`src/preload.c`): it interposes the exported symbol, reads the `QString&` argument (Qt6 layout:
`{ d@0, char16_t* ptr@8, qsizetype size@16 }`), and logs any SQL containing `hexkey` to
`$VIBER_PRELOAD_LOG`. LD_PRELOAD is more reliable than gdb on multithreaded Qt (gdb's
stop/resume races the event loop and can hang a live Viber), and it leaves the live process
running. Correlate with `QSqlDatabase::setDatabaseName`
(`_ZN12QSqlDatabase15setDatabaseNameERK7QString`) to know which db each key is for.

Run Viber **headless** (`QT_QPA_PLATFORM=offscreen`) and **offline** so it never links a device
or syncs — key derivation happens locally during startup, before/independent of sign-in. On Linux
the tool isolates the run with `unshare -U -n --map-users=<owner-uid>:<tool-uid>:1` (plus the
matching `--map-groups`) so the *login username* — and hence the username key — derives correctly
whether the tool is run by the profile owner or by root, and uses a distinct `TMPDIR` to dodge the
`QtSingleApplication` lock (its hash is bound to uid + tempdir).

To run headless you need the **offscreen** platform plugin. The Linux AppImage bundles it;
**macOS Viber ships only `libqcocoa.dylib`**, so the mac tool copies an `libqoffscreen.dylib`
of the *same Qt version* into a throwaway copy of `Viber.app`.

macOS extra: Viber.app is notarized with **hardened runtime**, so lldb can't debug it. The
tool re-signs a *copy* ad-hoc (`codesign -f -s - --deep`) which drops hardened runtime — no
admin needed. (An earlier all-in-one approach used gdb's `setKey` at a hardcoded address
`0x1fac6f0` for Viber 27.3.0.2 Linux — version-specific; the LD_PRELOAD interposer above
replaced it.)

## 5. Decrypting (`src/dump.cpp`)

A tiny Qt program: `QSqlDatabase("QSQLITE")` → `setDatabaseName(enc)` → `open()` →
`PRAGMA hexkey='<key>'` → `ATTACH '<out>' AS pln KEY ''` (empty key = plaintext) →
`CREATE TABLE pln.X AS SELECT * FROM main.X` per table. Compile it against **Qt6 headers**
but **link Viber's own frameworks** at runtime (so the loaded Qt matches the plugin's Qt) and
point `QT_PLUGIN_PATH` at Viber's `sqldrivers`. On Linux, system Qt6 headers + the AppImage's
`libQt6*.so.6` work (they were built with GCC; versions need only be ABI-compatible, e.g.
6.11 headers over 6.10 libs is fine). On macOS, aqtinstall provides matching-version headers.

## 6. Putting data back (`src/encrypt.cpp`)

To write a modified db back into Viber you must re-encrypt with the **target install's** key
and scheme. `encrypt.cpp`: open a fresh db, `PRAGMA hexkey='<key>'` (default scheme → reserved
12), `ATTACH` the plaintext, recreate the schema from the plaintext's `sqlite_master`
(tables first, then data, then indexes/triggers/views — triggers **after** data so they don't
retro-fire), and copy rows. Round-trip verify by decrypting the result with `dump`.

Install: **quit Viber**, back up `~/.ViberPC/<phone>/viber.db`, copy the new encrypted file
over it, and delete any `viber.db-wal`/`-shm`.

## 7. Gotchas

* **Running Viber against a live profile writes a WAL and, on exit, checkpoints changes into
  the main db** — i.e. it *modifies* it. Always run key-capture against a *copy* of the profile
  (the tools do). Verify the source md5 is unchanged afterwards.
* **Viber reprocesses `viber.db` on open** (migrations, re-deriving some events, occasionally
  re-splitting the self/"My Notes" chat). Expect small count changes and don't fight cosmetic
  self-chat duplicates.
* Keys are per-scheme; if `dump` prints `DECRYPT_FAIL … file is not a database`, the key/scheme
  is wrong (not a corrupt file). Capture more keys and try each.

## 8. Merging two installs (reference)

To merge one platform's archive into another install: decrypt both; use the Linux schema as the base;
INSERT all mac rows; then add Linux-only events (those whose `Events.Token` isn't in the mac
set). IDs are install-specific, so remap: `Contact` by `MID`/`Number`; `ChatID`/`ContactID`
for overlapping conversations via same-`Token` event pairs (they give direct linux→mac id
maps); import genuinely new chats/contacts with fresh ids; allocate new `EventID`s above the
base max and repoint child tables (`Messages, Calls, DownloadFile, UploadFile, EventsMetaData,
Reminders, LikeRelation`). Keep `Settings`/`Versions` from the target install. Finally
`dedup-chats.py`, re-encrypt, reinstall. `PRAGMA integrity_check` and check for orphan
messages / duplicate `EventID`/`Token` before installing.
