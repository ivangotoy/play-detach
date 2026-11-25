#!/bin/sh
# Play Detach - tests. Dependency-free POSIX sh: sh tests/run.sh
#
# Runs the declared syntax checks and drives the real module scripts (the
# play-detach command, service.sh, customize.sh) with stub Android commands
# on PATH and a fake data folder (PD_DATA_DIR, PD_STORAGE, PD_TERMUX_BIN).
# Checks that need bash, node, python3, git or unzip are skipped when the tool
# is missing. Not part of the module zip (build.sh packs module/ only).
#
#   TMPDIR         where the scratch folder is made (default /tmp)
#   PD_TEST_STUBS  folder for the stub commands (default: inside the scratch folder)
#   PD_TEST_KEEP   set to keep the scratch folder for a look afterwards

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SH=${SH:-sh}
export LC_ALL=C
unset PD_BB PD_DATA_DIR PD_STORAGE PD_TERMUX_BIN

WORK=$(mktemp -d "${TMPDIR:-/tmp}/play-detach-test.XXXXXX") || exit 2
STUBS=${PD_TEST_STUBS:-$WORK/stubs}
mkdir -p "$STUBS" || exit 2
[ -n "$PD_TEST_KEEP" ] || trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' INT TERM HUP

pass=0
fail=0
skip=0
ok() {
    pass=$((pass + 1))
    echo "ok   $1"
}
no() {
    fail=$((fail + 1))
    echo "FAIL $1"
}
skipped() {
    skip=$((skip + 1))
    echo "skip $1"
}
check() {
    name=$1
    shift
    if "$@"; then ok "$name"; else no "$name"; fi
}
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Declared checks
# ---------------------------------------------------------------------------

for f in module/play-detach module/customize.sh module/post-fs-data.sh module/service.sh \
    module/uninstall.sh module/META-INF/com/google/android/update-binary; do
    check "sh -n $f" "$SH" -n "$ROOT/$f"
done
for f in build.sh .forgejo/module-ci.sh tests/release.sh; do
    if have bash; then check "bash -n $f" bash -n "$ROOT/$f"; else skipped "bash -n $f (no bash)"; fi
done
for f in "$ROOT"/module/webroot/*.js; do
    if have node; then check "node --check ${f#"$ROOT"/}" node --check "$f"; else skipped "node --check ${f#"$ROOT"/} (no node)"; fi
done
if have python3; then
    for f in update.json .forgejo/update.json; do
        check "json $f" python3 -I -c 'import json,sys;json.load(open(sys.argv[1]))' "$ROOT/$f"
    done
    if python3 -I -c 'import yaml' 2>/dev/null; then
        check "yaml .forgejo/workflows/module-release.yml" python3 -I -c 'import sys,yaml;yaml.safe_load(open(sys.argv[1]))' \
            "$ROOT/.forgejo/workflows/module-release.yml"
    else
        skipped "yaml .forgejo/workflows/module-release.yml (no python3 yaml)"
    fi
else
    skipped "json and yaml checks (no python3)"
fi

# ---------------------------------------------------------------------------
# Stub Android commands. Each call is logged to $WORK/calls.log.
# ---------------------------------------------------------------------------

stub() {
    {
        echo '#!/bin/sh'
        echo "echo \"$1 \$*\" >>\"$WORK/calls.log\""
        cat
    } >"$STUBS/$1"
    chmod 755 "$STUBS/$1"
}
stub id <<'EOF'
[ "$1" = -u ] && echo 0 || echo "uid=0(root) gid=0(root)"
EOF
for c in am cmd su magisk settings logcat getevent; do stub "$c" </dev/null; done
stub pidof <<'EOF'
exit 1
EOF
stub getprop <<'EOF'
[ "$1" = sys.boot_completed ] && echo 1
exit 0
EOF
stub dumpsys <<'EOF'
echo "    versionCode=84021 minSdk=29 targetSdk=35"
echo "    versionName=44.1.20-31"
EOF
# pm list packages -3 -i prints the lines of $PD_TEST_PM
# (PD_TEST_PM_FAIL: then it exits 1, as a pm cut off after part of its list)
stub pm <<'EOF'
[ -f "$PD_TEST_PM" ] && cat "$PD_TEST_PM"
[ -z "$PD_TEST_PM_FAIL" ] || exit 1
exit 0
EOF
# busybox --list / busybox inotifyd for service.sh: one /data/app event, then
# a harmless event every second while the fake module folder exists
stub busybox <<'EOF'
case "$1" in
    --list) echo inotifyd ;;
    inotifyd)
        # PD_TEST_INOTIFYD_DIES: an inotifyd that exits at once (no events)
        if [ -n "$PD_TEST_INOTIFYD_DIES" ]; then
            echo start >>"$PD_TEST_INOTIFYD_DIES"
            exit 1
        fi
        d=${4%:*}
        printf 'n\t/data/app\tcom.example.app\n'
        i=0
        while [ -d "$PD_TEST_MOD" ] && [ $i -lt 60 ]; do
            sleep 1
            printf 'y\t%s\tother\n' "$d"
            i=$((i + 1))
        done
        ;;
    *) exit 1 ;;
esac
EOF

# rm, rmdir and sort that can stop at a chosen moment, to stage a race:
# while <flag>.wait exists they wait (at most 30 s) after writing their pid
# to <flag>.reached. rm stops only for the path in PD_TEST_RM_BLOCK (flag
# PD_TEST_RM_FLAG), rmdir only for PD_TEST_RMDIR_BLOCK (PD_TEST_RMDIR_FLAG),
# sort only when PD_TEST_SORT_FLAG is set.
REAL_RM=$(command -v rm)
REAL_RMDIR=$(command -v rmdir)
REAL_SORT=$(command -v sort)
hold() { printf 'echo $$ >"$1.reached"; i=0; while [ -e "$1.wait" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done\n'; }
{
    echo '#!/bin/sh'
    echo 'if [ -n "$PD_TEST_RM_BLOCK" ]; then for a; do [ "$a" = "$PD_TEST_RM_BLOCK" ] && {'
    hold | sed 's/\$1/$PD_TEST_RM_FLAG/g'
    echo 'break; }; done; fi'
    # PD_TEST_RM_REPLANT: after removing that path (or its name), a link to
    # PD_TEST_RM_LINK is put there again, as a racing owner of the folder could
    echo 'if [ -n "$PD_TEST_RM_REPLANT" ]; then for a; do if [ "$a" = "$PD_TEST_RM_REPLANT" ] || [ "$a" = "${PD_TEST_RM_REPLANT##*/}" ]; then'
    echo "    $REAL_RM \"\$@\"; ln -s \"\$PD_TEST_RM_LINK\" \"\$PD_TEST_RM_REPLANT\"; exit 0"
    echo 'fi; done; fi'
    echo "exec $REAL_RM \"\$@\""
} >"$STUBS/rm"
{
    echo '#!/bin/sh'
    echo 'if [ -n "$PD_TEST_RMDIR_BLOCK" ]; then for a; do [ "$a" = "$PD_TEST_RMDIR_BLOCK" ] && {'
    hold | sed 's/\$1/$PD_TEST_RMDIR_FLAG/g'
    echo 'break; }; done; fi'
    echo "exec $REAL_RMDIR \"\$@\""
} >"$STUBS/rmdir"
# mkdir that, once the installer's staging folder is made, moves it to
# PD_TEST_MKDIR_TO and leaves a link to it, as a racing owner of the folder could
REAL_MKDIR=$(command -v mkdir)
cat >"$STUBS/mkdir" <<EOF
#!/bin/sh
if [ -n "\$PD_TEST_MKDIR_TO" ]; then
    for a; do case "\${a##*/}" in .play-detach-install.*)
        $REAL_MKDIR "\$@" && mv "\$a" "\$PD_TEST_MKDIR_TO" && ln -s "\$PD_TEST_MKDIR_TO" "\$a"; exit; esac; done
fi
# PD_TEST_STAGE_TO: the same for the shared-storage staging folders
if [ -n "\$PD_TEST_STAGE_TO" ]; then
    for a; do case "\${a##*/}" in .play-detach-backup.* | .play-detach-folder.*)
        $REAL_MKDIR "\$@" && mv "\$a" "\$PD_TEST_STAGE_TO" && ln -s "\$PD_TEST_STAGE_TO" "\$a"; exit; esac; done
