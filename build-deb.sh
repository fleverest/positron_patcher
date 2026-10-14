#!/usr/bin/env bash
# Rebuild Positron extensions from source with patches/*.patch applied, and
# repackage the installed Positron .deb with the rebuilt bundles into build/.
#
# Only patches under extensions/<name>/ are supported (no full Positron build).
#
# Env overrides:
#   POSITRON_COMMIT  commit to patch against (default: from `positron --version`)
#   ORIG_DEB         original .deb to repackage (default: dpkg-repack the install)
#   PKG              installed package name (default: positron)
#   NODE_IMAGE       container image used when host node is missing/too old
#
# Usage: build-deb.sh            build build/<pkg>_<ver>+patched.<hash>_<arch>.deb
#        build-deb.sh --overlay  instead copy the rebuilt bundles over the installed
#                                Positron in place (any distro; uses sudo, keeps
#                                *.orig backups). Re-run after each Positron upgrade.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
PATCH_DIR=$ROOT/patches
BUILD=$ROOT/build
SRC=$BUILD/src
PKG=${PKG:-positron}
REPO=https://github.com/posit-dev/positron.git
EXT_PREFIX=usr/share/positron/resources/app/extensions

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

NODE_IMAGE=${NODE_IMAGE:-docker.io/library/node:22}

have_node() {
	command -v node >/dev/null && command -v npm >/dev/null &&
		node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22||(a===22&&b>=6)?0:1)'
}

