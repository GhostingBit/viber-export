# viber-common.sh — shared helpers for viber-export / viber-merge. Source this file.
# Provides: vc_platform, vc_prepare, vc_cheap_keys, vc_runtime_keys, vc_dump, vc_encrypt.
# Globals set by vc_prepare: VC_TMP, VC_DUMP, VC_ENCRYPT, and the runtime env is applied by
# vc_dump/vc_encrypt. Never modifies any source db.
set -euo pipefail

vc_platform(){ case "$(uname -s)" in Darwin) echo mac;; Linux) echo linux;; *) echo unknown;; esac; }

_VC_HERE=""   # set by vc_init to the toolkit root (dir containing src/)
vc_init(){ _VC_HERE="$1"; }

# Kill a process and every descendant of it. Deliberately scoped to this subtree only —
# never `pkill -f Viber`, which would also match (and kill) a live Viber instance.
_vc_kill_tree(){
  local pid="$1" c
  for c in $(pgrep -P "$pid" 2>/dev/null); do _vc_kill_tree "$c"; done
  kill -KILL "$pid" 2>/dev/null || true
}

# ---- locate Viber + compile the dump/encrypt harnesses for this platform ----
vc_prepare(){
  local plat; plat="$(vc_platform)"
  VC_TMP="$(mktemp -d)"; trap 'rm -rf "$VC_TMP"' EXIT
  if [ "$plat" = linux ]; then
    for t in g++ gcc pkg-config; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; return 1; }; done
    pkg-config --exists Qt6Sql Qt6Core || { echo "missing Qt6 dev headers (Qt6Sql,Qt6Core)" >&2; return 1; }
    # Pick a Viber install: prefer a system install (VIBER_APP, else /opt/viber) when it has the
    # codec; else fall back to the AppImage (extracted into VC_TMP). One install is used for both
    # the codec (dump/encrypt) and the capture binary (vc_runtime_keys), so they stay consistent.
    local sys="${VIBER_APP:-}"
    [ -z "$sys" ] && [ -x /opt/viber/Viber ] && [ -f /opt/viber/plugins/sqldrivers/libqsqlite.so ] && sys=/opt/viber
    if [ -n "$sys" ] && [ -x "$sys/Viber" ] && [ -f "$sys/plugins/sqldrivers/libqsqlite.so" ]; then
      echo "[*] Viber install: $sys" >&2
      VC_VIBERBIN="$sys/Viber"; VC_RUN_LD="$sys/lib"; VC_RUN_PLUG="$sys/plugins"
    else
      local app="${VIBER_APPIMAGE:-}"
      [ -z "$app" ] && app="$(grep -rhs '^Exec=' ~/.local/share/applications/ 2>/dev/null | grep -i viber | head -1 | sed -E 's/^Exec=//; s/ .*//')"
      [ -z "$app" ] && app="$(ls "$HOME"/Applications/viber*.[aA]pp[iI]mage 2>/dev/null | head -1 || true)"
      [ -n "$app" ] && [ -x "$app" ] || { echo "no Viber install found; set VIBER_APP or VIBER_APPIMAGE=/path" >&2; return 1; }
      echo "[*] Viber AppImage: $app" >&2
      ( cd "$VC_TMP" && "$app" --appimage-extract >/dev/null 2>&1 )
      [ -x "$VC_TMP/squashfs-root/usr/bin/Viber" ] || { echo "extract failed" >&2; return 1; }
      VC_VIBERBIN="$VC_TMP/squashfs-root/usr/bin/Viber"; VC_RUN_LD="$VC_TMP/squashfs-root/usr/lib"; VC_RUN_PLUG="$VC_TMP/squashfs-root/usr/plugins"
    fi
    echo "[*] compiling harnesses..." >&2
    g++ -O2 -std=c++17 "$_VC_HERE/src/dump.cpp"    -o "$VC_TMP/dump"    $(pkg-config --cflags Qt6Sql Qt6Core) "$VC_RUN_LD/libQt6Sql.so.6" "$VC_RUN_LD/libQt6Core.so.6" -Wl,-rpath,"$VC_RUN_LD"
    g++ -O2 -std=c++17 "$_VC_HERE/src/encrypt.cpp" -o "$VC_TMP/encrypt" $(pkg-config --cflags Qt6Sql Qt6Core) "$VC_RUN_LD/libQt6Sql.so.6" "$VC_RUN_LD/libQt6Core.so.6" -Wl,-rpath,"$VC_RUN_LD"
    gcc -O2 -fPIC -shared "$_VC_HERE/src/preload.c" -o "$VC_TMP/preload.so" -ldl
    VC_PRELOAD="$VC_TMP/preload.so"
  else # mac
    command -v clang++ >/dev/null || { echo "need Xcode CLT: xcode-select --install" >&2; return 1; }
    local app="${VIBER_APP:-}"
    for c in "$app" /Applications/Viber.app "$HOME/Applications/Viber.app"; do [ -d "${c:-/nx}/Contents/PlugIns/sqldrivers" ] && app="$c" && break; done
    [ -n "$app" ] && [ -d "$app/Contents/PlugIns/sqldrivers" ] || { echo "Viber.app not found; set VIBER_APP=/path" >&2; return 1; }
    echo "[*] Viber.app: $app" >&2
    VC_FW="$app/Contents/Frameworks"; VC_PLUG="$app/Contents/PlugIns"; VC_APP="$app"
    local qver inc; qver="$(defaults read "$VC_FW/QtCore.framework/Resources/Info" CFBundleShortVersionString 2>/dev/null || echo 6.10.1)"
    inc=""; local fwstyle=1
    [ -n "${QT_DIR:-}" ] && [ -d "$QT_DIR/lib/QtCore.framework/Headers" ] && inc="$QT_DIR/lib"
    if [ -z "$inc" ] && command -v brew >/dev/null && [ -d "$(brew --prefix qt6 2>/dev/null)/include" ]; then inc="$(brew --prefix qt6)/include"; fwstyle=0; fi
    if [ -z "$inc" ]; then
      echo "[*] fetching Qt $qver headers via aqtinstall..." >&2
      python3 -m pip install --user --quiet aqtinstall 2>/dev/null || true
      python3 -m aqt install-qt mac desktop "$qver" clang_64 --archives qtbase --outputdir "$HOME/Qt" >/dev/null 2>&1 || { echo "aqt failed; set QT_DIR" >&2; return 1; }
      inc="$HOME/Qt/$qver/macos/lib"
    fi
    VC_QTINC="$inc"; VC_QVER="$qver"
    local hflags
    if [ "$fwstyle" = 1 ]; then hflags=(-iframework "$inc" -I "$inc/QtCore.framework/Headers" -I "$inc/QtSql.framework/Headers"); else hflags=(-I "$inc" -I "$inc/QtCore" -I "$inc/QtSql"); fi
    echo "[*] compiling harnesses..." >&2
    clang++ -std=c++17 -O2 "$_VC_HERE/src/dump.cpp"    -o "$VC_TMP/dump"    "${hflags[@]}" "$VC_FW/QtCore.framework/QtCore" "$VC_FW/QtSql.framework/QtSql" -Wl,-rpath,"$VC_FW"
    clang++ -std=c++17 -O2 "$_VC_HERE/src/encrypt.cpp" -o "$VC_TMP/encrypt" "${hflags[@]}" "$VC_FW/QtCore.framework/QtCore" "$VC_FW/QtSql.framework/QtSql" -Wl,-rpath,"$VC_FW"
  fi
  VC_DUMP="$VC_TMP/dump"; VC_ENCRYPT="$VC_TMP/encrypt"
}

