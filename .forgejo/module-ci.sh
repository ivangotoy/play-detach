#!/usr/bin/env bash
# Generic KernelSU module release pipeline (identical in every module repo).
#
# Run by .forgejo/workflows/module-release.yml from a full clone of main.
# Per-repo settings live in .forgejo/module-ci.conf (sourced shell):
#   UPSTREAM_URL, UPSTREAM_BRANCH   upstream to merge into main ("" = none)
#   ZIP_PREFIX                      release zip name prefix
#   VERSION_CODE_FLOOR              lowest versionCode allowed to release
#   VERSION_CODE_OFFSET             added to the built versionCode (default 0)
#   UPDATE_JSON_PATH                update.json path in main (default .forgejo/update.json)
#   SYNC_ROOT_PROP                  module.prop in main to keep at the released version ("" = none)
#   CHANGELOG_PATH                  changelog file in the tree ("" = none)
#   build()                         builds the module zip, prints nothing on stdout but
#                                   may log on stderr; must leave exactly one zip at "$OUT/module.zip"
#   prebuilt()                      optional: instead of the merge, supplies "$OUT/module.zip"
#                                   and sets UPSTREAM_DESC (repack of an upstream release)
# Flow: merge upstream -> build -> set updateJson/version in the zip -> draft release ->
# upload -> download back and verify -> push merge -> publish -> commit update.json.
# Any failure before publish deletes the draft and pushes nothing.
set -euo pipefail

: "${FORGEJO_TOKEN:?}" "${SERVER_URL:?}" "${REPOSITORY:?}" "${RUN_NUMBER:?}"
API="$SERVER_URL/api/v1/repos/$REPOSITORY"
REPO_NAME="${REPOSITORY#*/}"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
OUT="$ROOT/.ci-out"
rm -rf "$OUT"; mkdir -p "$OUT"
export GIT_AUTHOR_NAME="Ivan Angelov" GIT_AUTHOR_EMAIL="ivangotoy@gmail.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

UPSTREAM_URL="" UPSTREAM_BRANCH="" ZIP_PREFIX="$REPO_NAME" VERSION_CODE_FLOOR=0 VERSION_CODE_OFFSET=0
UPDATE_JSON_PATH=".forgejo/update.json" SYNC_ROOT_PROP="" CHANGELOG_PATH="" UPSTREAM_DESC=""
. .forgejo/module-ci.conf

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
auth() { printf 'Authorization: token %s' "$FORGEJO_TOKEN"; }
api() { local m="$1" p="$2"; shift 2; curl -sS --fail-with-body --retry 3 -X "$m" -H "$(auth)" "$@" "$API$p"; }
http_code() { curl -sS -o /dev/null -w '%{http_code}' -H "$(auth)" "$API$1"; }
jget() { python3 -I -c 'import json,sys;d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d[k] if not k.isdigit() else d[int(k)]
print(d)' "$1"; }
git_auth() { git -c "http.extraHeader=$(auth)" "$@"; }
prop_get() { sed -n "s/^$1=//p" "$2" | head -n1 | tr -d '\r'; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

# pack_paths <path...>: zip the listed tree paths (helper for script modules)
pack_paths() { (cd "$ROOT" && zip -qr9 -X "$OUT/module.zip" "$@" -x '*/.gitkeep'); }

RELEASE_ID=""
cleanup() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ -n "$RELEASE_ID" ] && [ "${PUBLISHED:-0}" != 1 ]; then
        log "failure before publish: deleting draft release $RELEASE_ID"
        api DELETE "/releases/$RELEASE_ID" >/dev/null || true
    fi
    exit "$rc"
}
trap cleanup EXIT

# 1. upstream merge (main only, merge, never rebase)
BASE_SHA="$(git rev-parse HEAD)"
if declare -F prebuilt >/dev/null; then
    log "prebuilt source"
    ( unset FORGEJO_TOKEN; prebuilt )
    UPSTREAM_DESC="$(cat "$OUT/upstream-desc" 2>/dev/null || true)"
elif [ -n "$UPSTREAM_URL" ]; then
    log "merging $UPSTREAM_URL $UPSTREAM_BRANCH"
    git fetch -q "$UPSTREAM_URL" "$UPSTREAM_BRANCH"
    UP_SHA="$(git rev-parse FETCH_HEAD)"
    UP_NAME="${UPSTREAM_URL#https://github.com/}"; UP_NAME="${UP_NAME%.git}"
    if git merge-base --is-ancestor "$UP_SHA" HEAD; then
        log "upstream $UP_SHA already merged"
    else
        git merge -q --no-edit -m "Merge $UP_NAME $UPSTREAM_BRANCH ${UP_SHA:0:12}" "$UP_SHA" \
            || die "merge conflict with upstream $UP_SHA: resolve by hand"
    fi
    UPSTREAM_DESC="$UP_NAME@$UPSTREAM_BRANCH ${UP_SHA:0:12}"
