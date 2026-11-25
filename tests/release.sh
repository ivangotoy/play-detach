#!/usr/bin/env bash
# Offline test of the build and release steps of .forgejo/module-ci.sh, called by
# tests/run.sh: bash tests/release.sh <repo root> <scratch dir> <stub dir>
#
# The "forge" is a local bare repo (SERVER_URL is a folder, git uses the file
# protocol only) and curl is a stub that answers the release API calls from
# files; any other URL fails. Nothing leaves the machine.
# Results: "ok <name>" / "FAIL <name>" lines in <scratch dir>/results.

ROOT=$1 W=$2 STUBS=$3
RES="$W/results"
: >"$RES"
ok() { echo "ok   $1"; echo "ok $1" >>"$RES"; }
no() { echo "FAIL $1"; echo "FAIL $1" >>"$RES"; }
check() { local n=$1; shift; if "$@"; then ok "$n"; else no "$n"; fi; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_ALLOW_PROTOCOL=file
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
REPOSITORY=owner/mod
TOKEN=test-token-not-a-secret

cat >"$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
# curl stub for the Forgejo release API. State in $CURL_STATE.
S=$CURL_STATE
printf '%s\n' "$*" >>"$S/argv.log"
m=GET out="" w="" url="" upload="" ct=- mt=- retry=- auth=none hfile=- hmode=-
while [ $# -gt 0 ]; do
    case "$1" in
        -X) m=$2; shift ;;
        -o) out=$2; shift ;;
        -w) w=$2; shift ;;
        -F) upload=${2#attachment=@}; shift ;;
        --connect-timeout) ct=$2; shift ;;
        --max-time) mt=$2; shift ;;
        --retry) retry=$2; shift ;;
        -H)
            case "$2" in
                @*)
                    hfile=${2#@}
                    hmode=$(stat -c %a "$hfile" 2>/dev/null || echo missing)
                    if [ "$(cat "$hfile" 2>/dev/null)" = "Authorization: token $CURL_TOKEN" ]; then auth=file-ok; else auth=file-bad; fi ;;
                Authorization:*) auth=literal ;;
            esac
            shift ;;
        -d) shift ;;
        -*) ;;
        *) url=$1 ;;
    esac
    shift
done
# one line per call: method url connect-timeout max-time retry auth header-file mode
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$m" "$url" "$ct" "$mt" "$retry" "$auth" "$hfile" "$hmode" >>"$S/calls.tsv"
api="$SERVER_URL/api/v1/repos/$REPOSITORY"
web="$SERVER_URL/$REPOSITORY"
say() { if [ -n "$out" ]; then printf '%s' "$1" >"$out"; else printf '%s' "$1"; fi; }
case "$m $url" in
    "GET $api/releases/tags/"* | "GET $api/tags/"*)
        if [ -n "$w" ]; then printf 404; exit 0; fi
        say "{\"commit\": {\"sha\": \"$(cat "$S/base")\"}}" ;;
    "POST $api/releases") [ "$CURL_FAIL" = draftlost ] && exit 28; say '{"id": 7}' ;;
    "POST $api/releases/7/assets?name="*)
        cp "$upload" "$S/asset.zip" && say '{"id": 9}' ;;
    "GET $api/releases/7/assets/9")
        say "{\"browser_download_url\": \"$web/releases/download/$(cat "$S/tag")\"}" ;;
    "GET $api/releases/7")
        if [ -f "$S/published" ]; then say '{"id": 7, "draft": false}'; else say '{"id": 7, "draft": true}'; fi ;;
    "PATCH $api/releases/7") touch "$S/published"; [ "$CURL_FAIL" = publishlost ] && exit 28; say '{}' ;;
    "DELETE $api/releases/7") touch "$S/deleted"; say '{}' ;;
    "GET $web/releases/download/"*)
        if [ "$CURL_FAIL" = back ]; then echo corrupt >"$out"; else cp "$S/asset.zip" "$out"; fi ;;
    "GET $web/raw/branch/main/"*)
        git --git-dir="$SERVER_URL/$REPOSITORY.git" show "main:${url#"$web/raw/branch/main/"}" ;;
    *) echo "curl stub: unexpected $m $url" >&2; exit 22 ;;
esac
EOF
chmod 755 "$STUBS/curl"