fi
exec $REAL_MKDIR "\$@"
EOF
chmod 755 "$STUBS/mkdir"
# chmod that swaps the file PD_TEST_CHMOD_SWAP for a link to
# PD_TEST_CHMOD_TO right before changing its mode
REAL_CHMOD=$(command -v chmod)
cat >"$STUBS/chmod" <<EOF
#!/bin/sh
if [ -n "\$PD_TEST_CHMOD_SWAP" ]; then
    for a; do [ "\$a" = "\$PD_TEST_CHMOD_SWAP" ] && $REAL_RM -rf "\$a" && ln -s "\$PD_TEST_CHMOD_TO" "\$a"; done
fi
exec $REAL_CHMOD "\$@"
EOF
{
    echo '#!/bin/sh'
    # PD_TEST_SORT_FAIL: a sort that fails (killed, no memory) with no output
    echo '[ -n "$PD_TEST_SORT_FAIL" ] && { cat >/dev/null; exit 1; }'
    echo 'if [ -n "$PD_TEST_SORT_FLAG" ]; then'
    hold | sed 's/\$1/$PD_TEST_SORT_FLAG/g'
    echo 'fi'
    echo "exec $REAL_SORT \"\$@\""
} >"$STUBS/sort"
# mv that, with PD_TEST_MV_LOG set, logs the full real path of its source
# (the folder it is in with links resolved)
REAL_MV=$(command -v mv)
cat >"$STUBS/mv" <<EOF
#!/bin/sh
if [ -n "\$PD_TEST_MV_LOG" ]; then
    src= prev=
    for a; do src=\$prev; prev=\$a; done
    case "\$src" in /*) ;; *) src="\$(pwd -P)/\$src" ;; esac
    src="\$(cd -P "\${src%/*}" 2>/dev/null && pwd -P)/\${src##*/}"
    echo "\$src" >>"\$PD_TEST_MV_LOG"
fi
exec $REAL_MV "\$@"
EOF
chmod 755 "$STUBS/rm" "$STUBS/rmdir" "$STUBS/sort" "$STUBS/chmod" "$STUBS/mv"

# failing <folder> <command> [first argument [status]]: $STUBS/<folder>/<command>
# ends at once with status 1 (or the one given; grep: 2) and no output (a
# killed or broken stage of a pipe), for every call or only for calls with
# that first argument; other calls run the real command. Put the folder on
# PATH for one command: PATH="$STUBS/<folder>:$PATH" pd ...
failing() {
    mkdir -p "$STUBS/$1"
    printf '#!/bin/sh\nif [ -z "%s" ] || [ "$1" = "%s" ]; then exit %s; fi\nexec %s "$@"\n' \
        "$3" "$3" "${4:-1}" "$(command -v "$2")" >"$STUBS/$1/$2"
    "$REAL_CHMOD" 755 "$STUBS/$1/$2"
}

# A fresh fake phone for one test case
fresh() {
    C=$WORK/case
    rm -rf "$C"
    mkdir -p "$C/data" "$C/storage/Download" "$C/storage/Play-Detach"
    : >"$WORK/calls.log"
    PD_DATA_DIR=$C/data
    PD_STORAGE=$C/storage
    PD_TEST_PM=$C/pm.txt
    export PD_DATA_DIR PD_STORAGE PD_TEST_PM
}

# Runs the play-detach command; output in $C/out, error output in $C/err
pd() {
    PATH="$STUBS:$PATH" PD_BB=1 "$SH" "$ROOT/module/play-detach" "$@" >"$C/out" 2>"$C/err"
}
list_is() {
    [ "$(cat "$PD_DATA_DIR/detach.list" 2>/dev/null)" = "$1" ]
}
out_has() { grep -qF -- "$1" "$C/out"; }
err_has() { grep -qF -- "$1" "$C/err"; }
not() { ! "$@"; }

# service.sh with an inotifyd that exits at once: the watcher must still
# scan (it falls back to the 3 s check). Started here and checked at the end,
# because its first wait is the 30 s boot delay.
DEAD=$WORK/dead
mkdir -p "$DEAD/mod" "$DEAD/data"
cp "$ROOT/module/service.sh" "$DEAD/mod/service.sh"
printf '#!/bin/sh\necho "$1" >>"%s"\n' "$DEAD/cli.log" >"$DEAD/mod/play-detach"
chmod 755 "$DEAD/mod/play-detach"
PATH="$STUBS:$PATH" PD_DATA_DIR=$DEAD/data PD_TEST_INOTIFYD_DIES=$DEAD/starts PD_TEST_MOD=$DEAD/mod \
    "$SH" "$DEAD/mod/service.sh" </dev/null >/dev/null 2>&1
DEAD_START=$(date +%s)

# ---------------------------------------------------------------------------
# play-detach command
# ---------------------------------------------------------------------------