fi
SRC_SHA="$(git rev-parse HEAD)"

# 2. build (no forge token in the build environment)
if ! declare -F prebuilt >/dev/null; then
    log "building $SRC_SHA"
    ( unset FORGEJO_TOKEN; build )
fi
[ -f "$OUT/module.zip" ] || die "build left no $OUT/module.zip"

# 3. version and updateJson inside the zip
mkdir -p "$OUT/orig"
unzip -p "$OUT/module.zip" module.prop > "$OUT/orig/module.prop" || die "zip has no module.prop at its root"
BUILT_VERSION="$(prop_get version "$OUT/orig/module.prop")"
BUILT_VC="$(prop_get versionCode "$OUT/orig/module.prop")"
case "$BUILT_VC" in ''|*[!0-9]*) die "built versionCode '$BUILT_VC' is not a number" ;; esac
BASE_VERSION="$(printf '%s' "$BUILT_VERSION" | sed -E 's/-(fork|ci)[0-9]+$//')"
VERSION="$BASE_VERSION-ci$RUN_NUMBER"
VC=$((BUILT_VC + VERSION_CODE_OFFSET))
[ "$VC" -ge "$VERSION_CODE_FLOOR" ] || die "versionCode $VC is below the floor $VERSION_CODE_FLOOR"
TAG="$(printf '%s' "$VERSION" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/-+/-/g; s/^-//; s/-$//')"
case "$TAG" in v*) ;; *) TAG="v$TAG" ;; esac
ZIP_NAME="$ZIP_PREFIX-$TAG.zip"
UPDATE_URL="$SERVER_URL/$REPOSITORY/raw/branch/main/$UPDATE_JSON_PATH"
ZIP_URL="$SERVER_URL/$REPOSITORY/releases/download/$TAG/$ZIP_NAME"
CHANGELOG_URL=""
[ -n "$CHANGELOG_PATH" ] && [ -f "$CHANGELOG_PATH" ] && CHANGELOG_URL="$SERVER_URL/$REPOSITORY/raw/commit/$SRC_SHA/$CHANGELOG_PATH"
log "version $VERSION versionCode $VC tag $TAG"

python3 -I - "$OUT/module.zip" "$OUT/$ZIP_NAME" "$VERSION" "$VC" "$UPDATE_URL" <<'PY'
import hashlib, sys, zipfile
src, dst, version, vc, url = sys.argv[1:]
zin = zipfile.ZipFile(src)
lines, seen = [], set()
for line in zin.read("module.prop").decode().splitlines():
    k = line.split("=", 1)[0]
    if k in ("version", "versionCode", "updateJson"):
        if k in seen:
            continue
        seen.add(k)
        line = f"{k}=" + {"version": version, "versionCode": vc, "updateJson": url}[k]
    lines.append(line)
for k, v in (("version", version), ("versionCode", vc), ("updateJson", url)):
    if k not in seen:
        lines.append(f"{k}={v}")
prop = ("\n".join(lines) + "\n").encode()
names = zin.namelist()
with zipfile.ZipFile(dst, "w") as zout:
    for info in zin.infolist():
        data = zin.read(info)
        if info.filename == "module.prop":
            data = prop
        elif info.filename == "module.prop.sha256":
            data = hashlib.sha256(prop).hexdigest().encode()
        zi = zipfile.ZipInfo(info.filename, info.date_time)
        zi.compress_type, zi.external_attr, zi.create_system = info.compress_type, info.external_attr, info.create_system
        zout.writestr(zi, data, compresslevel=9 if info.compress_type == zipfile.ZIP_DEFLATED else None)
PY
ZIP="$OUT/$ZIP_NAME"
unzip -tq "$ZIP" >/dev/null || die "zip test failed"
[ "$(unzip -p "$ZIP" module.prop | prop_get updateJson /dev/stdin)" = "$UPDATE_URL" ] || die "updateJson not set"
ZIP_SHA="$(sha "$ZIP")"
log "zip $ZIP_NAME sha256 $ZIP_SHA"

