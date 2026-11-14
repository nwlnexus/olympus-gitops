#!/usr/bin/env bash
# Offline admission-policy test bed for the atlas cluster actuator (olympus-sdk#964).
#
# Starts a throwaway etcd and kube-apiserver (RBAC on) in a temp dir, applies the repo's actuator RBAC,
# dedupe ConfigMap and ValidatingAdmissionPolicy, the Flux CRDs and fixture objects with realistic field
# ownership, then runs the allow/deny matrix in cases.sh as the actuator ServiceAccount. Needs no cluster
# credential: it never reads ~/.kube/config or $KUBECONFIG.
#
#   tests/admission/run.sh                    # the policy on this checkout
#   POLICY=/path/to/copy.yaml tests/admission/run.sh   # another policy file (regression checks)
#   KEEP_TMP=1 tests/admission/run.sh         # keep the temp dir (logs, kubeconfig) for debugging
#
# The binaries come from a pinned nixpkgs (see NIXPKGS_REV); the script re-executes itself inside
# `nix shell`. Set ADMISSION_TEST_IN_NIX=1 to use kube-apiserver, kube-controller-manager, kubectl, etcd,
# openssl and gawk from PATH instead.
set -euo pipefail

# nixpkgs-unstable of 2026-04-23: kubernetes 1.35.4, etcd 3.6.10 (both in cache.nixos.org).
NIXPKGS_REV=1a78a349635f5ef781af5f7383cbf9a9d714c23f

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)
POLICY=${POLICY:-$repo/clusters/olympus/atlas-system/actuator-admission.yaml}
POLICY=$(cd "$(dirname "$POLICY")" && pwd)/$(basename "$POLICY")
export POLICY

if [ -z "${ADMISSION_TEST_IN_NIX:-}" ]; then
  command -v nix >/dev/null || { echo "run.sh: nix is required (or set ADMISSION_TEST_IN_NIX=1 with the binaries on PATH)" >&2; exit 2; }
  export ADMISSION_TEST_IN_NIX=1
  np="github:NixOS/nixpkgs/$NIXPKGS_REV"
  exec nix --extra-experimental-features 'nix-command flakes' shell \
    "$np#kubernetes" "$np#etcd" "$np#openssl" "$np#gawk" -c bash "${BASH_SOURCE[0]}" "$@"
fi

# Never talk to a real cluster: no inherited kubeconfig, and every kubectl call passes --kubeconfig and
# --cache-dir inside the temp dir, so nothing under ~/.kube is read or written.
unset KUBECONFIG