# build_exts SRC LOCKFILE EXT... : npm install + esbuild each extension.
build_exts() {
	local src=$1 lock=$2 e d out specs; shift 2
	log "Installing build tooling"
	(cd "$src/extensions" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)
	for e in "$@"; do
		d=$src/extensions/$e
		[[ -f $d/esbuild.mts ]] || die "$e has no esbuild.mts at this commit"
		log "Building $e"
		(cd "$d" && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)
		if ! out=$(esbuild_ext "$d"); then
			# Some extensions import packages that only resolve from the repo-root
			# node_modules in a full checkout; install those at the root lock's versions.
			mapfile -t missing < <(grep -oP 'Could not resolve "\K[^."][^"]*' <<<"$out" |
				sed -E 's#^(@[^/]+/[^/]+|[^/]+).*#\1#' | sort -u)
			(( ${#missing[@]} )) || { echo "$out" >&2; die "build of $e failed"; }
			specs=$(node -e '
				const p = JSON.parse(require("fs").readFileSync(process.argv[1])).packages;
				console.log(process.argv.slice(2).map(n => {
					const v = p["node_modules/" + n]?.version; return v ? `${n}@${v}` : n;
				}).join(" "));' "$lock" "${missing[@]}")
			log "Installing root-level deps for $e: $specs"
			# shellcheck disable=SC2086
			(cd "$d" && npm i --no-save --ignore-scripts --no-audit --no-fund --loglevel=error $specs)
			out=$(esbuild_ext "$d") || { echo "$out" >&2; die "build of $e failed"; }
		fi
	done
}
esbuild_ext() { (cd "$1" && rm -rf dist && node --experimental-strip-types --no-warnings esbuild.mts) 2>&1; }

# Container entry point
if [[ ${1:-} == --build-exts ]]; then shift; build_exts "$@"; exit; fi

MODE=deb
[[ ${1:-} == --overlay ]] && MODE=overlay
tools=(git); [[ $MODE == deb ]] && tools+=(dpkg-deb)
for t in "${tools[@]}"; do command -v "$t" >/dev/null || die "missing $t"; done

shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
(( ${#patches[@]} )) || die "no patches in $PATCH_DIR"

# --- Installed version ------------------------------------------------------
if [[ -z ${POSITRON_COMMIT:-} ]]; then
	command -v positron >/dev/null || die "positron not on PATH; set POSITRON_COMMIT"
	# Positron prints a "Positron SHA: <sha>" line; fall back to the first bare SHA
	v=$(positron --version 2>/dev/null || true)
	POSITRON_COMMIT=$(grep -oP 'Positron SHA:\s*\K[0-9a-f]{40}' <<<"$v" ||
		grep -oE '\b[0-9a-f]{40}\b' <<<"$v" | head -1 || true)
fi
[[ $POSITRON_COMMIT =~ ^[0-9a-f]{40}$ ]] || die "bad commit '$POSITRON_COMMIT'"
log "Positron commit $POSITRON_COMMIT"

# --- Which extensions do the patches touch? ---------------------------------
mapfile -t paths < <(sed -n 's|^+++ b/||p; s|^--- a/||p' "${patches[@]}" | sort -u)
exts=()
for p in "${paths[@]}"; do
	[[ $p == extensions/*/* ]] || die "patch touches $p; only extensions/<name>/ is supported"
	e=${p#extensions/}; exts+=("${e%%/*}")
done
mapfile -t exts < <(printf '%s\n' "${exts[@]}" | sort -u)
log "Extensions to rebuild: ${exts[*]}"

# --- Source checkout at that commit ----------------------------------------
mkdir -p "$BUILD"
if [[ ! -d $SRC/.git ]]; then
	git clone -q --filter=blob:none --no-checkout "$REPO" "$SRC"
fi
git -C "$SRC" sparse-checkout set --cone "${exts[@]/#/extensions/}"
git -C "$SRC" cat-file -e "$POSITRON_COMMIT^{commit}" 2>/dev/null ||
	git -C "$SRC" fetch -q --filter=blob:none origin "$POSITRON_COMMIT"
git -C "$SRC" am --abort >/dev/null 2>&1 || true
git -C "$SRC" checkout -qf --detach "$POSITRON_COMMIT"

log "Applying ${#patches[@]} patch(es)"
GIT_COMMITTER_NAME=patcher GIT_COMMITTER_EMAIL=patcher@localhost \
	git -C "$SRC" am -q -3 "${patches[@]}"

# --- Build extensions --------------------------------------------------------
# Needs Node >= 22.6 (to run the .mts build scripts). Uses the host's node if
# new enough, otherwise runs this section in a node:22 container (podman/docker).
git -C "$SRC" show HEAD:package-lock.json >"$BUILD/root-lock.json"
if have_node; then
	build_exts "$SRC" "$BUILD/root-lock.json" "${exts[@]}"
else
	engine=$(command -v podman || command -v docker) ||
		die "need Node >= 22.6, or podman/docker to build in a container"
	log "No suitable node on host; building in $NODE_IMAGE via $(basename "$engine")"
	uargs=(--userns=keep-id)
	[[ $(basename "$engine") == docker ]] && uargs=(-u "$(id -u):$(id -g)")
	"$engine" run --rm "${uargs[@]}" -v "$ROOT:$ROOT" -w "$ROOT" \
		-e HOME=/tmp -e npm_config_cache="$BUILD/.npm-cache" \
		"$NODE_IMAGE" bash "$ROOT/build-deb.sh" --build-exts "$SRC" "$BUILD/root-lock.json" "${exts[@]}"
fi

# --- Overlay onto the installed Positron --------------------------------------
if [[ $MODE == overlay ]]; then
	command -v positron >/dev/null || die "positron not on PATH"
	app=$(dirname "$(readlink -f "$(command -v positron)")")
	extroot=
	for d in "$app/resources/app/extensions" "$app/../resources/app/extensions" \
		"$app/../share/positron/resources/app/extensions" /usr/share/positron/resources/app/extensions \
		/opt/positron/resources/app/extensions /opt/Positron/resources/app/extensions; do
		[[ -d $d/${exts[0]} ]] && { extroot=$(readlink -f "$d"); break; }
	done
	[[ -n $extroot ]] || die "could not find Positron's extensions directory near $app"
	SUDO=; [[ -w $extroot/${exts[0]}/dist ]] || SUDO=sudo
	log "Installing into $extroot${SUDO:+ (sudo)}"
	for e in "${exts[@]}"; do
		dst=$extroot/$e/dist
		[[ -d $dst ]] || die "$dst not found"
		for f in "$SRC/extensions/$e/dist/"*; do
			b=$dst/$(basename "$f")
			[[ -e $b && ! -e $b.orig ]] && $SUDO cp -p "$b" "$b.orig"
			$SUDO install -m 644 "$f" "$b"
		done
	done
	log "Done. Fully quit and restart Positron."
	echo "Revert with:"
	for e in "${exts[@]}"; do
		echo "  for f in $extroot/$e/dist/*.orig; do $SUDO mv \"\$f\" \"\${f%.orig}\"; done"
	done
	exit 0
fi

# --- Repackage ---------------------------------------------------------------
STAGE=$BUILD/pkg
rm -rf "$STAGE"
if [[ -z ${ORIG_DEB:-} ]]; then
	ORIG_DEB=$BUILD/orig-$POSITRON_COMMIT.deb
	if [[ ! -f $ORIG_DEB ]]; then
		command -v dpkg-repack >/dev/null || die "install dpkg-repack (and fakeroot), or set ORIG_DEB"
		log "Repacking installed $PKG (cached for next time; takes a minute)"
		tmp=$(mktemp -d "$BUILD/repack.XXXX")
		(cd "$tmp" && fakeroot -u dpkg-repack "$PKG" >/dev/null)
		mv "$tmp"/*.deb "$ORIG_DEB"; rmdir "$tmp"
	fi
fi
log "Unpacking $(basename "$ORIG_DEB")"
dpkg-deb -R "$ORIG_DEB" "$STAGE"

for e in "${exts[@]}"; do
	dst=$STAGE/$EXT_PREFIX/$e
	[[ -d $dst/dist ]] || die "$dst/dist not found in package"
	cp -f "$SRC/extensions/$e/dist/"* "$dst/dist/"
done

hash=$(cat "${patches[@]}" | sha256sum | cut -c1-8)
base=$(sed -n 's/^Version: //p' "$STAGE/DEBIAN/control" | sed 's/+patched\..*//')
version=$base+patched.$hash
sed -i "s/^Version: .*/Version: $version/" "$STAGE/DEBIAN/control"
arch=$(sed -n 's/^Architecture: //p' "$STAGE/DEBIAN/control")

if [[ -f $STAGE/DEBIAN/md5sums ]]; then
	log "Regenerating md5sums"
	(cd "$STAGE" && find . -path ./DEBIAN -prune -o -type f -printf '%P\0' |
		sort -z | xargs -0 md5sum) >"$STAGE/DEBIAN/md5sums"
fi

out=$BUILD/${PKG}_${version}_${arch}.deb
log "Building $(basename "$out")"
dpkg-deb --root-owner-group -Zgzip -b "$STAGE" "$out" >/dev/null
rm -rf "$STAGE"
log "Done: $out"
echo "Install with: sudo apt install $out"