vc_dump(){    # <enc-db> <key> <out-db>  -> 0 on success
  local plat; plat="$(vc_platform)"
  if [ "$plat" = linux ]; then LD_LIBRARY_PATH="$VC_RUN_LD" QT_PLUGIN_PATH="$VC_RUN_PLUG" QT_QPA_PLATFORM=offscreen "$VC_DUMP" "$1" "$2" "$3" 2>/dev/null | grep -q '^OK:'
  else QT_PLUGIN_PATH="$VC_PLUG" DYLD_FRAMEWORK_PATH="$VC_FW" "$VC_DUMP" "$1" "$2" "$3" 2>/dev/null | grep -q '^OK:'; fi
}
vc_encrypt(){ # <plain-db> <key> <out-db> -> 0 on success
  local plat; plat="$(vc_platform)"
  if [ "$plat" = linux ]; then LD_LIBRARY_PATH="$VC_RUN_LD" QT_PLUGIN_PATH="$VC_RUN_PLUG" QT_QPA_PLATFORM=offscreen "$VC_ENCRYPT" "$1" "$2" "$3" 2>/dev/null | grep -q 'ENCRYPTED'
  else QT_PLUGIN_PATH="$VC_PLUG" DYLD_FRAMEWORK_PATH="$VC_FW" "$VC_ENCRYPT" "$1" "$2" "$3" 2>/dev/null | grep -q 'ENCRYPTED'; fi
}