SA=system:serviceaccount:atlas-system:atlas-cluster-actuator
atlas=$repo/clusters/olympus/atlas-system
tmp=$(mktemp -d "${TMPDIR:-/tmp}/admission-test.XXXXXX")
pids=()
cleanup() {
  # Stop in reverse start order (the API server before etcd, or its shutdown can hang), 10 s each.
  local i p
  for ((i = ${#pids[@]} - 1; i >= 0; i--)); do
    p=${pids[i]}
    kill "$p" 2>/dev/null || continue
    for _ in $(seq 40); do kill -0 "$p" 2>/dev/null || break; sleep 0.25; done
    kill -9 "$p" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  if [ -n "${KEEP_TMP:-}" ]; then echo "kept $tmp"; else rm -rf "$tmp"; fi
}
trap cleanup EXIT

die() {
  echo "run.sh: $*" >&2
  local f
  for f in etcd apiserver controller-manager; do
    [ -f "$tmp/$f.log" ] && { echo "--- last lines of $f.log" >&2; tail -n 20 "$tmp/$f.log" >&2; }
  done
  exit 2
}

free_port() {
  local p _
  for _ in $(seq 100); do
    p=$((20000 + RANDOM % 40000))
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then echo "$p"; return 0; fi
  done
  return 1
}

echo "== versions: $(kube-apiserver --version), etcd $(etcd --version | awk '/etcd Version/ {print $3}')"
echo "== policy: ${POLICY#"$repo/"}"

# --- etcd -------------------------------------------------------------------------------------------
etcd_client=$(free_port) || die "no free port"
etcd_peer=$(free_port) || die "no free port"
etcd --name test --data-dir "$tmp/etcd" --unsafe-no-fsync --log-level error \
  --listen-client-urls "http://127.0.0.1:$etcd_client" --advertise-client-urls "http://127.0.0.1:$etcd_client" \
  --listen-peer-urls "http://127.0.0.1:$etcd_peer" --initial-advertise-peer-urls "http://127.0.0.1:$etcd_peer" \
  --initial-cluster "test=http://127.0.0.1:$etcd_peer" >"$tmp/etcd.log" 2>&1 &
pids+=($!)

# --- kube-apiserver ---------------------------------------------------------------------------------
openssl genrsa -out "$tmp/sa.key" 2048 2>/dev/null
openssl rsa -in "$tmp/sa.key" -pubout -out "$tmp/sa.pub" 2>/dev/null
token=$(openssl rand -hex 32)
printf '%s,test-admin,test-admin,system:masters\n' "$token" >"$tmp/tokens.csv"
api_port=$(free_port) || die "no free port"
kube-apiserver \
  --etcd-servers "http://127.0.0.1:$etcd_client" \
  --bind-address 127.0.0.1 --advertise-address 127.0.0.1 --secure-port "$api_port" \
  --cert-dir "$tmp/certs" \
  --token-auth-file "$tmp/tokens.csv" --anonymous-auth=false \
  --authorization-mode RBAC \
  --service-account-issuer https://kubernetes.default.svc.cluster.local \
  --service-account-key-file "$tmp/sa.pub" --service-account-signing-key-file "$tmp/sa.key" \
  --service-cluster-ip-range 10.96.0.0/24 \
  >"$tmp/apiserver.log" 2>&1 &
pids+=($!)

kc=$tmp/kubeconfig
for _ in $(seq 120); do [ -s "$tmp/certs/apiserver.crt" ] && break; sleep 0.5; done
[ -s "$tmp/certs/apiserver.crt" ] || die "kube-apiserver wrote no serving certificate"
cat >"$kc" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: test
    cluster:
      server: https://127.0.0.1:$api_port
      certificate-authority: $tmp/certs/apiserver.crt
users:
  - name: test-admin
    user:
      token: $token
contexts:
  - name: test
    context: {cluster: test, user: test-admin}
current-context: test
EOF
chmod 600 "$kc"

k() { kubectl --kubeconfig "$kc" --cache-dir "$tmp/kube-cache" "$@"; }
ka() { kubectl --kubeconfig "$kc" --cache-dir "$tmp/kube-cache" --as "$SA" "$@"; }

ready=""
for _ in $(seq 120); do
  if k get --raw /readyz >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.5
done
[ -n "$ready" ] || die "kube-apiserver did not become ready"

# The ValidatingAdmissionPolicy status (type checking) is written by this one kube-controller-manager
# controller; no other controller runs, so nothing reconciles the fixtures.
kube-controller-manager --kubeconfig "$kc" --controllers validatingadmissionpolicy-status-controller \
  --leader-elect=false --secure-port 0 >"$tmp/controller-manager.log" 2>&1 &
pids+=($!)

# --- objects ----------------------------------------------------------------------------------------
echo "== applying Flux CRDs, namespaces, actuator RBAC, dedupe ConfigMap and the policy"
gawk 'BEGIN { RS = "\n---\n" } /(^|\n)kind: CustomResourceDefinition\n/ { print "---"; print }' \
  "$repo/clusters/olympus/flux-system/gotk-components.yaml" >"$tmp/flux-crds.yaml"
k apply --server-side -f "$tmp/flux-crds.yaml" >/dev/null || die "applying the Flux CRDs failed"
k wait --for condition=Established --timeout 60s \
  crd/kustomizations.kustomize.toolkit.fluxcd.io crd/helmreleases.helm.toolkit.fluxcd.io >/dev/null \
  || die "the Flux CRDs were not established"

for ns in flux-system whoami external-dns otel arc-runners; do k create namespace "$ns" >/dev/null; done
k apply -f "$atlas/namespace.yaml" -f "$atlas/actuator-rbac.yaml" -f "$atlas/actuator-configmaps.yaml" >/dev/null \
  || die "applying the actuator RBAC failed"
k apply -f "$POLICY" >/dev/null || die "applying $POLICY failed"

checked=""
for _ in $(seq 120); do
  gen=$(k get validatingadmissionpolicy atlas-cluster-actuator-fields -o jsonpath='{.metadata.generation}')
  obs=$(k get validatingadmissionpolicy atlas-cluster-actuator-fields -o jsonpath='{.status.observedGeneration}')
  if [ "$gen" = "$obs" ]; then checked=1; break; fi
  sleep 0.5
done
[ -n "$checked" ] || die "the policy status was never written (type checking did not run)"
policy_status=$(k get validatingadmissionpolicy atlas-cluster-actuator-fields -o jsonpath='{.status}')
echo "== policy status: $policy_status"

echo "== applying fixtures with their field managers"
k apply --server-side --field-manager kustomize-controller -f "$here/fixtures.yaml" >/dev/null \
  || die "applying the fixtures failed"
# Status as the controllers write it (subresource entries in managedFields, as on the live objects).
for ks in flux-system atlas-system whoami cert-manager; do
  k -n flux-system patch kustomization "$ks" --subresource status --type merge --field-manager kustomize-controller \
    -p '{"status":{"observedGeneration":1,"lastAppliedRevision":"main@sha1:0000000000000000000000000000000000000000"}}' >/dev/null
done
k -n arc-runners patch helmrelease olympus-gate --subresource status --type merge --field-manager helm-controller \
  -p '{"status":{"observedGeneration":1}}' >/dev/null
for d in whoami/whoami kube-system/coredns external-dns/external-dns atlas-system/atlas-cluster-actuator; do
  k -n "${d%/*}" patch deployment "${d#*/}" --subresource status --type merge --field-manager kube-controller-manager \
    -p '{"status":{"observedGeneration":1,"replicas":1,"readyReplicas":1,"availableReplicas":1,"updatedReplicas":1}}' >/dev/null
done
k -n otel patch daemonset node-exporter --subresource status --type merge --field-manager kube-controller-manager \
  -p '{"status":{"observedGeneration":1,"currentNumberScheduled":3,"numberMisscheduled":0,"desiredNumberScheduled":3,"numberReady":3}}' >/dev/null
# `flux reconcile ks cert-manager` set requestedAt earlier: manager `flux` owns it.
k -n flux-system patch kustomization cert-manager --type merge --field-manager flux \
  -p '{"metadata":{"annotations":{"reconcile.fluxcd.io/requestedAt":"2026-11-01T00:00:00Z"}}}' >/dev/null
# `kubectl rollout restart` restarted external-dns earlier: manager `kubectl-rollout` owns restartedAt.
k -n external-dns rollout restart deployment external-dns >/dev/null

managers() { k -n "$1" get "$2" "$3" -o jsonpath='{range .metadata.managedFields[*]}{.manager}{" "}{end}'; }
[[ " $(managers flux-system kustomization cert-manager)" == *" flux "* ]] || die "fixture: flux does not own requestedAt on ks cert-manager"
[[ " $(managers external-dns deployment external-dns)" == *" kubectl-rollout "* ]] || die "fixture: kubectl-rollout does not own restartedAt on external-dns"
[[ " $(managers whoami deployment whoami)" == *" kustomize-controller "* ]] || die "fixture: kustomize-controller does not own whoami"

# The admission plugin loads the policy and binding through informers; wait until a request it must
# deny under any version of the policy (replicas on a workload) is denied by it, at most 30 s.
for _ in $(seq 60); do
  probe=$(ka -n whoami patch deployment whoami --dry-run=server --field-manager atlas-cluster-actuator \
    -p '{"spec":{"replicas":0}}' 2>&1) || true
  [[ $probe == *"ValidatingAdmissionPolicy 'atlas-cluster-actuator-fields'"* ]] && break
  sleep 0.5
done

# --- matrix -----------------------------------------------------------------------------------------
POLICY_MARK="ValidatingAdmissionPolicy 'atlas-cluster-actuator-fields'"
RBAC_MARK="User \"$SA\" cannot"
pass=0
fail=0
failed=()

# classify <rc> <output>: allow | policy | rbac | invalid | error
classify() {
  if [ "$1" -eq 0 ]; then echo allow
  elif [[ $2 == *"$POLICY_MARK"* ]]; then echo policy
  elif [[ $2 == *"$RBAC_MARK"* ]]; then echo rbac
  elif [[ $2 == *"is invalid"* || $2 == *"Invalid value"* ]]; then echo invalid
  else echo error; fi
}

record() { # <id> <ok> <expect> <got> <desc> <output>
  if [ "$2" = 1 ]; then
    pass=$((pass + 1))
    printf 'PASS  %-8s expected %-7s got %-7s %s\n' "$1" "$3" "$4" "$5"
  else
    fail=$((fail + 1))
    failed+=("$1")
    printf 'FAIL  %-8s expected %-7s got %-7s %s\n' "$1" "$3" "$4" "$5"
    printf '%s\n' "$6" | head -n 4 | sed 's/^/        | /'
  fi
}

# row <id> <expect: allow|policy|rbac|invalid> <substring or ""> <description> <kubectl args as the actuator...>
row() {
  local id=$1 expect=$2 want=$3 desc=$4 out rc got ok=0
  shift 4
  out=$(ka "$@" 2>&1) && rc=0 || rc=$?
  got=$(classify "$rc" "$out")
  if [ "$got" = "$expect" ] && { [ -z "$want" ] || [[ $out == *"$want"* ]]; }; then ok=1; fi
  record "$id" "$ok" "$expect" "$got" "$desc" "$out"
}

# check <id> <description> <expected stdout> <kubectl args as the admin...>
check() {
  local id=$1 desc=$2 want=$3 out ok=0
  shift 3
  out=$(k "$@" 2>&1) || true
  [ "$out" = "$want" ] && ok=1
  record "$id" "$ok" "$want" "$out" "$desc" "$out"
}

# cani <id> <description> <namespace> <expected rows, one "resource [names] [verbs]" per line>
# Compares `auth can-i --list` as the actuator, minus the rows every authenticated identity has.
cani() {
  local id=$1 desc=$2 ns=$3 want=$4 out got ok=0
  out=$(ka auth can-i --list -n "$ns" 2>&1) || true
  got=$(printf '%s\n' "$out" | awk 'NR > 1 && $1 !~ /^\[/ && $1 !~ /^selfsubject/ { print $1, $3, $4, $5 }' | sort)
  [ "$got" = "$(printf '%s\n' "$want" | sort)" ] && ok=1
  record "$id" "$ok" "exact" "$([ $ok = 1 ] && echo exact || echo other)" "$desc" "$got"
}

# admin <kubectl args...>: a setup write as the admin; aborts on failure.
admin() { k "$@" >/dev/null || die "setup step failed: kubectl $*"; }

echo "== matrix (as $SA)"
# shellcheck source-path=SCRIPTDIR source=cases.sh
source "$here/cases.sh"

echo "== $pass passed, $fail failed ($((pass + fail)) rows)"
if [ "$fail" -gt 0 ]; then
  echo "failing rows: ${failed[*]}"
  exit 1
fi
