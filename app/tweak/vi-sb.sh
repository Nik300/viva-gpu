#!/var/jb/bin/sh
# VivaIsland, phone side (installed by app/install.sh at /var/jb/usr/libexec/vi-sb.sh, run as root through vivad):
#   vi-sb.sh install   SpringBoard <- /private/var/mobile/SpringBoard.patched (made on the Mac by tweak/inject.sh);
#                      the first time the original is kept as SpringBoard.orig next to it. Restarts SpringBoard.
#   vi-sb.sh restore   SpringBoard <- SpringBoard.orig (the stock binary). Restarts SpringBoard.
#   vi-sb.sh off|on    move VivaIsland.dylib aside / back (the weak load command then finds nothing). Restarts SpringBoard.
#   vi-sb.sh guard     clear the crash guard (system island path disabled after repeated crashes)
#   vi-sb.sh status
# vivad runs one command per line with a bare PATH: everything here uses full paths.
PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH
DIR=/System/Library/CoreServices/SpringBoard.app
SB=$DIR/SpringBoard
ORIG=$DIR/SpringBoard.orig
PATCHED=/private/var/mobile/SpringBoard.patched
DYLIB=/var/jb/usr/lib/VivaIsland.dylib
GUARD=/var/mobile/Library/Caches/VivaIsland/pending

fail() { echo "vi-sb: $*" >&2; exit 1; }

respring() {
  killall -9 SpringBoard 2>/dev/null && echo "SpringBoard restarted" || echo "SpringBoard was not running"
}

writable() {   # the root filesystem is mounted rw on viva; try once if it is not
  touch "$DIR/.vi-sb-test" 2>/dev/null && rm -f "$DIR/.vi-sb-test" && return 0
  mount -uw / 2>/dev/null
  touch "$DIR/.vi-sb-test" 2>/dev/null && rm -f "$DIR/.vi-sb-test" || fail "$DIR is not writable"
}

replace_sb() {   # $1 = source; atomic rename inside the bundle
  cp "$1" "$SB.new" || fail "copy $1"
  chown root:wheel "$SB.new" && chmod 755 "$SB.new" || fail "chown/chmod"
  mv -f "$SB.new" "$SB" || fail "rename"
}

case "${1:-status}" in
install)
  [ -f "$PATCHED" ] || fail "$PATCHED missing (push it first)"
  grep -q -a "$DYLIB" "$PATCHED" || fail "$PATCHED has no load command for $DYLIB"
  [ -f "$DYLIB" ] || echo "warning: $DYLIB missing (SpringBoard starts anyway: weak load)"
  writable
  if [ ! -f "$ORIG" ]; then
    grep -q -a "$DYLIB" "$SB" && fail "$SB is already patched and there is no $ORIG: refusing to lose the original"
    cp -p "$SB" "$ORIG" || fail "backup"
    echo "original kept as $ORIG"
  fi
  replace_sb "$PATCHED"
  rm -f "$PATCHED"
  ls -l "$SB" "$ORIG"
  respring
  ;;
restore)
  [ -f "$ORIG" ] || fail "$ORIG missing"
  writable
  replace_sb "$ORIG"
  ls -l "$SB" "$ORIG"
  respring
  ;;
off)
  [ -f "$DYLIB" ] && mv -f "$DYLIB" "$DYLIB.off"
  ls -l "$DYLIB"* 2>/dev/null
  respring
  ;;
on)
  [ -f "$DYLIB.off" ] && mv -f "$DYLIB.off" "$DYLIB"
  ls -l "$DYLIB"* 2>/dev/null
  respring
  ;;
guard)
  rm -f "$GUARD" && echo "crash guard cleared"
  ;;
status)
  ls -l "$SB" "$ORIG" "$DYLIB" "$DYLIB.off" 2>/dev/null
  if grep -q -a "$DYLIB" "$SB"; then echo "SpringBoard: patched"; else echo "SpringBoard: stock"; fi
  [ -f "$GUARD" ] && echo "crash guard: $(cat "$GUARD")"
  echo "kern.viva_linkstate: $(sysctl -n kern.viva_linkstate 2>/dev/null || echo missing)"
  ;;
*)
  fail "usage: vi-sb.sh install|restore|off|on|guard|status"
  ;;
esac
