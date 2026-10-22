#!/bin/bash
# Init step of Deployment/memory-embedder: make sure the pinned model files are on the cache PVC
# (/cache, qnap-nfs, shared by both replicas), verified, and copy them to the pod-local emptyDir
# /model that the server reads. Runs in the TEI image itself (Debian: bash, curl, coreutils).
#
# Safety properties
#  - Everything is pinned: MODEL_REPO + MODEL_REVISION (a commit sha, never a branch) pick the bytes
#    and SHA256SUMS (next to this script, same ConfigMap) pins their content. A file that does not
#    match is never used.
#  - Bounded: every download has connect / total timeouts and a bounded retry count, the whole
#    script has a hard deadline. On failure it exits non-zero; the kubelet restarts the init
#    container with back-off and the pod stays in Init:Error / Init:CrashLoopBackOff (visible with
#    `kubectl -n memory get pods`, and MemoryEmbedderDown fires after 10 minutes).
#  - Atomic and concurrency-safe on the shared PVC: files land in a private temp directory and are
#    renamed into place as one directory only after verification. Two replicas starting together
#    both download (a few seconds each); whoever renames first wins, the other discards its copy.
#  - A restart with a verified cache needs no network at all.
set -euo pipefail
: "${MODEL_REPO:?}" "${MODEL_REVISION:?}"
cache=/cache
final="$cache/${MODEL_REPO//\//__}@${MODEL_REVISION}"
sums=/config/SHA256SUMS
out=/model
base="https://huggingface.co/${MODEL_REPO}/resolve/${MODEL_REVISION}"

verify() { ( cd "$1" && sha256sum --quiet --check "$sums" ); }
log() { echo "fetch-model: $*"; }

# Hard deadline for the whole step (the model is ~550 MB).
if [ -z "${FETCH_MODEL_DEADLINE_SET:-}" ]; then
  export FETCH_MODEL_DEADLINE_SET=1
  exec timeout --signal=TERM --kill-after=10 "${FETCH_DEADLINE_SECONDS:-900}" bash "$0" "$@"
fi

if [ -d "$final" ] && verify "$final" > /dev/null 2>&1; then
  log "cache hit: $final verified, no download"
else
  [ -e "$final" ] && { log "cache entry $final failed verification, discarding"; rm -rf "$final"; }
  tmp="$cache/.tmp-${HOSTNAME}-$$"
  trap 'rm -rf "$tmp"' EXIT
  rm -rf "$tmp"
  mkdir -p "$tmp"
  log "downloading ${MODEL_REPO}@${MODEL_REVISION} from huggingface.co"
  while read -r _ file; do
    [ -n "$file" ] || continue
    mkdir -p "$tmp/$(dirname "$file")"
    log "  $file"
    curl --fail --silent --show-error --location \
      --retry 6 --retry-delay 5 --retry-max-time 300 --retry-all-errors \
      --connect-timeout 15 --max-time 420 \
      --output "$tmp/$file" "$base/$file"
  done < "$sums"
  verify "$tmp"
  log "download verified"
  if mv -T "$tmp" "$final" 2> /dev/null; then
    log "cache populated: $final"
  elif [ -d "$final" ] && verify "$final" > /dev/null 2>&1; then
    log "another replica populated the cache first, using it"
  else
    log "cannot publish $final and it is not valid" >&2
    exit 1
  fi
fi

# Pod-local copy: the server then never touches NFS, and a QNAP hiccup cannot stall inference.
rm -rf "${out:?}"/*
cp -r "$final"/. "$out"/
verify "$out"
log "model ready in $out ($(du -sh "$out" | cut -f1))"
