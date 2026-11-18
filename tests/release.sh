#!/usr/bin/env bash
# Offline test of the release step of .forgejo/module-ci.sh, called by
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
m=GET out="" w="" url="" upload=""
while [ $# -gt 0 ]; do
    case "$1" in
        -X) m=$2; shift ;;
        -o) out=$2; shift ;;
        -w) w=$2; shift ;;
        -F) upload=${2#attachment=@}; shift ;;
        -H | -d | --retry) shift ;;
        -*) ;;
        *) url=$1 ;;
    esac
    shift
done
api="$SERVER_URL/api/v1/repos/$REPOSITORY"
web="$SERVER_URL/$REPOSITORY"
say() { if [ -n "$out" ]; then printf '%s' "$1" >"$out"; else printf '%s' "$1"; fi; }
case "$m $url" in
    "GET $api/releases/tags/"* | "GET $api/tags/"*)
        if [ -n "$w" ]; then printf 404; exit 0; fi
        say "{\"commit\": {\"sha\": \"$(cat "$S/base")\"}}" ;;
    "POST $api/releases") say '{"id": 7}' ;;
    "POST $api/releases/7/assets?name="*)
        cp "$upload" "$S/asset.zip" && say '{"id": 9}' ;;
    "GET $api/releases/7/assets/9")
        say "{\"browser_download_url\": \"$web/releases/download/$(cat "$S/tag")\"}" ;;
    "PATCH $api/releases/7") touch "$S/published"; say '{}' ;;
    "DELETE $api/releases/7") touch "$S/deleted"; say '{}' ;;
    "GET $web/releases/download/"*) cp "$S/asset.zip" "$out" ;;
    "GET $web/raw/branch/main/"*)
        git --git-dir="$SERVER_URL/$REPOSITORY.git" show "main:${url#"$web/raw/branch/main/"}" ;;
    *) echo "curl stub: unexpected $m $url" >&2; exit 22 ;;
esac
EOF
chmod 755 "$STUBS/curl"

# release_case <name> <built version>: a forge repo with a fork-owned
# module.prop (SYNC_ROOT_PROP), a built zip with that version, one release run
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
            PATH="$STUBS:$PATH" CURL_STATE="$d/state" SERVER_URL="$d/forge" REPOSITORY=$REPOSITORY \
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