# git wrapper: records argv and whether the token came in through
# GIT_CONFIG_* (never through argv), then runs the real git
REAL_GIT=$(command -v git)
cat >"$STUBS/git" <<EOF
#!/usr/bin/env bash
if [ -n "\${CURL_STATE:-}" ]; then
    printf '%s\\n' "\$*" >>"\$CURL_STATE/git-argv.log"
    envauth=no
    for ((i = 0; i < \${GIT_CONFIG_COUNT:-0}; i++)); do
        k=GIT_CONFIG_KEY_\$i v=GIT_CONFIG_VALUE_\$i
        [ "\${!k}" = http.extraHeader ] && [ "\${!v}" = "Authorization: token \$CURL_TOKEN" ] && envauth=yes
    done
    printf '%s\\t%s\\t%s\\n' "\${1:-}" "\$envauth" "\${GIT_HTTP_LOW_SPEED_LIMIT:--}/\${GIT_HTTP_LOW_SPEED_TIME:--}" >>"\$CURL_STATE/git-env.tsv"
fi
exec "$REAL_GIT" "\$@"
EOF
chmod 755 "$STUBS/git"

# release_case <name> <built version> [side|back|publishlost|draftlost]: a forge repo with a
# fork-owned module.prop (SYNC_ROOT_PROP), a built zip with that version, one
# release run. With "side" the dispatched commit is on a branch other than
# main; with "back" the asset downloaded back is corrupt (fails after the draft);
# with "publishlost" or "draftlost" the publish or draft request gets no reply.
release_case() {
    local built=$2 d="$W/$1"
    rm -rf "$d"
    mkdir -p "$d/forge/owner" "$d/seed/.forgejo" "$d/state" "$d/run" "$d/src/.ci-out"
    git init -q --bare -b main "$d/forge/$REPOSITORY.git"
    printf 'id=mod\nname=Mod\nversion=v1.0\nversionCode=5\nupdateJson=https://example.invalid/update.json\n' >"$d/seed/module.prop"
    printf 'ZIP_PREFIX=mod\nVERSION_CODE_FLOOR=1\nSYNC_ROOT_PROP=module.prop\n' >"$d/seed/.forgejo/module-ci.conf"
    git -C "$d/seed" init -q -b main
    git -C "$d/seed" add -A
    git -C "$d/seed" commit -qm seed
    git -C "$d/seed" push -q "$d/forge/$REPOSITORY.git" main
    if [ "$3" = side ]; then
        git -C "$d/seed" checkout -q -b side
        echo side >"$d/seed/side.txt"
        git -C "$d/seed" add side.txt
        git -C "$d/seed" commit -qm side
        git -C "$d/seed" push -q "$d/forge/$REPOSITORY.git" side
    fi
    BASE=$(git -C "$d/seed" rev-parse HEAD)
    echo "$BASE" >"$d/state/base"
    printf '%s\n\n' "$BASE" >"$d/src/.ci-out/src"
    echo "test build" >"$d/src/.ci-out/desc"
    python3 -I - "$d/src/.ci-out/module.zip" "$built" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("module.prop", f"id=mod\nname=Mod\nversion={sys.argv[2]}\nversionCode=5\nupdateJson=https://example.invalid/update.json\n")
    z.writestr("service.sh", "#!/system/bin/sh\n")
PY
    VERSION=$(printf '%s' "$built" | sed -E 's/-(fork|ci)[0-9]+$//')-ci3
    TAG=$(printf '%s' "$VERSION" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/-+/-/g; s/^-//; s/-$//')
    case "$TAG" in v*) ;; *) TAG="v$TAG" ;; esac
    echo "$TAG/mod-$TAG.zip" >"$d/state/tag"
    (
        cd "$d/run" &&
            PATH="$STUBS:$PATH" CURL_STATE="$d/state" CURL_TOKEN=$TOKEN CURL_FAIL=${3:-} \
                SERVER_URL="$d/forge" REPOSITORY=$REPOSITORY \
                BASE_SHA=$BASE RELEASE_TOKEN=$TOKEN RUN_NUMBER=3 \
                timeout 120 bash "$ROOT/.forgejo/module-ci.sh" release "$d/src"
    ) >"$d/log" 2>&1
    RC=$?
    UPDATE_URL="$d/forge/$REPOSITORY/raw/branch/main/.forgejo/update.json"
    MAIN_PROP=$(git --git-dir="$d/forge/$REPOSITORY.git" show main:module.prop 2>/dev/null)
    D=$d
}