fresh
pd history
check "history: no history yet is not an error" [ $? = 0 ]
check "history: no history yet prints nothing" [ ! -s "$C/out" ]
pd add com.example.two com.example.app
check "add: exit 0" [ $? = 0 ]
check "add: list sorted" list_is "com.example.app
com.example.two"
check "add: list mode 600" [ "$(stat -c %a "$PD_DATA_DIR/detach.list")" = 600 ]
check "add: history logged" [ "$(grep -c ' detach user com.example.' "$PD_DATA_DIR/history.log")" = 2 ]
check "add: Play Store restarted" grep -q '^am force-stop com.android.vending' "$WORK/calls.log"
check "add: automatic backup" [ -s "$PD_STORAGE/Play-Detach/play-detach-auto.txt" ]
pd list
check "list: prints the list" [ "$(cat "$C/out")" = "com.example.app
com.example.two" ]

for bad in "../x" "com.example;touch $C/pwned" ".com.example" "com..example" "com example" ""; do
    pd add "$bad"
    check "add rejects '$bad'" [ $? = 1 ]
done
check "add: rejected names leave the list" list_is "com.example.app
com.example.two"
check "add: no command ran from a name" [ ! -e "$C/pwned" ]

pd remove com.example.two
check "remove: exit 0" [ $? = 0 ]
check "remove: list" list_is "com.example.app"
check "remove: history" grep -q ' reattach user com.example.two$' "$PD_DATA_DIR/history.log"
pd set com.example.b com.example.a
check "set: replaces the list" list_is "com.example.a
com.example.b"
pd clear
check "clear: empty list" list_is ""
check "clear: automatic backup kept" grep -qx com.example.b "$PD_STORAGE/Play-Detach/play-detach-auto.txt"
pd history 3
check "history: last lines" [ "$(wc -l <"$C/out")" = 3 ]
pd frobnicate
check "unknown command: exit 1" [ $? = 1 ]

# Two commands waiting on a stale list lock (left by a killed command):
# only one may take it over. B stops right before removing the stale lock;
# A takes the lock over and stops while holding it; then B goes on. B must
# not remove A's lock, so neither change is lost.
fresh
L=$PD_DATA_DIR/list.lock
mkdir "$L"
touch -t 200001010000 "$L"
: >"$C/b.wait"
: >"$C/a.wait"
PATH="$STUBS:$PATH" PD_BB=1 PD_TEST_RM_BLOCK=$L PD_TEST_RM_FLAG=$C/b \
    "$SH" "$ROOT/module/play-detach" add com.example.b >"$C/b.out" 2>&1 &
bpid=$!
i=0
while [ ! -e "$C/b.reached" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
PATH="$STUBS:$PATH" PD_BB=1 PD_TEST_SORT_FLAG=$C/a \
    "$SH" "$ROOT/module/play-detach" add com.example.a >"$C/a.out" 2>&1 &
apid=$!
i=0
while [ ! -e "$C/a.reached" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
# A that did not take the lock over must not stop later: it may get the
# lock right after B removes the stale one, and B would then wait for it
[ -e "$C/a.reached" ] || "$REAL_RM" -f "$C/a.wait"
"$REAL_RM" -f "$C/b.wait"
wait $bpid
"$REAL_RM" -f "$C/a.wait"
wait $apid
check "stale list lock, two waiters: B stopped before the takeover" [ -e "$C/b.reached" ]
check "stale list lock, two waiters: no change lost" list_is "com.example.a
com.example.b"
check "stale list lock, two waiters: no lock left" [ -z "$(ls -a "$PD_DATA_DIR" | grep '^list\.lock')" ]

# The takeover folder name of older versions (<lock>.takeover) is used by
# nobody now: the next holder of that lock removes a leftover one
fresh
mkdir "$PD_DATA_DIR/list.lock.takeover"
pd add com.example.a
check "old-version takeover folder left: add works" list_is com.example.a
check "old-version takeover folder left: removed by the lock holder" [ ! -e "$PD_DATA_DIR/list.lock.takeover" ]

# A command killed while taking a stale lock over leaves its takeover
# behind. Two waiters then: B stops right before it would remove that old
# takeover; A takes the lock over and stops right before removing the stale
# lock; B goes on and stops inside the list change if it gets the lock; then
# A goes on. A takeover must never remove a lock another command holds, so
# neither change is lost. (Each wait below ends early when its stop is
# reached or the command ended.)
fresh
L=$PD_DATA_DIR/list.lock
mkdir "$L"
touch -t 200001010000 "$L"
: >"$C/k.wait"
PATH="$STUBS:$PATH" PD_BB=1 PD_TEST_RM_BLOCK=$L PD_TEST_RM_FLAG=$C/k \
    "$SH" "$ROOT/module/play-detach" add com.example.k >"$C/k.out" 2>&1 &
kpid=$!
i=0
while [ ! -s "$C/k.reached" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
kill -9 "$kpid" "$(cat "$C/k.reached")" 2>/dev/null
wait "$kpid" 2>/dev/null
"$REAL_RM" -f "$C/k.wait"
for g in "$L".takeover*; do [ -e "$g" ] && touch -t 200001010000 "$g"; done
: >"$C/b.wait"
: >"$C/bs.wait"
: >"$C/a.wait"
PATH="$STUBS:$PATH" PD_BB=1 PD_TEST_RMDIR_BLOCK=$L.takeover PD_TEST_RMDIR_FLAG=$C/b PD_TEST_SORT_FLAG=$C/bs \
    "$SH" "$ROOT/module/play-detach" add com.example.b >"$C/b.out" 2>&1 &
bpid=$!
i=0
while [ ! -e "$C/b.reached" ] && [ ! -e "$C/bs.reached" ] && kill -0 "$bpid" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
PATH="$STUBS:$PATH" PD_BB=1 PD_TEST_RM_BLOCK=$L PD_TEST_RM_FLAG=$C/a \
    "$SH" "$ROOT/module/play-detach" add com.example.a >"$C/a.out" 2>&1 &
apid=$!
i=0
while [ ! -e "$C/a.reached" ] && kill -0 "$apid" 2>/dev/null && [ $i -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
"$REAL_RM" -f "$C/b.wait"
i=0
while [ ! -e "$C/bs.reached" ] && kill -0 "$bpid" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
"$REAL_RM" -f "$C/a.wait"
i=0
while kill -0 "$apid" 2>/dev/null && [ $i -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
"$REAL_RM" -f "$C/bs.wait"
wait $bpid
wait $apid
check "killed takeover, two waiters: no change lost" list_is "com.example.a
com.example.b"
check "killed takeover, two waiters: no lock left" [ -z "$(ls -a "$PD_DATA_DIR" | grep '^list\.lock')" ]

# A command ended by a signal exits non-zero and leaves no lock and no
# temporary file (here: TERM to scan while the sort that feeds seen.list
# is stopped; the shell runs the trap when that pipe has written it)
fresh
printf 'package:com.example.o1  installer=com.example.inst\n' >"$PD_TEST_PM"
: >"$C/t.wait"
PATH="$STUBS:$PATH" PD_BB=1 PD_TEST_SORT_FLAG=$C/t "$SH" "$ROOT/module/play-detach" scan >"$C/t.out" 2>&1 &
tpid=$!
i=0
while [ ! -e "$C/t.reached" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
kill -TERM "$tpid" 2>/dev/null
"$REAL_RM" -f "$C/t.wait"
wait "$tpid"
check "scan ended by a signal: exit not 0" [ $? != 0 ]
check "scan ended by a signal: no lock left" [ -z "$(ls -a "$PD_DATA_DIR" | grep 'lock')" ]
check "scan ended by a signal: no temporary file left" [ -z "$(ls -a "$PD_DATA_DIR" | grep '\.tmp\.')" ]

# The same while scan looks for new apps (its loop splits on newlines
# only): the scan lock is still removed (TERM while grep is stopped)
mkdir -p "$STUBS/hold-grep"
{
    echo '#!/bin/sh'
    echo 'if [ -n "$PD_TEST_GREP_FLAG" ]; then'
    hold | sed 's/\$1/$PD_TEST_GREP_FLAG/g'
    echo 'fi'
    echo "exec $(command -v grep) \"\$@\""
} >"$STUBS/hold-grep/grep"
"$REAL_CHMOD" 755 "$STUBS/hold-grep/grep"
fresh
printf 'package:com.example.o1  installer=com.example.inst\n' >"$PD_TEST_PM"
pd autodetach on
: >"$C/g.wait"
PATH="$STUBS/hold-grep:$STUBS:$PATH" PD_BB=1 PD_TEST_GREP_FLAG=$C/g "$SH" "$ROOT/module/play-detach" scan >"$C/g.out" 2>&1 &
tpid=$!
i=0
while [ ! -e "$C/g.reached" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
kill -TERM "$tpid" 2>/dev/null
"$REAL_RM" -f "$C/g.wait"
wait "$tpid"
check "scan ended by a signal in its app loop: stopped there" [ -e "$C/g.reached" ]
check "scan ended by a signal in its app loop: no scan lock left" [ ! -e "$PD_DATA_DIR/scan.lock" ]
pd scan
check "scan ended by a signal in its app loop: next scan runs" [ $? = 0 ]

# A failed sort must keep the list and seen.list (its status was lost
# behind the cat that checks the write)
fresh
pd add com.example.keep
export PD_TEST_SORT_FAIL=1
pd add com.example.new
check "add, failed sort: exit 1" [ $? = 1 ]
check "add, failed sort: list kept" list_is com.example.keep
printf 'com.example.old\n' >"$PD_DATA_DIR/seen.list"
printf 'package:com.example.new  installer=com.google.android.packageinstaller\n' >"$PD_TEST_PM"
pd scan
unset PD_TEST_SORT_FAIL
check "scan, failed sort: seen.list kept" [ "$(cat "$PD_DATA_DIR/seen.list")" = com.example.old ]
# A list or backup file that cannot be read (tr or sed fails) is never taken
# as an empty one: nothing is changed and the command fails
failing fail-tr tr
failing fail-readsed sed -e
for f in fail-tr fail-readsed; do
    fresh
    pd add com.example.a com.example.b
    pd backup "$PD_STORAGE/Download/b.txt"
    printf 'com.example.x\n' >"$C/in.txt"
    PATH="$STUBS/$f:$PATH" pd add com.example.new
    check "add, list unreadable ($f): exit 1" [ $? = 1 ]
    PATH="$STUBS/$f:$PATH" pd remove com.example.a
    check "remove, list unreadable ($f): exit 1" [ $? = 1 ]
    PATH="$STUBS/$f:$PATH" pd import "$C/in.txt"
    check "import, unreadable ($f): exit 1" [ $? = 1 ]
    PATH="$STUBS/$f:$PATH" pd restore "$C/in.txt"
    check "restore, unreadable ($f): exit 1" [ $? = 1 ]
    check "add, remove, import, restore, unreadable ($f): list kept" list_is "com.example.a
com.example.b"
    PATH="$STUBS/$f:$PATH" pd backup "$PD_STORAGE/Download/b.txt"
    check "backup, list unreadable ($f): exit 1" [ $? = 1 ]
    check "backup, list unreadable ($f): old backup kept" [ "$(grep -vc '^#' "$PD_STORAGE/Download/b.txt")" = 2 ]
    PATH="$STUBS/$f:$PATH" pd list
    check "list, unreadable ($f): exit 1" [ $? = 1 ]
done
fresh
printf 'package:com.example.old  installer=com.google.android.packageinstaller\n' >"$PD_TEST_PM"
pd autodetach on
pd add com.example.a
printf 'package:com.example.old  installer=com.google.android.packageinstaller\npackage:com.example.new  installer=com.google.android.packageinstaller\n' >"$PD_TEST_PM"
PATH="$STUBS/fail-readsed:$PATH" pd scan
check "scan, list unreadable: list kept" list_is com.example.a
# A failed stage between the read and the write (grep in remove, sed in
# remove and restore) must not empty the list
failing fail-grepv grep -vxF 2
failing fail-blanksed sed '/^$/d'
fresh
pd add com.example.a com.example.b
printf 'com.example.x\n' >"$C/in.txt"
PATH="$STUBS/fail-grepv:$PATH" pd remove com.example.a
check "remove, failed grep: exit 1" [ $? = 1 ]
PATH="$STUBS/fail-blanksed:$PATH" pd remove com.example.a
check "remove, failed sed: exit 0, one name left" sh -c '[ "$1" = 0 ] && [ "$(cat "$2")" = com.example.b ]' sh $? "$PD_DATA_DIR/detach.list"
pd add com.example.a
PATH="$STUBS/fail-blanksed:$PATH" pd restore "$C/in.txt"
check "restore, failed sed: exit 0, file restored" sh -c '[ "$1" = 0 ] && [ "$(cat "$2")" = com.example.x ]' sh $? "$PD_DATA_DIR/detach.list"
PATH="$STUBS/fail-grepv:$PATH" pd remove com.example.x
check "remove, failed grep: list kept" list_is com.example.x
# A failed stage between the app list and seen.list (cut, sed) must keep
# seen.list: an emptied one makes every app look new at the next scan
failing fail-cut cut
for f in fail-cut fail-blanksed; do
    fresh
    printf 'package:com.example.o1  installer=com.example.inst\npackage:com.example.o2  installer=com.example.inst\n' >"$PD_TEST_PM"
    pd autodetach on
    printf 'package:com.example.o1  installer=com.example.inst\npackage:com.example.o2  installer=com.example.inst\npackage:com.example.n  installer=com.example.inst\n' >"$PD_TEST_PM"
    PATH="$STUBS/$f:$PATH" pd scan
    check "scan, failed stage ($f): seen.list kept" [ "$(cat "$PD_DATA_DIR/seen.list")" = "com.example.o1
com.example.o2" ]
done
# A seen.list or an auto-skip list that cannot be read must not make old
# apps, or apps of a skipped installer, look new: the scan stops and the
# next one tries again
fresh
printf 'package:com.example.o1  installer=com.example.inst\npackage:com.example.o2  installer=com.example.inst\n' >"$PD_TEST_PM"
pd autodetach on
PATH="$STUBS/fail-grepq:$PATH" pd scan
check "scan, seen.list unreadable: old apps not detached" list_is ""
check "scan, seen.list unreadable: no scan lock left" [ ! -e "$PD_DATA_DIR/scan.lock" ]
pd scan
check "scan, seen.list unreadable: next scan runs" [ $? = 0 ]
check "scan, seen.list unreadable: next scan detaches nothing old" list_is ""
failing fail-skiptr tr '\n'
fresh
printf 'package:com.example.o1  installer=com.android.vending\n' >"$PD_TEST_PM"
pd autodetach on
pd autoskip add com.example.inst
printf 'package:com.example.o1  installer=com.android.vending\npackage:com.example.n  installer=com.example.inst\n' >"$PD_TEST_PM"
PATH="$STUBS/fail-skiptr:$PATH" pd scan
check "scan, auto-skip list unreadable: app of a skipped installer not detached" list_is ""
check "scan, auto-skip list unreadable: seen.list kept" [ "$(cat "$PD_DATA_DIR/seen.list")" = com.example.o1 ]
# pm that fails after part of its list (worker decision: a failed pm is not
# trusted): seen.list keeps the apps it did not print, and the next scan
# detaches none of them
fresh
printf 'package:com.example.o1  installer=com.example.inst\npackage:com.example.o2  installer=com.example.inst\n' >"$PD_TEST_PM"
pd autodetach on
printf 'package:com.example.o1  installer=com.example.inst\n' >"$PD_TEST_PM"
PD_TEST_PM_FAIL=1 pd scan
check "scan, pm failed after part of its list: seen.list kept" [ "$(cat "$PD_DATA_DIR/seen.list")" = "com.example.o1
com.example.o2" ]
printf 'package:com.example.o1  installer=com.example.inst\npackage:com.example.o2  installer=com.example.inst\n' >"$PD_TEST_PM"
pd scan
check "scan after a failed pm: old apps not detached" list_is ""
# Pruning auto.log of removed apps: whole names only (a name that is part
# of an installed one is removed), skip lines stay
fresh
printf 'package:com.example.o10  installer=com.example.inst\n' >"$PD_TEST_PM"
pd autodetach on
printf '1700000000 com.example.o1\n1700000001 example.o10\n1700000002 com.example.o10\n1700000003 skip 7\n' >"$PD_DATA_DIR/auto.log"
pd scan
check "scan: auto.log keeps installed apps and skip lines only" [ "$(cat "$PD_DATA_DIR/auto.log")" = "1700000002 com.example.o10
1700000003 skip 7" ]
# Pruning auto.log of removed apps: a failed cut or grep must not make an
# installed app look removed
failing fail-grepq grep -qxF 2
for f in fail-cut fail-grepq; do
    fresh
    printf 'package:com.example.o1  installer=com.example.inst\n' >"$PD_TEST_PM"
    pd autodetach on
    printf '1700000000 com.example.o1\n1700000000 skip 7\n' >"$PD_DATA_DIR/auto.log"
    PATH="$STUBS/$f:$PATH" pd scan
    check "scan, failed stage ($f): auto.log entry of an installed app kept" grep -qx '1700000000 com.example.o1' "$PD_DATA_DIR/auto.log"
done
# mksh keeps a here-document in a temporary file. When that cannot be made
# after scan's first check of it (here: its folder goes away when the list
# is read), every later here-document prints nothing: seen.list must be kept.
mkdir -p "$STUBS/tmp-gone"
printf '#!/bin/sh\n[ -d "$PD_TEST_TMP" ] && %s "$PD_TEST_TMP" "$PD_TEST_TMP.gone"\nexec %s "$@"\n' \
    "$REAL_MV" "$(command -v tr)" >"$STUBS/tmp-gone/tr"
"$REAL_CHMOD" 755 "$STUBS/tmp-gone/tr"
if [ -n "$("$SH" -c 'echo "$KSH_VERSION"')" ]; then
    fresh
    printf 'package:com.example.o1  installer=com.example.inst\npackage:com.example.o2  installer=com.example.inst\n' >"$PD_TEST_PM"
    pd autodetach on
    pd add com.example.a
    printf '1700000000 com.example.o1\n' >"$PD_DATA_DIR/auto.log"
    printf 'package:com.example.o1  installer=com.example.inst\npackage:com.example.o2  installer=com.example.inst\npackage:com.example.n  installer=com.example.inst\n' >"$PD_TEST_PM"
    mkdir "$C/tmp"
    PATH="$STUBS/tmp-gone:$PATH" TMPDIR=$C/tmp PD_TEST_TMP=$C/tmp pd scan
    check "scan, here-document fails after the first check: the case ran (mksh)" [ -d "$C/tmp.gone" ]
    check "scan, here-document fails after the first check: seen.list kept" [ "$(cat "$PD_DATA_DIR/seen.list")" = "com.example.o1
com.example.o2" ]
    check "scan, here-document fails after the first check: list kept" list_is com.example.a
    check "scan, here-document fails after the first check: auto.log kept" [ "$(cat "$PD_DATA_DIR/auto.log")" = "1700000000 com.example.o1" ]
else
    skipped "scan, here-document fails after the first check (needs mksh)"
fi
# A list text longer than one command argument may be (an external printf
# in mksh) must still reach the size check, never an empty list
fresh
pd add com.example.keep
i=0
while [ $i -lt 3000 ]; do echo "com.example.app$i.longername.padding.abcdefghijkl"; i=$((i + 1)); done >"$C/big.txt"
# shellcheck disable=SC2046 # one argument per name
pd add $(cat "$C/big.txt")
check "add of a list over 128 KB: exit 1" [ $? = 1 ]
check "add of a list over 128 KB: list kept" list_is com.example.keep
fresh
pd autoskip add com.example.inst
pd autoskip add com.example.inst2
PD_TEST_SORT_FAIL=1 pd autoskip add com.example.more
check "autoskip add, failed sort: exit 1" [ $? = 1 ]
PD_TEST_SORT_FAIL=1 pd autoskip remove com.example.inst2
check "autoskip remove, failed sort: exit 1" [ $? = 1 ]
check "autoskip, failed sort: list kept" [ "$(cat "$PD_DATA_DIR/auto-skip")" = "com.example.inst
com.example.inst2" ]
# The other stages of the auto-skip change (reading the old list, sed, grep).
# cat is built into mksh: a cat on PATH cannot fail there.
failing fail-skipcat cat "$PD_DATA_DIR/auto-skip"
skipcat=fail-skipcat
case "$("$SH" -c 'command -v cat')" in
    /*) ;;
    *)
        skipcat=
        skipped "autoskip, failed read of the old list (cat is a shell builtin)"
        ;;
esac
for f in $skipcat fail-blanksed fail-grepv; do
    printf 'com.example.inst\ncom.example.inst2\n' >"$PD_DATA_DIR/auto-skip"
    if [ "$f" != fail-grepv ]; then
        PATH="$STUBS/$f:$PATH" pd autoskip add com.example.more
        check "autoskip add, failed stage ($f): exit 1" [ $? = 1 ]
    fi
    PATH="$STUBS/$f:$PATH" pd autoskip remove com.example.inst2
    check "autoskip remove, failed stage ($f): exit 1" [ $? = 1 ]
    check "autoskip, failed stage ($f): list kept" [ "$(cat "$PD_DATA_DIR/auto-skip")" = "com.example.inst
com.example.inst2" ]
done

# import / backup / restore
fresh
printf '# comment\r\n  com.example.one  \n\ncom.example.two\n' >"$C/in.txt"
pd import "$C/in.txt"
check "import: exit 0" [ $? = 0 ]
check "import: list" list_is "com.example.one
com.example.two"
printf 'com.example.one com.example.x\n' >"$C/bad.txt"
pd import "$C/bad.txt"
check "import: two names on a line rejected" [ $? = 1 ]
pd backup
check "backup: default file" [ -s "$PD_STORAGE/Play-Detach/play-detach-backup.txt" ]
check "backup: header and names" [ "$(grep -vc '^#' "$PD_STORAGE/Play-Detach/play-detach-backup.txt")" = 2 ]
pd clear
pd restore "$PD_STORAGE/Play-Detach/play-detach-backup.txt"
check "restore: exit 0" [ $? = 0 ]
check "restore: list back" list_is "com.example.one
com.example.two"
pd backup "$PD_STORAGE/Download/mine.txt"
pd restore "$PD_STORAGE/Download/mine.txt"
check "restore: message names the restored file" out_has "from $PD_STORAGE/Download/mine.txt"
pd restore "$C/missing.txt"
check "restore: missing file exit 1" [ $? = 1 ]
mkdir "$PD_STORAGE/Folder"
chmod 775 "$PD_STORAGE/Folder"
pd backup "$PD_STORAGE/Folder"
check "backup to a folder: refused" [ $? = 1 ]
check "backup to a folder: folder mode kept" [ "$(stat -c %a "$PD_STORAGE/Folder")" = 775 ]
check "backup to a folder: nothing put in it" [ -z "$(ls -A "$PD_STORAGE/Folder")" ]
rm -rf "$PD_STORAGE/Play-Detach"
pd backup
check "backup: falls back to Download" [ -s "$PD_STORAGE/Download/play-detach-backup.txt" ]

# Shared storage: root must follow no link planted there, at the temporary
# name ($$ is known when the command is started with exec), at the backup
# itself, or swapped in for the backup before its mode is set
fresh
pd add com.example.a
echo precious >"$C/victim"
"$REAL_CHMOD" 600 "$C/victim"
B=$PD_STORAGE/Download/b.txt
PATH="$STUBS:$PATH" PD_BB=1 "$SH" -c 'ln -s "$1" "$2.tmp.$$" && exec "$3" "$4" backup "$2"' \
    sh "$C/victim" "$B" "$SH" "$ROOT/module/play-detach" >"$C/out" 2>&1
check "backup, link at the temporary name: file behind it untouched" [ "$(cat "$C/victim")" = precious ]
check "backup, link at the temporary name: backup written" grep -qx com.example.a "$B"
"$REAL_RM" -f "$B" "$B".tmp.* "$C/victim"
echo precious >"$C/victim"
"$REAL_CHMOD" 600 "$C/victim"
ln -s "$C/victim" "$B"
pd backup "$B"
check "backup over a link: file behind it untouched" [ "$(cat "$C/victim")" = precious ]
check "backup over a link: backup is a file" sh -c '[ -f "$1" ] && [ ! -L "$1" ] && grep -qx com.example.a "$1"' sh "$B"
(
    PD_TEST_CHMOD_SWAP=$B PD_TEST_CHMOD_TO=$C/victim
    export PD_TEST_CHMOD_SWAP PD_TEST_CHMOD_TO
    pd backup "$B"
)
check "backup swapped for a link before chmod: file behind it keeps its mode" [ "$(stat -c %a "$C/victim")" = 600 ]
check "backup: no staging folder left" [ -z "$(ls -A "$PD_STORAGE/Download" | grep '^\.play-detach')" ]
# The staging folder swapped for a link to another folder right after it is
# made: refused, nothing is made through it
mkdir "$C/decoy"
(
    PD_TEST_STAGE_TO=$C/decoy/stage PD_TEST_MV_LOG=$C/mv.log
    export PD_TEST_STAGE_TO PD_TEST_MV_LOG
    pd backup "$B"
)
check "backup, staging folder swapped for a link: refused" [ $? = 1 ]
check "backup, staging folder swapped for a link: nothing made through it" sh -c '! grep -q "/decoy/" "$1" 2>/dev/null && [ -z "$(ls -A "$2")" ]' sh "$C/mv.log" "$C/decoy/stage"
"$REAL_RM" -f "$PD_STORAGE/Download"/.play-detach-backup.*
# A relative backup path (the folder is resolved before the staging folder is used)
(cd "$PD_STORAGE/Download" && pd backup rel.txt)
check "backup to a relative path: written there" grep -qx com.example.a "$PD_STORAGE/Download/rel.txt"
# A backup path through the FUSE view of internal storage is written in the
# real folder (/data/media/<n>), where root owns what it makes; a path
# whose real folder does not exist is used as given (PD_FS_ROOT stands for /)
FR=$C/root
mkdir -p "$FR/data/media/0/Download" "$FR/data/media/10/Download" "$FR/sdcard/Download" "$FR/sdcard/Other" \
    "$FR/storage/self/primary/Download" "$FR/storage/emulated/10/Download"
for p in sdcard/Download/a.txt storage/self/primary/Download/b.txt; do
    PD_FS_ROOT=$FR pd backup "$FR/$p"
    check "backup to /$p: written in /data/media/0" sh -c 'grep -qx com.example.a "$1" && [ ! -e "$2" ]' sh "$FR/data/media/0/Download/${p##*/}" "$FR/$p"
done
PD_FS_ROOT=$FR pd backup "$FR/storage/emulated/10/Download/c.txt"
check "backup to /storage/emulated/10/...: written in /data/media/10" sh -c 'grep -qx com.example.a "$1" && [ ! -e "$2" ]' sh "$FR/data/media/10/Download/c.txt" "$FR/storage/emulated/10/Download/c.txt"
PD_FS_ROOT=$FR pd backup "$FR/sdcard/Other/d.txt"
check "backup to /sdcard/... without a real folder: written as given" grep -qx com.example.a "$FR/sdcard/Other/d.txt"
# The staging folder's name is known too: a link planted there is refused,
# left alone and not followed
mkdir "$C/victimdir"
PATH="$STUBS:$PATH" PD_BB=1 "$SH" -c 'ln -s "$1" "${2%/*}/.play-detach-backup.$$" && exec "$3" "$4" backup "$2"' \
    sh "$C/victimdir" "$B" "$SH" "$ROOT/module/play-detach" >"$C/out" 2>&1
check "backup, link at the staging folder name: refused" [ $? = 1 ]
check "backup, link at the staging folder name: nothing written behind it" [ -z "$(ls -A "$C/victimdir")" ]
check "backup, link at the staging folder name: link left alone" [ -n "$(find "$PD_STORAGE/Download" -name '.play-detach-backup.*' -type l)" ]

# status
fresh
pd add com.example.app
echo "loaded=1700000000 packages=1" >"$PD_DATA_DIR/status"
echo "hook=ok api=35 at=1700000000" >"$PD_DATA_DIR/hook"
pd status
check "status: exit 0" [ $? = 0 ]
check "status: fields" out_has "loaded=1700000000"
check "status: hook" out_has "hook=ok"
check "status: detached count" out_has "detached=1"

# scan and auto-detach
fresh
printf 'package:com.example.old  installer=com.android.vending\n' >"$PD_TEST_PM"
pd autodetach on
check "autodetach on: exit 0" [ $? = 0 ]
check "autodetach on: snapshot of current apps" grep -qx com.example.old "$PD_DATA_DIR/seen.list"
printf 'package:com.example.old  installer=com.android.vending\npackage:com.example.side  installer=com.google.android.packageinstaller\npackage:com.example.store  installer=com.android.vending\n' >"$PD_TEST_PM"
pd scan
check "scan: exit 0" [ $? = 0 ]
check "scan: new sideloaded app detached" list_is "com.example.side"
check "scan: auto history" grep -q ' detach auto com.example.side$' "$PD_DATA_DIR/history.log"
check "scan: Play Store version saved" grep -q '^code=84021 ' "$PD_DATA_DIR/store"
check "scan: notification posted" grep -q '^su 2000 -c cmd notification post' "$WORK/calls.log"
# history.log is cut to 200 lines by scan; list changes append to it under
# the list lock, so scan must not cut it while another command holds the lock
i=0
while [ $i -lt 250 ]; do
    echo "1700000000 detach user com.example.h$i"
    i=$((i + 1))
done >"$PD_DATA_DIR/history.log"
mkdir "$PD_DATA_DIR/list.lock"
pd scan
check "scan with the list busy: exit 0" [ $? = 0 ]
check "scan with the list busy: history not cut" [ "$(wc -l <"$PD_DATA_DIR/history.log")" = 250 ]
check "scan with the list busy: lock left alone" [ -d "$PD_DATA_DIR/list.lock" ]
rmdir "$PD_DATA_DIR/list.lock"
printf 'package:com.example.old  installer=com.android.vending\npackage:com.example.side  installer=com.google.android.packageinstaller\npackage:com.example.store  installer=com.android.vending\npackage:com.example.side2  installer=com.google.android.packageinstaller\n' >"$PD_TEST_PM"
pd scan
check "scan detaching with a long history: exit 0" [ $? = 0 ]
check "scan detaching with a long history: detached" grep -qx com.example.side2 "$PD_DATA_DIR/detach.list"
check "scan detaching with a long history: lock released" [ ! -d "$PD_DATA_DIR/list.lock" ]
check "scan detaching with a long history: history cut in the same scan" [ "$(wc -l <"$PD_DATA_DIR/history.log")" = 200 ]
pd scan
check "scan: history cut to 200 lines" [ "$(wc -l <"$PD_DATA_DIR/history.log")" = 200 ]
pd autoskip add com.example.inst
check "autoskip add" [ "$(cat "$C/out")" = com.example.inst ]
pd autoskip remove com.example.inst
check "autoskip remove" [ ! -s "$C/out" ]
pd autoskip add "bad;name"
check "autoskip rejects a bad name" [ $? = 1 ]
pd autoskip add com.example.inst
pd autoskip remove com.example.inst
check "autoskip remove of the last entry: exit 0" [ $? = 0 ]
check "autoskip remove of the last entry: empty list" [ ! -s "$PD_DATA_DIR/auto-skip" ]

# A full /data: with a file size limit of 0 and SIGXFSZ ignored every write
# fails with an error, as on a full disk. A failed write must never replace
# a state file.
nospace() { (trap '' XFSZ && ulimit -f 0 && pd "$@"); }
if (trap '' XFSZ && ulimit -f 0) 2>/dev/null; then
    fresh
    pd autoskip add com.example.inst
    pd autoskip add com.example.inst2
    nospace autoskip add com.example.more
    check "autoskip add, no space: exit 1" [ $? = 1 ]
    check "autoskip add, no space: list kept" [ "$(cat "$PD_DATA_DIR/auto-skip")" = "com.example.inst
com.example.inst2" ]
    nospace autoskip remove com.example.inst
    check "autoskip remove, no space: list kept" [ "$(cat "$PD_DATA_DIR/auto-skip")" = "com.example.inst
com.example.inst2" ]
    fresh
    printf 'package:com.example.oldside  installer=com.google.android.packageinstaller\n' >"$PD_TEST_PM"
    pd autodetach on
    printf '1700000000 com.example.gone\n1700000000 com.example.oldside\n' >"$PD_DATA_DIR/auto.log"
    printf 'package:com.example.oldside  installer=com.google.android.packageinstaller\npackage:com.example.new  installer=com.google.android.packageinstaller\n' >"$PD_TEST_PM"
    nospace scan
    check "scan, no space: seen.list kept" [ "$(cat "$PD_DATA_DIR/seen.list")" = com.example.oldside ]
    check "scan, no space: auto.log kept" [ "$(wc -l <"$PD_DATA_DIR/auto.log")" = 2 ]
    check "scan, no space: no temporary file left" [ -z "$(ls "$PD_DATA_DIR" | grep '\.tmp\.')" ]
    echo "loaded=$(($(date +%s) - 100)) packages=1" >"$PD_DATA_DIR/status"
    nospace status
    check "status, no space: no temporary file left" [ -z "$(ls "$PD_DATA_DIR" | grep '\.tmp\.')" ]
    pd scan
    check "scan after a full /data: only the new app detached" list_is com.example.new
    # A shell that keeps a here-document in a temporary file (mksh) cannot
    # write it on a full /data: the names must not be lost on the way
    fresh
    pd add com.example.app
    printf 'com.example.other\ncom.example.more\n' >"$C/in.txt"
    # (output to /dev/null: a failed write of the output would end it with 1)
    nospace_rc() {
        (trap '' XFSZ && ulimit -f 0 && PATH="$STUBS:$PATH" PD_BB=1 "$SH" "$ROOT/module/play-detach" "$@" >/dev/null 2>&1
            echo $?)
    }
    check "restore, no space: exit 1" [ "$(nospace_rc restore "$C/in.txt")" = 1 ]
    check "restore, no space: list kept" list_is com.example.app
    pd clear
    check "import into an empty list, no space: exit 1" [ "$(nospace_rc import "$C/in.txt")" = 1 ]
    # busybox sort exits 0 when it cannot write a single line of output
    fresh
    check "first add, no space: exit 1" [ "$(nospace_rc add com.example.a)" = 1 ]
    pd add com.example.a com.example.b
    check "remove leaving one name, no space: exit 1" [ "$(nospace_rc remove com.example.b)" = 1 ]
    check "remove leaving one name, no space: list kept" list_is "com.example.a
com.example.b"
    printf 'package:com.example.oldside  installer=com.google.android.packageinstaller\n' >"$PD_TEST_PM"
    pd autodetach on
    printf 'package:com.example.new  installer=com.google.android.packageinstaller\n' >"$PD_TEST_PM"
    nospace scan
    check "scan of one app, no space: seen.list kept" [ "$(cat "$PD_DATA_DIR/seen.list")" = com.example.oldside ]
else
    skipped "full /data (no ulimit -f or trap XFSZ)"
fi

# ---------------------------------------------------------------------------
# service.sh: a /data/app event starts a scan; the watcher ends when the
# module folder is gone
# ---------------------------------------------------------------------------

fresh
MOD=$C/mod
mkdir -p "$MOD"
cp "$ROOT/module/service.sh" "$MOD/service.sh"
printf '#!/bin/sh\necho "$1" >>"%s"\n' "$C/cli.log" >"$MOD/play-detach"
chmod 755 "$MOD/play-detach"
PATH="$STUBS:$PATH" PD_TEST_MOD=$MOD "$SH" "$MOD/service.sh" </dev/null >/dev/null 2>&1
i=0
while [ $i -lt 20 ] && ! grep -qx scan "$C/cli.log" 2>/dev/null; do
    sleep 1
    i=$((i + 1))
done
check "service: event starts a scan" grep -qx scan "$C/cli.log"
check "service: event pipe made" [ -p "$PD_DATA_DIR/events.fifo" ]
rm -rf "$MOD"
if have pgrep; then
    i=0
    while [ $i -lt 15 ] && pgrep -f "$MOD/service.sh" >/dev/null; do
        sleep 1
        i=$((i + 1))
    done
    check "service: watcher ends without the module" not pgrep -f "$MOD/service.sh"
    pkill -f "$MOD/service.sh" 2>/dev/null
else
    skipped "service: watcher end (no pgrep)"
fi

# An event pipe that cannot be opened (here: mode 000, as a non-root user)
# must make the watcher fall back to the 3 s check, not end it
if [ "$(id -u)" != 0 ] && have pgrep; then
    fresh
    MOD=$C/mod
    mkdir -p "$MOD"
    cp "$ROOT/module/service.sh" "$MOD/service.sh"
    printf '#!/bin/sh\necho "$1" >>"%s"\n' "$C/cli.log" >"$MOD/play-detach"
    chmod 755 "$MOD/play-detach"
    mkfifo -m 000 "$PD_DATA_DIR/events.fifo"
    PATH="$STUBS:$PATH" PD_TEST_MOD=$MOD "$SH" "$MOD/service.sh" </dev/null >/dev/null 2>&1
    sleep 4
    check "service: unopenable event pipe, watcher still runs" pgrep -f "$MOD/service.sh"
    rm -rf "$MOD"
    i=0
    while [ $i -lt 15 ] && pgrep -f "$MOD/service.sh" >/dev/null; do
        sleep 1
        i=$((i + 1))
    done
    pkill -f "$MOD/service.sh" 2>/dev/null
else
    skipped "service: unopenable event pipe (needs a non-root user and pgrep)"
fi

# The watcher with an inotifyd that exits at once (started at the top):
# within 75 s of its start it must have scanned, and stopped starting
# inotifyd after 3 tries. Without /data/app here, the scan of the 3 s check
# is the one for 10 minutes since the last scan, which needs an uptime of
# 10 minutes.
read -r up _ </proc/uptime
if [ "${up%.*}" -ge 600 ]; then
    while [ $(($(date +%s) - DEAD_START)) -lt 75 ] && ! grep -qx scan "$DEAD/cli.log" 2>/dev/null; do
        sleep 1
    done
    echo "     dying inotifyd: $(cat "$DEAD/cli.log" 2>/dev/null | grep -cx scan) scan(s), $(wc -l <"$DEAD/starts") start(s) in $(($(date +%s) - DEAD_START)) s"
    check "service: inotifyd that exits at once still gets scans" grep -qx scan "$DEAD/cli.log"
    check "service: inotifyd that exits at once is started 3 times only" [ "$(wc -l <"$DEAD/starts")" = 3 ]
else
    skipped "service: dying inotifyd (uptime under 10 minutes)"
fi
rm -rf "$DEAD/mod"
if have pgrep; then
    i=0
    while [ $i -lt 15 ] && pgrep -f "$DEAD/mod/service.sh" >/dev/null; do
        sleep 1
        i=$((i + 1))
    done
    check "service: watcher with a dying inotifyd ends without the module" not pgrep -f "$DEAD/mod/service.sh"
    pkill -f "$DEAD/mod/service.sh" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# customize.sh (run the way the installer runs it: sourced, with its helpers)
# ---------------------------------------------------------------------------

# install_module [arch]: a copy of module/ as MODPATH; a file $C/detach.txt
# is put in it as detach.txt. Output in $C/install.log.
install_module() {
    rm -rf "$C/mp"
    cp -R "$ROOT/module" "$C/mp"
    [ -f "$C/detach.txt" ] && cp "$C/detach.txt" "$C/mp/detach.txt"
    # The installer runs $MODPATH/play-detach; its #!/system/bin/sh does not
    # exist here, so that copy starts the real script with $SH instead
    printf '#!/bin/sh\nexec %s "%s" "$@"\n' "$SH" "$ROOT/module/play-detach" >"$C/mp/play-detach"
    (
        ui_print() { echo "$1"; }
        abort() {
            echo "ABORT: $1"
            exit 1
        }
        set_perm() { chmod "$4" "$1"; }
        set_perm_recursive() { :; }
        MODPATH=$C/mp
        ARCH=${1:-arm64}
        API=34
        KSU=true
        PATH="$STUBS:$PATH"
        PD_TERMUX_BIN=${TBIN:-$C/termux/bin}
        export PD_TERMUX_BIN
        # shellcheck disable=SC1091
        . "$MODPATH/customize.sh"
    ) >"$C/install.log" 2>&1
}

fresh
mkdir -p "$C/termux/bin"
printf 'com.example.app\n' >"$C/detach.txt"
install_module
check "install: no abort" not grep -q ABORT "$C/install.log"
check "install: data folder 700" [ "$(stat -c %a "$PD_DATA_DIR")" = 700 ]
check "install: detach.txt imported" list_is "com.example.app"
check "install: detach.txt removed" [ ! -e "$C/mp/detach.txt" ]
check "install: Termux command" grep -qx 'exec su -c /data/adb/modules/play-detach/play-detach "$@"' "$C/termux/bin/play-detach"
check "install: Termux command mode 755" [ "$(stat -c %a "$C/termux/bin/play-detach")" = 755 ]
# The Termux folder belongs to Termux: a link planted as play-detach must not
# make the root installer write, chown or chmod the file it points to
fresh
mkdir -p "$C/termux/bin"
echo precious >"$C/victim"
chmod 600 "$C/victim"
ln -s "$C/victim" "$C/termux/bin/play-detach"
install_module
check "install: file behind a Termux link untouched" [ "$(cat "$C/victim")" = precious ]
check "install: file behind a Termux link keeps its mode" [ "$(stat -c %a "$C/victim")" = 600 ]
check "install: Termux link replaced by the command" \
    sh -c '[ -f "$1" ] && [ ! -L "$1" ] && grep -q "^exec su -c" "$1"' sh "$C/termux/bin/play-detach"
fresh
mkdir -p "$C/termux/bin"
ln -s "$C/nowhere" "$C/termux/bin/play-detach"
install_module
check "install: dangling Termux link not followed" [ ! -e "$C/nowhere" ]
fresh
mkdir -p "$C/termux/bin"
echo old >"$C/termux/bin/play-detach"
install_module
check "install: old Termux command replaced" grep -qx 'exec su -c /data/adb/modules/play-detach/play-detach "$@"' "$C/termux/bin/play-detach"
# The command is made inside the Termux folder (so it gets that folder's
# SELinux label and encryption policy on a phone) and only renamed there
fresh
mkdir -p "$C/termux/bin"
(
    PD_TEST_MV_LOG=$C/mv.log
    export PD_TEST_MV_LOG
    install_module
)
check "install: Termux command made inside the Termux folder" \
    sh -c 'tail -n 1 "$1" | grep -q "^$2/"' sh "$C/mv.log" "$(cd -P "$C/termux/bin" && pwd -P)"
check "install: no staging folder left" [ "$(ls -A "$C/termux/bin")" = play-detach ]
# A link among the Termux folders (here usr) must not move the command
# into the folder it points to
fresh
mkdir -p "$C/tx/files" "$C/else/usr/bin"
ln -s "$C/else/usr" "$C/tx/files/usr"
TBIN=$C/tx/files/usr/bin install_module
check "install: Termux usr folder as a link: nothing written behind it" [ ! -e "$C/else/usr/bin/play-detach" ]
# Termux swaps the new command for a link before its mode is set: the file
# behind the link must keep its mode
fresh
mkdir -p "$C/termux/bin"
echo precious >"$C/victim"
"$REAL_CHMOD" 600 "$C/victim"
(
    PD_TEST_CHMOD_SWAP=$C/termux/bin/play-detach PD_TEST_CHMOD_TO=$C/victim
    export PD_TEST_CHMOD_SWAP PD_TEST_CHMOD_TO
    install_module
)
check "install: command swapped for a link before chmod: file behind it keeps its mode" [ "$(stat -c %a "$C/victim")" = 600 ]
# Termux moves the new staging folder elsewhere and leaves a link to it:
# the command must not be put next to the moved folder
fresh
mkdir -p "$C/termux/bin" "$C/decoy"
(
    PD_TEST_MKDIR_TO=$C/decoy/stage
    export PD_TEST_MKDIR_TO
    install_module
)
check "install: staging folder swapped for a link: nothing written beside it" [ ! -e "$C/decoy/play-detach" ]
# Termux plants a link to a pipe again right after the old command is
# removed: root must not write through it
fresh
mkdir -p "$C/termux/bin"
mkfifo "$C/pipe"
timeout 10 cat "$C/pipe" >"$C/pipe.got" 2>/dev/null &
readpid=$!
(
    PD_TEST_RM_REPLANT=$C/termux/bin/play-detach PD_TEST_RM_LINK=$C/pipe
    export PD_TEST_RM_REPLANT PD_TEST_RM_LINK
    install_module
)
# ends the reader when nothing was written (bounded, the reader may be gone)
timeout 5 sh -c ': >"$1"' sh "$C/pipe" >/dev/null 2>&1 &
wait $readpid
check "install: link to a pipe planted after the remove: nothing written through it" [ ! -s "$C/pipe.got" ]
check "install: link to a pipe planted after the remove: command is a file" \
    sh -c '[ -f "$1" ] && [ ! -L "$1" ] && grep -q "^exec su -c" "$1"' sh "$C/termux/bin/play-detach"
# The backup folder in shared storage: made with the owner and mode of
# Download, and root follows no link swapped in for it while doing that
fresh
"$REAL_RM" -rf "$PD_STORAGE/Play-Detach"
"$REAL_CHMOD" 771 "$PD_STORAGE/Download"
install_module
check "install: backup folder made with the mode of Download" \
    sh -c '[ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %a "$1")" = 771 ]' sh "$PD_STORAGE/Play-Detach"
check "install: no staging folder left in storage" [ -z "$(ls -A "$PD_STORAGE" | grep '^\.play-detach')" ]
fresh
"$REAL_RM" -rf "$PD_STORAGE/Play-Detach"
"$REAL_CHMOD" 771 "$PD_STORAGE/Download"
mkdir "$C/victimdir"
"$REAL_CHMOD" 700 "$C/victimdir"
(
    PD_TEST_CHMOD_SWAP=$PD_STORAGE/Play-Detach PD_TEST_CHMOD_TO=$C/victimdir
    export PD_TEST_CHMOD_SWAP PD_TEST_CHMOD_TO
    install_module
)
check "install: backup folder swapped for a link before chmod: folder behind it keeps its mode" [ "$(stat -c %a "$C/victimdir")" = 700 ]
# A Play-Detach folder that is a link (worker decision: not used): no
# backup is written behind it, by the installer or automatically
fresh
"$REAL_RM" -rf "$PD_STORAGE/Play-Detach"
mkdir "$C/victimdir"
ln -s "$C/victimdir" "$PD_STORAGE/Play-Detach"
printf 'com.example.app\n' >"$C/detach.txt"
install_module
check "install: Play-Detach as a link: no backup behind it" [ -z "$(ls -A "$C/victimdir")" ]
pd add com.example.b
check "add: Play-Detach as a link: no automatic backup behind it" [ -z "$(ls -A "$C/victimdir")" ]
check "add: Play-Detach as a link: automatic backup in Download" grep -qx com.example.b "$PD_STORAGE/Download/play-detach-auto.txt"
"$REAL_RM" -rf "$PD_STORAGE/Play-Detach" "$PD_STORAGE/Download"
ln -s "$C/victimdir" "$PD_STORAGE/Download"
pd add com.example.c
check "add: Download as a link: no automatic backup behind it" [ -z "$(ls -A "$C/victimdir")" ]
# The installer's staging folder swapped for a link right after it is made:
# no Play-Detach is made through it
fresh
"$REAL_RM" -rf "$PD_STORAGE/Play-Detach"
mkdir "$C/decoy"
(
    PD_TEST_STAGE_TO=$C/decoy/stage PD_TEST_MV_LOG=$C/mv.log
    export PD_TEST_STAGE_TO PD_TEST_MV_LOG
    install_module
)
check "install: staging folder swapped for a link: nothing made through it" sh -c '! grep -q "/decoy/" "$1" 2>/dev/null && [ -z "$(ls -A "$2")" ]' sh "$C/mv.log" "$C/decoy/stage"
# A link planted at the installer's staging folder name (install_module
# runs it in a subshell of this script, so its $$ is ours)
fresh
"$REAL_RM" -rf "$PD_STORAGE/Play-Detach"
mkdir "$C/victimdir"
ln -s "$C/victimdir" "$PD_STORAGE/.play-detach-folder.$$"
install_module
check "install: link at the staging folder name: nothing made behind it" [ -z "$(ls -A "$C/victimdir")" ]
check "install: link at the staging folder name: link left alone" [ -L "$PD_STORAGE/.play-detach-folder.$$" ]
fresh
install_module x86_64
check "install: abort on non-arm64" grep -q '^ABORT: ! Only arm64' "$C/install.log"

# ---------------------------------------------------------------------------
# .forgejo/module-ci.sh release step, offline (local bare repo, curl stub)
# ---------------------------------------------------------------------------

# The fork releases above the upstream build it replaces, so root managers
# offer it as an update: released versionCode = module.prop's + offset
off=$(sed -n 's/^VERSION_CODE_OFFSET=//p' "$ROOT/.forgejo/module-ci.conf")
# 4: the fork already released versionCode 15 (module.prop 12 + 3), so the
# next release of the same upstream version must be above that
check "module-ci.conf: release versionCode above the last fork release" [ "${off:-0}" -ge 4 ]

if have bash && have git && have python3 && have unzip && have sha256sum; then
    mkdir -p "$WORK/release" "$STUBS/release"
    bash "$ROOT/tests/release.sh" "$ROOT" "$WORK/release" "$STUBS/release"
    rc=$?
    n=$(grep -c "^ok " "$WORK/release/results" 2>/dev/null)
    pass=$((pass + ${n:-0}))
    n=$(grep -c "^FAIL " "$WORK/release/results" 2>/dev/null)
    fail=$((fail + ${n:-0}))
    [ $rc = 0 ] || [ -s "$WORK/release/results" ] || no "module-ci release harness (exit $rc)"
else
    skipped "module-ci release (needs bash, git, python3, unzip, sha256sum)"
fi

# the job builds the dispatched commit even when main has moved since: the steps whose run text
# clones or calls `module-ci.sh build` run against a local bare repo whose main has a commit after
# BASE_SHA. The fixture's .forgejo/module-ci.sh is a marker script that records which commit's copy
# ran; the real pipeline is never reachable from here. Run blocks are read without PyYAML.
wf_dispatched() {
  _wf=$WORK/workflow
  mkdir -p "$_wf/job" "$_wf/forge/owner" "$_wf/seed/.forgejo" || return 1
  git init -q --bare "$_wf/forge/owner/repo.git" && git init -q "$_wf/seed" || return 1
  for _c in dispatched later-on-main; do
    printf '#!/bin/sh\necho "%s $*" >> "$MARKER_LOG"\n' "$_c" > "$_wf/seed/.forgejo/module-ci.sh"
    (cd "$_wf/seed" && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -qm "$_c") || return 1
    [ "$_c" = dispatched ] && _base=$(git -C "$_wf/seed" rev-parse HEAD)
  done
  git -C "$_wf/seed" push -q "$_wf/forge/owner/repo.git" HEAD:refs/heads/main || return 1
  python3 -I - "$ROOT/.forgejo/workflows/module-release.yml" > "$_wf/steps.sh" <<'PY'
import re, sys
steps, cur = [], None
for l in open(sys.argv[1]).read().split("\n"):
    if re.match(r"^      - name:", l):
        cur = {"run": [], "in": False}; steps.append(cur); continue
    if cur is None:
        continue
    if re.match(r"^        run: \|\s*$", l):
        cur["in"] = True; continue
    m = re.match(r"^        run: (.+)$", l)
    if m:
        cur["run"].append(m.group(1)); continue
    if cur["in"]:
        if l.startswith("          ") or not l.strip():
            cur["run"].append(l[10:])
        else:
            cur["in"] = False
for st in steps:
    text = "\n".join(st["run"])
    if "git clone" in text or "module-ci.sh build" in text:
        print("(\n" + text + "\n)")
PY
  : > "$_wf/marker.log"
  (cd "$_wf/job" && env SERVER_URL="file://$_wf/forge" REPOSITORY=owner/repo BASE_SHA="$_base" \
    MARKER_LOG="$_wf/marker.log" sh "$_wf/steps.sh") > "$_wf/out.log" 2>&1 || { tail -n 2 "$_wf/out.log"; return 1; }
  [ "$(git -C "$_wf/job/src" rev-parse HEAD)" = "$_base" ] && [ "$(cat "$_wf/marker.log")" = "dispatched build src" ] \
    || { echo "     ran: $(tr '\n' ';' < "$_wf/marker.log")"; return 1; }
}
if command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  check "workflow: checkout and build use the dispatched commit after main moved" wf_dispatched
else
  skipped "workflow dispatched-commit check (needs python3 and git)"
fi

echo "passed $pass, failed $fail, skipped $skip"
[ "$fail" = 0 ]