vc_cheap_keys(){ # echoes cheap candidate keys (no Viber run).
  # Both macOS and Linux accept the username-based key: "aes128:" + reverse(login-username).
  # (Linux tries a profile-derived 64-hex key first, then this one; many profiles are
  #  actually encrypted with THIS key, so it is the reliable first guess.)
  local u; u="${VIBER_USERNAME:-${USER:-$(id -un 2>/dev/null || true)}}"
  [ -n "$u" ] || return 0
  printf '%s' "aes128:$(printf '%s' "$u" | rev)" | xxd -p | tr -d '\n'; echo
}

# run Viber headless+offline against a COPY of the profile and echo captured hexkeys (expensive)
vc_runtime_keys(){ # <viberpc-dir> <viber-db>
  local VPC="$1" IN="$2" plat; plat="$(vc_platform)"
  local phone; phone="$(basename "$(dirname "$IN")")"
  local klog="$VC_TMP/keys.$$"; : > "$klog"
  if [ "$plat" = linux ]; then
    local home="$VC_TMP/home"; mkdir -p "$home/tmp" "$home/run" "$home/.ViberPC/$phone"
    cp -a "$VPC/config.db" "$home/.ViberPC/" 2>/dev/null || true
    cp -a "$VPC/data" "$home/.ViberPC/" 2>/dev/null || true
    cp -a "$IN" "$home/.ViberPC/$phone/viber.db"
    for f in data.db data.db-wal data.db-shm; do cp -a "$(dirname "$IN")/$f" "$home/.ViberPC/$phone/" 2>/dev/null || true; done
    # Run the real Viber offline (user+net namespace) as the profile owner, with the LD_PRELOAD
    # interposer logging the PRAGMA hexkey it issues. No debugger needed — the interposer hooks a
    # single exported Qt symbol, so it is stable across Viber/Qt versions (gdb is not, on a
    # multithreaded Qt app). We map our own outside uid to the owner's uid so the username-based
    # key is derived correctly whether the tool is run by the owner or by root; an isolated TMPDIR
    # keeps the QtSingleApplication lock (bound to uid+tempdir) from clashing with a live instance.
    local uid user myuid
    uid="$(stat -c %u "$IN" 2>/dev/null || id -u)"
    user="${VIBER_USERNAME:-$(stat -c %U "$IN" 2>/dev/null || id -un)}"
    myuid="$(id -u)"
    unshare -U -n --map-users="$uid:$myuid:1" --map-groups="$uid:$myuid:1" env -i \
      PATH=/usr/bin:/bin TERM=xterm LANG=C.UTF-8 \
      HOME="$home" USER="$user" LOGNAME="$user" \
      TMPDIR="$home/tmp" XDG_RUNTIME_DIR="$home/run" \
      QT_QPA_PLATFORM=offscreen \
      LD_LIBRARY_PATH="$VC_RUN_LD" QT_PLUGIN_PATH="$VC_RUN_PLUG" \
      QTWEBENGINE_DISABLE_SANDBOX=1 \
      LD_PRELOAD="$VC_PRELOAD" VIBER_PRELOAD_LOG="$klog" \
      "$VC_VIBERBIN" --no-sandbox --disable-gpu >/dev/null 2>&1 &
    local bg=$! i
    for i in $(seq 1 30); do sleep 2; if grep -q hexkey "$klog" 2>/dev/null; then break; fi; if ! kill -0 "$bg" 2>/dev/null; then break; fi; done
    _vc_kill_tree "$bg"
  else # mac
    local home="$VC_TMP/home"; mkdir -p "$home/Library/Application Support/ViberPC/$phone"
    cp -a "$VPC/config.db" "$home/Library/Application Support/ViberPC/" 2>/dev/null || true
    cp -a "$VPC/data" "$home/Library/Application Support/ViberPC/" 2>/dev/null || true
    cp -a "$IN" "$home/Library/Application Support/ViberPC/$phone/viber.db"
    local wapp="$VC_TMP/Viber.app"; cp -R "$VC_APP" "$wapp"
    local offs="$VC_QTINC/../plugins/platforms/libqoffscreen.dylib"
    [ -f "$offs" ] && { cp "$offs" "$wapp/Contents/PlugIns/platforms/"; codesign -f -s - "$wapp/Contents/PlugIns/platforms/libqoffscreen.dylib" 2>/dev/null || true; }
    codesign -f -s - --deep "$wapp" 2>/dev/null || true
    cat > "$VC_TMP/cap.py" <<PY
import lldb
LOG=open("$klog","a")
def rq(p,a):
    e=lldb.SBError(); ptr=int.from_bytes(p.ReadMemory(a+8,8,e),"little"); n=int.from_bytes(p.ReadMemory(a+16,8,e),"little")
    return p.ReadMemory(ptr,n*2,e).decode("utf-16-le","replace") if (0<n<8192 and ptr) else ""
def onexec(f,l,d):
    s=rq(f.thread.process,f.FindRegister("x1").GetValueAsUnsigned())
    if "hexkey" in s: LOG.write(s+"\n"); LOG.flush()
    return False
PY
    cat > "$VC_TMP/run.lldb" <<LL
command script import $VC_TMP/cap.py
settings set target.env-vars HOME=$home QT_QPA_PLATFORM=offscreen
br set -n _ZN9QSqlQuery4execERK7QString
br command add -F cap.onexec 1
run
LL
    lldb -b -s "$VC_TMP/run.lldb" "$wapp/Contents/MacOS/Viber" >/dev/null 2>&1 &
    local lp=$!; for i in $(seq 1 24); do sleep 5; grep -q hexkey "$klog" 2>/dev/null && break; done
    kill $lp 2>/dev/null || true; pkill -9 -f "$wapp/Contents/MacOS/Viber" 2>/dev/null || true
  fi
  sed -E "s/.*hexkey='([^']*)'.*/\1/" "$klog" 2>/dev/null | awk 'NF' | awk '!seen[$0]++'
}

# high-level: find a working key for <viber-db> in <viberpc-dir>, echo it, or return 1
vc_find_key(){ # <viberpc-dir> <viber-db>
  local VPC="$1" IN="$2" k
  while read -r k; do [ -n "$k" ] && vc_dump "$IN" "$k" "$VC_TMP/_probe.db" && { echo "$k"; rm -f "$VC_TMP/_probe.db"*; return 0; }; done < <(vc_cheap_keys)
  while read -r k; do [ -n "$k" ] && vc_dump "$IN" "$k" "$VC_TMP/_probe.db" && { echo "$k"; rm -f "$VC_TMP/_probe.db"*; return 0; }; done < <(vc_runtime_keys "$VPC" "$IN")
  return 1
}