release_case plain v1.0
check "release: exit 0" [ "$RC" = 0 ]
[ "$RC" = 0 ] || sed 's/^/    /' "$D/log"
check "release: published" [ -f "$D/state/published" ]
check "release: zip updateJson points at the forge" \
    [ "$(unzip -p "$D/state/asset.zip" module.prop | sed -n 's/^updateJson=//p')" = "$UPDATE_URL" ]
check "release: zip version" [ "$(unzip -p "$D/state/asset.zip" module.prop | sed -n 's/^version=//p')" = v1.0-ci3 ]
check "release: update.json in main" \
    [ "$(git --git-dir="$D/forge/$REPOSITORY.git" show main:.forgejo/update.json | python3 -I -c 'import json,sys;print(json.load(sys.stdin)["versionCode"])')" = 5 ]
check "release: fork module.prop synced" [ "$MAIN_PROP" = "id=mod
name=Mod
version=v1.0-ci3
versionCode=5
updateJson=$UPDATE_URL" ]

# The built version comes from the build output: it must reach the fork's
# module.prop as text, never as part of the sed program
synced() {
    [ "$MAIN_PROP" = "id=mod
name=Mod
version=$1
versionCode=5
updateJson=$UPDATE_URL" ]
}
release_case inject "\$(touch $W/pwned)|e;#"
check "release, version with a sed command: exit 0" [ "$RC" = 0 ]
check "release, version with a sed command: nothing run" [ ! -e "$W/pwned" ]
check "release, version with a sed command: module.prop synced as text" synced "\$(touch $W/pwned)|e;#-ci3"
release_case special 'v1.0&b\\c|d'
check "release, version with & \\ |: exit 0" [ "$RC" = 0 ]
check "release, version with & \\ |: module.prop synced as text" synced 'v1.0&b\\c|d-ci3'

# The release must be built from a commit on main
release_case side v1.0 side
check "release from a commit not on main: refused" [ "$RC" != 0 ]
check "release from a commit not on main: nothing published" [ ! -f "$D/state/published" ]
check "release from a commit not on main: no draft left" sh -c '[ ! -f "$1/state/asset.zip" ] || [ -f "$1/state/deleted" ]' sh "$D"

# The release token never appears in argv: curl gets it from a 0600 header
# file (-H @file) that is removed on exit, git through GIT_CONFIG_* variables
no_token_in_argv() {
    [ -s "$1/state/argv.log" ] && [ -s "$1/state/git-argv.log" ] &&
        ! grep -qF "$TOKEN" "$1/state/argv.log" "$1/state/git-argv.log"
}
api_auth_from_file() {
    awk -F'\t' -v api="$1/forge/api/v1/repos/$REPOSITORY" -v m="${2:-}" '
        index($2, api) == 1 && (m == "" || $1 == m) { n++; if ($6 != "file-ok") bad++ }
        END { exit !(n > 0 && bad == 0) }' "$1/state/calls.tsv"
}
header_file_0600_and_gone() {
    local files f
    files=$(awk -F'\t' '$7 != "-" { print $7 }' "$1/state/calls.tsv" | sort -u)
    [ -n "$files" ] || return 1
    awk -F'\t' '$7 != "-" && $8 != "600" { bad = 1 } END { exit bad }' "$1/state/calls.tsv" || return 1
    for f in $files; do [ ! -e "$f" ] || return 1; done
}
git_auth_from_env() {
    awk -F'\t' '$1 == "clone" && $2 == "yes" { c = 1 } $1 == "push" && $2 == "yes" { p = 1 }
        END { exit !(c && p) }' "$1/state/git-env.tsv"
}
release_case token v1.0
check "release: exit 0 (token case)" [ "$RC" = 0 ]
check "release: token in no curl or git argv" no_token_in_argv "$D"
check "release: every API call sends the header from a file" api_auth_from_file "$D"
check "release: git gets the token through GIT_CONFIG_*" git_auth_from_env "$D"
check "release: header file 0600 and removed" header_file_0600_and_gone "$D"
release_case tokenfail v1.0 back
check "failed release: exit 1" [ "$RC" != 0 ]
check "failed release: draft deleted" [ -f "$D/state/deleted" ]
check "failed release: token in no curl or git argv" no_token_in_argv "$D"
check "failed release: draft DELETE sends the header from a file" api_auth_from_file "$D" DELETE
check "failed release: header file 0600 and removed" header_file_0600_and_gone "$D"
# the forge applied the publish PATCH but its reply was lost: the release stays
release_case lost v1.0 publishlost
check "publish reply lost: exit 1" [ "$RC" != 0 ]
check "publish reply lost: published release not deleted" [ ! -f "$D/state/deleted" ]
# the draft request failed or the forge made the draft and the reply was lost: no id to delete by
release_case draftlost v1.0 draftlost
check "draft reply lost: exit 1" [ "$RC" != 0 ]
check "draft reply lost: one draft request, nothing deleted or published" \
    sh -c '[ "$(awk -F"\t" -v u="$2" "\$1 == \"POST\" && \$2 == u" "$1/state/calls.tsv" | wc -l)" = 1 ] && [ ! -f "$1/state/deleted" ] && [ ! -f "$1/state/published" ]' \
    sh "$D" "$D/forge/api/v1/repos/$REPOSITORY/releases"
check "draft reply lost: tag logged for a check by hand" grep -qF "the draft request for $TAG failed or its reply was lost" "$D/log"

# Every curl call is time-limited, and only reads are retried (a retried
# POST/PATCH/DELETE can repeat a change the forge already made)
all_calls_time_limited() {
    awk -F'\t' '{ n++; if ($3 == "-" || $4 == "-") bad++ } END { exit !(n > 0 && bad == 0) }' "$1/state/calls.tsv"
}
no_retry_on_changes() {
    awk -F'\t' '$1 ~ /^(POST|PATCH|DELETE)$/ { n++; if ($5 != "-") bad++ } END { exit !(n > 0 && bad == 0) }' "$1/state/calls.tsv"
}
reads_retried() {
    awk -F'\t' -v api="$1/forge/api/v1/repos/$REPOSITORY" '$1 == "GET" && index($2, api) == 1 && $3 != "-" && $5 != "-" { r = 1 }
        END { exit !r }' "$1/state/calls.tsv"
}
check "release: every curl call has connect and total time limits" all_calls_time_limited "$W/token"
check "release: no retry on POST, PATCH or DELETE" no_retry_on_changes "$W/token"
check "failed release: no retry on the draft DELETE" no_retry_on_changes "$W/tokenfail"
check "failed release: every curl call has time limits" all_calls_time_limited "$W/tokenfail"
check "release: API reads are still retried" reads_retried "$W/token"
# git has no time limit of its own: every git call gets a stall limit
# (GIT_HTTP_LOW_SPEED_*) from the environment
git_stall_limited() {
    awk -F'\t' '{ n++; if ($3 !~ /^[0-9]+\/[0-9]+$/) bad++ } END { exit !(n > 0 && bad == 0) }' "$1/state/git-env.tsv"
}
check "release: every git call has a stall limit" git_stall_limited "$W/token"
check "failed release: every git call has a stall limit" git_stall_limited "$W/tokenfail"

# Build step, offline. setpriv and chown are stubs: the build runs as the
# tester (no uid change), and the stub records "kill -9 -1" and never runs it. build() in
# module-ci.conf plays the untrusted build: it leaves files in $OUT the way
# build code could. After the build root must follow no link in $OUT.
# Build mode runs only inside a container and only when asked for
# (PD_TEST_BUILD_MODE=1): with the real setpriv on PATH it would kill every
# process of the build uid, which on a workstation is the tester.
cat >"$STUBS/setpriv" <<'EOF2'
#!/bin/sh
# setpriv stub: drops the options and runs the command as is, except kill
case " $* " in *" kill "*) echo "kill-requested $*" >>"$SETPRIV_LOG"; exit 0 ;; esac
while [ $# -gt 0 ]; do case "$1" in --*) shift ;; *) break ;; esac; done
exec "$@"
EOF2
printf '#!/bin/sh\nexit 0\n' >"$STUBS/chown"
chmod 755 "$STUBS/setpriv" "$STUBS/chown"

# build_case <name> <body of build()> [NAME=value...]: V in the body is a
# folder outside the build with a file "file" (content: precious) and a file
# "secret"; NAME=value are extra variables in the environment of the build step
build_case() {
    local d="$W/b-$1" body=$2
    shift 2
    rm -rf "$d"
    mkdir -p "$d/work/.forgejo" "$d/v"
    cp "$ROOT/.forgejo/module-ci.sh" "$d/work/.forgejo/module-ci.sh"
    printf 'V=%s\nbuild() { %s; }\n' "$d/v" "$body" >"$d/work/.forgejo/module-ci.conf"
    echo precious >"$d/v/file"
    echo "secret line" >"$d/v/secret"
    git -C "$d/work" init -q -b main
    git -C "$d/work" add -A
    git -C "$d/work" commit -qm seed
    : >"$d/setpriv.log"
    (
        cd "$d" &&
            PATH="$STUBS:$PATH" SETPRIV_LOG="$d/setpriv.log" SERVER_URL=https://forge.example.invalid REPOSITORY=$REPOSITORY \
                BASE_SHA="$(git -C "$d/work" rev-parse HEAD)" \
                env "$@" timeout 120 bash "$d/work/.forgejo/module-ci.sh" build "$d/work"
    ) >"$d/log" 2>&1
    RC=$?
    D=$d
}
not_in_env() {
    [ -s "$1/work/.ci-out/env" ] && ! grep -q "^$2" "$1/work/.ci-out/env"
}
not_in_desc() {
    ! grep -qs "secret line" "$1/work/.ci-out/desc" "$1/work/.ci-out.old/desc"
}
if [ "${PD_TEST_BUILD_MODE:-}" != 1 ] || [ ! -f /.dockerenv ]; then
    echo "skip build step (only in a container with PD_TEST_BUILD_MODE=1)"
elif [ "$(PATH="$STUBS:$PATH" command -v setpriv)" = "$STUBS/setpriv" ]; then
    build_case plain 'printf x >"$OUT/module.zip"; echo "upstream 1.0" >"$OUT/upstream-desc"; tr "\\0" "\\n" </proc/$$/environ >"$OUT/env"; env >"$OUT/env.build"'
    check "build: exit 0" [ "$RC" = 0 ]
    [ "$RC" = 0 ] || sed 's/^/    /' "$D/log"
    check "build: the build user gets no git stall limit" not_in_env "$D" GIT_HTTP_LOW_SPEED_
    check "build: build() gets no git stall limit" sh -c '[ -s "$1" ] && ! grep -q "^GIT_HTTP_LOW_SPEED_" "$1"' sh "$D/work/.ci-out/env.build"
    check "build: desc from upstream-desc" [ "$(cat "$D/work/.ci-out/desc")" = "upstream 1.0" ]
    check "build: the build user's processes are killed after the build" grep -q -e '^kill-requested .*--reuid=1000 .*kill -9 -1' "$D/setpriv.log"
    # a failed build: whatever the build user started is killed before the script stops
    build_case failed 'echo "example build failure" >&2; return 1'
    check "build failed: exit non-zero with the build's error" \
        sh -c '[ "$1" != 0 ] && grep -q "example build failure" "$2" && ! grep -q "unbound variable" "$2"' sh "$RC" "$D/log"
    check "build failed: the build user's processes are killed too" grep -q -e '^kill-requested .*--reuid=1000 .*kill -9 -1' "$D/setpriv.log"
    # The build step's own helper names must not let an exported variable
    # of the same name (or readonly SHELLOPTS) through to the build user
    build_case names 'printf x >"$OUT/module.zip"; tr "\\0" "\\n" </proc/$$/environ >"$OUT/env"' \
        keep=x drop=x v=x e=x SHELLOPTS=braceexpand:hashall:interactive-comments
    check "build with exported keep/drop/v/e: exit 0" [ "$RC" = 0 ]
    check "build with exported keep/drop/v/e: SHELLOPTS not passed" not_in_env "$D" SHELLOPTS=
    check "build with exported keep/drop/v/e: none of them passed" sh -c '! grep -qE "^(keep|drop|v|e)=" "$1"' sh "$D/work/.ci-out/env"
    # the build step's result variable must not come from the environment
    build_case rcenv 'printf x >"$OUT/module.zip"' build_rc=1
    check "build with an exported build_rc: a good build passes" [ "$RC" = 0 ]
    build_case desclink 'printf x >"$OUT/module.zip"; echo planted >"$OUT/upstream-desc"; ln -s "$V/file" "$OUT/desc"'
    check "build, desc planted as a link: file behind it untouched" [ "$(cat "$D/v/file")" = precious ]
    check "build, desc planted as a link: desc written as a file" \
        sh -c '[ -f "$1" ] && [ ! -L "$1" ] && [ "$(cat "$1")" = planted ]' sh "$D/work/.ci-out/desc"
    build_case uplink 'printf x >"$OUT/module.zip"; ln -s "$V/secret" "$OUT/upstream-desc"'
    check "build, upstream-desc planted as a link: refused" [ "$RC" != 0 ]
    check "build, upstream-desc planted as a link: file behind it not copied" not_in_desc "$D"
    build_case uphard 'printf x >"$OUT/module.zip"; ln "$V/secret" "$OUT/upstream-desc"'
    check "build, upstream-desc planted as a hard link: refused" [ "$RC" != 0 ]
    check "build, upstream-desc planted as a hard link: file not copied" not_in_desc "$D"
    build_case outlink 'printf x >"$V/module.zip"; mv "$OUT" "$OUT.old"; ln -s "$V" "$OUT"'
    check "build, output folder replaced by a link: refused" [ "$RC" != 0 ]
    check "build, output folder replaced by a link: nothing written behind it" [ ! -e "$D/v/desc" ]

    # This repo's own build() (module-ci.conf) runs tests/run.sh before it
    # builds: a failing test fails the build. The upstream merge is turned off
    # (no network here) and build.sh is a stub that leaves a zip; tests/run.sh
    # is a stub (exit $2) that saves its environment, or the real suite ("real").
    conf_case() {
        local d="$W/c-$1"
        rm -rf "$d"
        mkdir -p "$d/work/.forgejo" "$d/work/tests"
        if [ "$2" = real ]; then
            cp -R "$ROOT/." "$d/work/"
            rm -rf "$d/work/.git"
        else
            printf '#!/bin/sh\nenv >"$OUT/tests.env"\nexit %s\n' "$2" >"$d/work/tests/run.sh"
        fi
        cp "$ROOT/.forgejo/module-ci.sh" "$d/work/.forgejo/module-ci.sh"
        { cat "$ROOT/.forgejo/module-ci.conf"; echo 'UPSTREAM_URL=""'; } >"$d/work/.forgejo/module-ci.conf"
        printf '#!/bin/sh\nmkdir -p "$OUT_DIR" && printf x >"$OUT_DIR/play-detach-test.zip"\n' >"$d/work/build.sh"
        git -C "$d/work" init -q -b main
        git -C "$d/work" add -A
        git -C "$d/work" commit -qm seed
        : >"$d/setpriv.log"
        (
            cd "$d" &&
                PATH="$STUBS:$PATH" SETPRIV_LOG="$d/setpriv.log" SERVER_URL=https://forge.example.invalid REPOSITORY=$REPOSITORY \
                    BASE_SHA="$(git -C "$d/work" rev-parse HEAD)" RELEASE_TOKEN=not-for-the-build \
                    timeout 900 bash "$d/work/.forgejo/module-ci.sh" build "$d/work"
        ) >"$d/log" 2>&1
        RC=$?
        D=$d
    }
    conf_case tfail 1
    check "build, a test fails: the build fails" sh -c '[ "$1" != 0 ] && grep -q "build failed" "$2" && [ ! -e "$3" ]' sh "$RC" "$D/log" "$D/work/.ci-out/module.zip"
    conf_case tpass 0
    check "build, tests pass: the build passes" sh -c '[ "$1" = 0 ] && [ -f "$2" ]' sh "$RC" "$D/work/.ci-out/module.zip"
    check "build, tests ran with scratch in the build area, under bash, without the token" \
        sh -c 'grep -qx "TMPDIR=$2/.ci-home/tmp" "$1" && grep -qx "SH=bash" "$1" && ! grep -q "^RELEASE_TOKEN=" "$1"' sh "$D/work/.ci-out/tests.env" "$D/work"
    conf_case treal real
    check "build, the real tests/run.sh passes in the build step" [ "$RC" = 0 ]
    [ "$RC" = 0 ] || grep -E '^FAIL|^passed' "$D/log" | sed 's/^/    /'
else
    no "build: setpriv stub not first on PATH"
fi