# 4. draft release, upload, download back, verify
[ "$(http_code "/releases/tags/$TAG")" = 404 ] || die "release $TAG exists (or the check failed)"
[ "$(http_code "/tags/$TAG")" = 404 ] || die "tag $TAG exists (or the check failed)"
BODY="$(printf 'Built by module-release #%s from %s (%s).\nversionCode %s\nsha256 %s  %s\nupdateJson %s' \
    "$RUN_NUMBER" "${SRC_SHA:0:12}" "${UPSTREAM_DESC:-fork main}" "$VC" "$ZIP_SHA" "$ZIP_NAME" "$UPDATE_URL")"
REQ="$(python3 -I -c 'import json,sys;print(json.dumps({"tag_name":sys.argv[1],"target_commitish":"main","name":sys.argv[2],"body":sys.argv[3],"draft":True}))' "$TAG" "$ZIP_PREFIX $VERSION" "$BODY")"
RELEASE_ID="$(api POST /releases -H 'Content-Type: application/json' -d "$REQ" | jget id)"
log "draft release $RELEASE_ID"
log "uploading $ZIP_NAME"
ASSET_ID="$(api POST "/releases/$RELEASE_ID/assets?name=$ZIP_NAME" -F "attachment=@$ZIP" | jget id)"
log "reading back asset $ASSET_ID"
api GET "/releases/$RELEASE_ID/assets/$ASSET_ID" | jget browser_download_url > "$OUT/asset-url"
log "downloading $(cat "$OUT/asset-url")"
curl -sSL --fail-with-body -H "$(auth)" -o "$OUT/back.zip" "$(cat "$OUT/asset-url")"
[ "$(sha "$OUT/back.zip")" = "$ZIP_SHA" ] || die "downloaded asset sha256 differs"
unzip -tq "$OUT/back.zip" >/dev/null || die "downloaded asset fails zip test"

# 5. push the merge (fast-forward only), publish at the built commit
if [ "$SRC_SHA" != "$BASE_SHA" ]; then
    log "pushing merge $SRC_SHA"
    git_auth push -q origin "$SRC_SHA:refs/heads/main" || die "push of the merge failed (main moved?)"
fi
REQ="$(python3 -I -c 'import json,sys;print(json.dumps({"draft":False,"target_commitish":sys.argv[1]}))' "$SRC_SHA")"
api PATCH "/releases/$RELEASE_ID" -H 'Content-Type: application/json' -d "$REQ" >/dev/null
PUBLISHED=1
TAG_SHA="$(api GET "/tags/$TAG" | jget commit.sha)"
[ "$TAG_SHA" = "$SRC_SHA" ] || die "published tag $TAG points at $TAG_SHA, expected $SRC_SHA"
for i in 1 2 3 4 5; do
    curl -fsSL -o "$OUT/anon.zip" "$ZIP_URL" && break; sleep 5
done
[ "$(sha "$OUT/anon.zip")" = "$ZIP_SHA" ] || die "anonymous download of $ZIP_URL differs"
log "published $TAG"

# 6. update.json (and the fork-owned module.prop) in main
git fetch -q origin main 2>/dev/null || git_auth fetch -q origin main
git checkout -q -B main FETCH_HEAD
mkdir -p "$(dirname "$UPDATE_JSON_PATH")"
python3 -I - "$UPDATE_JSON_PATH" "$VERSION" "$VC" "$ZIP_URL" "$CHANGELOG_URL" <<'PY'
import json, sys
path, version, vc, zip_url, changelog = sys.argv[1:]
with open(path, "w") as f:
    f.write(json.dumps({"version": version, "versionCode": int(vc), "zipUrl": zip_url, "changelog": changelog}, indent=2) + "\n")
PY
git add -- "$UPDATE_JSON_PATH"
if [ -n "$SYNC_ROOT_PROP" ]; then
    sed -i -E "s|^version=.*|version=$VERSION|; s|^versionCode=.*|versionCode=$VC|; s|^updateJson=.*|updateJson=$UPDATE_URL|" "$SYNC_ROOT_PROP"
    git add -- "$SYNC_ROOT_PROP"
fi
git commit -q -m "update.json: $VERSION (versionCode $VC)"
git_auth push -q origin HEAD:refs/heads/main || die "push of update.json failed"
for i in 1 2 3 4 5; do
    got="$(curl -fsS "$UPDATE_URL" | jget versionCode || true)"
    [ "$got" = "$VC" ] && break; sleep 5
done
[ "$got" = "$VC" ] || die "$UPDATE_URL answers versionCode '$got', expected $VC"
log "done: $UPDATE_URL -> $TAG"
