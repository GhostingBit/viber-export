# viber-common.sh — shared helpers for viber-export / viber-merge. Source this file.
# Provides: vc_platform, vc_prepare, vc_cheap_keys, vc_runtime_keys, vc_dump, vc_encrypt.
# Globals set by vc_prepare: VC_TMP, VC_DUMP, VC_ENCRYPT, and the runtime env is applied by
# vc_dump/vc_encrypt. Never modifies any source db.
set -euo pipefail

vc_platform(){ case "$(uname -s)" in Darwin) echo mac;; Linux) echo linux;; *) echo unknown;; esac; }

_VC_HERE=""   # set by vc_init to the toolkit root (dir containing src/)
vc_init(){ _VC_HERE="$1"; }

# ---- locate Viber + compile the dump/encrypt harnesses for this platform ----
vc_prepare(){
  local plat; plat="$(vc_platform)"
  VC_TMP="$(mktemp -d)"; trap 'rm -rf "$VC_TMP"' EXIT
  if [ "$plat" = linux ]; then
    for t in g++ pkg-config; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; return 1; }; done
    pkg-config --exists Qt6Sql Qt6Core || { echo "missing Qt6 dev headers (Qt6Sql,Qt6Core)" >&2; return 1; }
    local app="${VIBER_APPIMAGE:-}"
    [ -z "$app" ] && app="$(grep -rhs '^Exec=' ~/.local/share/applications/ 2>/dev/null | grep -i viber | head -1 | sed -E 's/^Exec=//; s/ .*//')"
    [ -z "$app" ] && app="$(ls "$HOME"/Applications/viber*.[aA]pp[iI]mage 2>/dev/null | head -1 || true)"
    [ -n "$app" ] && [ -x "$app" ] || { echo "Viber AppImage not found; set VIBER_APPIMAGE=/path" >&2; return 1; }
    echo "[*] Viber AppImage: $app" >&2
    ( cd "$VC_TMP" && "$app" --appimage-extract >/dev/null 2>&1 )
    VC_SR="$VC_TMP/squashfs-root"; [ -x "$VC_SR/usr/bin/Viber" ] || { echo "extract failed" >&2; return 1; }
    echo "[*] compiling harnesses..." >&2
    g++ -O2 -std=c++17 "$_VC_HERE/src/dump.cpp"    -o "$VC_TMP/dump"    $(pkg-config --cflags Qt6Sql Qt6Core) "$VC_SR/usr/lib/libQt6Sql.so.6" "$VC_SR/usr/lib/libQt6Core.so.6" -Wl,-rpath,"$VC_SR/usr/lib"
    g++ -O2 -std=c++17 "$_VC_HERE/src/encrypt.cpp" -o "$VC_TMP/encrypt" $(pkg-config --cflags Qt6Sql Qt6Core) "$VC_SR/usr/lib/libQt6Sql.so.6" "$VC_SR/usr/lib/libQt6Core.so.6" -Wl,-rpath,"$VC_SR/usr/lib"
    VC_RUN_LD="$VC_SR/usr/lib"; VC_RUN_PLUG="$VC_SR/usr/plugins"; VC_VIBERBIN="$VC_SR/usr/bin/Viber"
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

vc_cheap_keys(){ # echoes cheap candidate keys (no Viber run). macOS: aes128:reverse(username)
  if [ "$(vc_platform)" = mac ]; then
    local u; u="${VIBER_USERNAME:-$USER}"; printf '%s' "aes128:$(printf '%s' "$u" | rev)" | xxd -p | tr -d '\n'; echo
  fi
}

# run Viber headless+offline against a COPY of the profile and echo captured hexkeys (expensive)
vc_runtime_keys(){ # <viberpc-dir> <viber-db>
  local VPC="$1" IN="$2" plat; plat="$(vc_platform)"
  local phone; phone="$(basename "$(dirname "$IN")")"
  local klog="$VC_TMP/keys.$$"; : > "$klog"
  if [ "$plat" = linux ]; then
    local home="$VC_TMP/home"; mkdir -p "$home/run" "$home/.ViberPC/$phone"
    cp -a "$VPC/config.db" "$home/.ViberPC/" 2>/dev/null || true
    cp -a "$VPC/data" "$home/.ViberPC/" 2>/dev/null || true
    cp -a "$IN" "$home/.ViberPC/$phone/viber.db"
    for f in data.db data.db-wal data.db-shm; do cp -a "$(dirname "$IN")/$f" "$home/.ViberPC/$phone/" 2>/dev/null || true; done
    cat > "$VC_TMP/cap.py" <<PY
import gdb
LOG=open("$klog","a"); st={'db':''}
def qs(a):
    i=gdb.selected_inferior(); p=int.from_bytes(i.read_memory(a+8,8),'little'); n=int.from_bytes(i.read_memory(a+16,8),'little')
    return bytes(i.read_memory(p,n*2)).decode('utf-16-le','replace') if (0<n<8192 and p) else ''
def onexec():
    s=qs(int(gdb.selected_frame().read_register('rsi')))
    if 'hexkey' in s: LOG.write(s+"\n"); LOG.flush()
    gdb.execute('continue')
PY
    cat > "$VC_TMP/g.gdb" <<GDB
set pagination off
set confirm off
set breakpoint pending on
set environment HOME=$home
set environment QT_QPA_PLATFORM=offscreen
set environment LD_LIBRARY_PATH=$VC_SR/usr/lib:$VC_SR/usr/lib/qt6
set environment QT_PLUGIN_PATH=$VC_SR/usr/plugins
set environment XDG_RUNTIME_DIR=$home/run
set environment QTWEBENGINE_DISABLE_SANDBOX=1
handle SIGSEGV nostop noprint pass
handle SIGPIPE nostop noprint pass
source $VC_TMP/cap.py
break QSqlQuery::exec(QString const&)
commands
 silent
 python onexec()
end
run --no-sandbox --disable-gpu
GDB
    ( timeout 130 unshare -rn env -i PATH=/usr/bin:/bin HOME="$home" TERM=xterm gdb -batch -x "$VC_TMP/g.gdb" "$VC_VIBERBIN" >/dev/null 2>&1 ) &
    local bg=$!; for i in $(seq 1 26); do sleep 5; grep -q hexkey "$klog" 2>/dev/null && break; done
    kill $bg 2>/dev/null || true; pkill -9 -f "$VC_VIBERBIN" 2>/dev/null || true
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
