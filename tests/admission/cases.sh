# shellcheck shell=bash disable=SC2034
# The allow/deny matrix for the admission test bed (olympus-sdk#964). Sourced by run.sh after the
# fixtures exist; every `row` runs kubectl as system:serviceaccount:atlas-system:atlas-cluster-actuator.
#
#   row <id> <expect> <message substring> <description> <kubectl args...>
#     expect: allow   the request succeeds
#             policy  denied by ValidatingAdmissionPolicy atlas-cluster-actuator-fields
#             rbac    forbidden by RBAC (authorization runs before admission, so the policy is not reached)
#             invalid rejected by the API schema
#   check <id> <description> <expected output> <kubectl args as the admin...>
#   cani  <id> <description> <namespace> <expected can-i rows>
#   admin <kubectl args...>   a setup write as the admin
#
# Ids: 922-N and 956-N are the rows of the live tables on olympus-sdk#922 (2026-11-13, policy generation
# 1) and olympus-sdk#956 (2026-11-13, generation 2); R-N are the further dry runs of the #922 security
# review; X-N are added here. Rows default to --dry-run=server, as the live checks did. The #922 table
# was taken before #956 bound managedFields, with kubectl's default field manager; the actuator always
# patches as `atlas-cluster-actuator`, which the current policy requires, so those rows use it too.

FM=--field-manager=atlas-cluster-actuator
DRY=--dry-run=server
T=2026-11-14T00:00:00Z
RESTART='{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"'$T'"}}}}}'
RECONCILE='{"metadata":{"annotations":{"reconcile.fluxcd.io/requestedAt":"'$T'"}}}'
SUSPEND='{"spec":{"suspend":true}}'
RESUME='{"spec":{"suspend":false}}'

M_WORKLOAD='may only set spec.template.metadata.annotations[kubectl.kubernetes.io/restartedAt] on workloads'
M_META='may only set metadata.annotations[reconcile.fluxcd.io/requestedAt], on Flux objects'
M_NS='may not change workloads in kube-system, flux-system or atlas-system'
M_FLUXSPEC='may only set spec.suspend on Flux objects'
M_ROOT='may not suspend the root Kustomizations'
M_MF='may not add or change metadata.managedFields entries beyond its own fields'
M_MAIN='may only update (patch) the main resource: no create, delete or subresource writes'

# --- olympus-sdk#922 ---------------------------------------------------------------------------------
check 922-1 "policy type-checked: observed generation, no expression warnings" \
  "1 {}" get validatingadmissionpolicy atlas-cluster-actuator-fields \
  -o jsonpath='{.status.observedGeneration} {.status.typeChecking}'
cani 922-2 "auth can-i --list -n whoami: only get/patch on the five kinds" whoami \
  "daemonsets.apps [] [get patch]
deployments.apps [] [get patch]
helmreleases.helm.toolkit.fluxcd.io [] [get patch]
kustomizations.kustomize.toolkit.fluxcd.io [] [get patch]
statefulsets.apps [] [get patch]"
row 922-3 policy "$M_WORKLOAD" "patch deploy whoami replicas=0 (dry run)" \
  -n whoami patch deployment whoami $FM $DRY -p '{"spec":{"replicas":0}}'
row 922-4 policy "$M_WORKLOAD" "patch deploy whoami replicas=0 (real write)" \
  -n whoami patch deployment whoami $FM -p '{"spec":{"replicas":0}}'
check 922-4b "whoami replicas still 1 after 922-4" "1" -n whoami get deployment whoami -o jsonpath='{.spec.replicas}'
row 922-5 allow "" "restartedAt on deploy whoami" \
  -n whoami patch deployment whoami $FM $DRY --type merge -p "$RESTART"
row 922-6 policy "$M_META" "another metadata annotation on deploy whoami" \
  -n whoami patch deployment whoami $FM $DRY --type merge -p '{"metadata":{"annotations":{"example.com/x":"y"}}}'
row 922-7 policy "$M_NS" "restartedAt on deploy kube-system/coredns" \
  -n kube-system patch deployment coredns $FM $DRY --type merge -p "$RESTART"
row 922-8 allow "" "requestedAt on ks flux-system/whoami" \
  -n flux-system patch kustomization whoami $FM $DRY --type merge -p "$RECONCILE"
row 922-9 allow "" "spec.suspend on ks whoami" \
  -n flux-system patch kustomization whoami $FM $DRY --type merge -p "$SUSPEND"
row 922-10 policy "$M_FLUXSPEC" "spec.suspend + interval on ks whoami" \
  -n flux-system patch kustomization whoami $FM $DRY --type merge -p '{"spec":{"suspend":true,"interval":"1h"}}'
row 922-11 allow "" "spec.suspend on hr arc-runners/olympus-gate" \
  -n arc-runners patch helmrelease olympus-gate $FM $DRY --type merge -p "$SUSPEND"
row 922-12 rbac 'cannot delete resource "deployments"' "delete deploy whoami (dry run)" \
  -n whoami delete deployment whoami $DRY

# --- olympus-sdk#956 ---------------------------------------------------------------------------------
row 956-2 policy "$M_ROOT" "suspend ks flux-system/flux-system" \
  -n flux-system patch kustomization flux-system $FM $DRY --type merge -p "$SUSPEND"
row 956-3 policy "$M_ROOT" "suspend ks flux-system/atlas-system" \
  -n flux-system patch kustomization atlas-system $FM $DRY --type merge -p "$SUSPEND"
row 956-4 allow "" "suspend ks whoami" \
  -n flux-system patch kustomization whoami $FM $DRY --type merge -p "$SUSPEND"
row 956-5 allow "" "requestedAt on ks flux-system" \
  -n flux-system patch kustomization flux-system $FM $DRY --type merge -p "$RECONCILE"
row 956-6 allow "" "resume ks atlas-system" \
  -n flux-system patch kustomization atlas-system $FM $DRY --type merge -p "$RESUME"
row 956-7 policy "$M_MF" "forged kustomize-controller managedFields entry on ks whoami" \
  -n flux-system patch kustomization whoami $FM $DRY --type merge \
  -p '{"metadata":{"managedFields":[{"manager":"kustomize-controller","operation":"Apply","apiVersion":"kustomize.toolkit.fluxcd.io/v1","time":"'$T'","fieldsType":"FieldsV1","fieldsV1":{"f:spec":{"f:suspend":{}}}}]}}'
row 956-8 policy "$M_MF" "evil managedFields entry on deploy whoami" \
  -n whoami patch deployment whoami $FM $DRY --type merge \
  -p '{"metadata":{"managedFields":[{"manager":"evil","operation":"Update","apiVersion":"apps/v1","time":"'$T'","fieldsType":"FieldsV1","fieldsV1":{"f:spec":{"f:replicas":{}}}}]}}'
row 956-9 policy "$M_MF" "requestedAt under field manager kubectl-patch" \
  -n flux-system patch kustomization flux-system --field-manager=kubectl-patch $DRY --type merge -p "$RECONCILE"
row 956-10 allow "" "requestedAt on ks cert-manager (takes the field from flux)" \
  -n flux-system patch kustomization cert-manager $FM $DRY --type merge -p "$RECONCILE"
row 956-11 allow "" "restartedAt on deploy external-dns (takes the field from kubectl-rollout)" \
  -n external-dns patch deployment external-dns $FM $DRY --type merge -p "$RESTART"
row 956-12 allow "" "restartedAt on ds otel/node-exporter (server bumps the template generation)" \
  -n otel patch daemonset node-exporter $FM $DRY --type merge -p "$RESTART"
row 956-13 policy "" "replicas=0 on deploy whoami" \
  -n whoami patch deployment whoami $FM $DRY --type merge -p '{"spec":{"replicas":0}}'
row 956-14 policy "$M_NS" "restart in kube-system" \
  -n kube-system patch deployment coredns $FM $DRY --type merge -p "$RESTART"
row 956-15 allow "" "suspend hr arc-runners/olympus-gate" \
  -n arc-runners patch helmrelease olympus-gate $FM $DRY --type merge -p "$SUSPEND"
row 956-16 rbac 'cannot delete resource "deployments"' "delete deploy whoami" \
  -n whoami delete deployment whoami $DRY
row 956-17 policy "$M_META" "another annotation on ks whoami" \
  -n flux-system patch kustomization whoami $FM $DRY --type merge -p '{"metadata":{"annotations":{"example.com/x":"y"}}}'
row 956-18 policy "$M_FLUXSPEC" "suspend + interval" \
  -n flux-system patch kustomization whoami $FM $DRY --type merge -p '{"spec":{"suspend":true,"interval":"1h"}}'

# --- the #922 security review's further dry runs -----------------------------------------------------
row R-1 policy "$M_META" "label on ks whoami" \
  -n flux-system patch kustomization whoami $FM $DRY --type merge -p '{"metadata":{"labels":{"example.com/x":"y"}}}'
row R-2 policy "$M_WORKLOAD" "template label on deploy whoami" \
  -n whoami patch deployment whoami $FM $DRY --type merge -p '{"spec":{"template":{"metadata":{"labels":{"example.com/x":"y"}}}}}'
row R-3 policy "$M_META" "finalizer on deploy whoami" \
  -n whoami patch deployment whoami $FM $DRY --type merge -p '{"metadata":{"finalizers":["example.com/x"]}}'
row R-4 policy "$M_META" "ownerReferences on deploy whoami" \
  -n whoami patch deployment whoami $FM $DRY --type merge \
  -p '{"metadata":{"ownerReferences":[{"apiVersion":"v1","kind":"ConfigMap","name":"x","uid":"00000000-0000-0000-0000-000000000001"}]}}'
row R-5 policy "$M_META" "requestedAt plus a second annotation on ks whoami" \
  -n flux-system patch kustomization whoami $FM $DRY --type merge \
  -p '{"metadata":{"annotations":{"reconcile.fluxcd.io/requestedAt":"'$T'","example.com/x":"y"}}}'
row R-6 policy "$M_WORKLOAD" "JSON patch of replicas on deploy whoami" \
  -n whoami patch deployment whoami $FM $DRY --type json -p '[{"op":"replace","path":"/spec/replicas","value":0}]'
row R-7 policy "$M_WORKLOAD" "restartedAt plus an image change on deploy whoami" \
  -n whoami patch deployment whoami $FM $DRY \
  -p '{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"'$T'"}},"spec":{"containers":[{"name":"whoami","image":"example.com/evil:1"}]}}}}'
row R-8 policy "$M_NS" "restartedAt on deploy atlas-system/atlas-cluster-actuator" \
  -n atlas-system patch deployment atlas-cluster-actuator $FM $DRY --type merge -p "$RESTART"
row R-9 rbac 'resource "deployments/scale"' "scale subresource of deploy whoami" \
  -n whoami patch deployment whoami $FM $DRY --subresource scale --type merge -p '{"spec":{"replicas":0}}'
row R-10 rbac 'cannot list resource "deployments"' "list deployments" \
  -n whoami get deployments
row R-11 rbac 'cannot get resource "configmaps"' "another ConfigMap in atlas-system" \
  -n atlas-system get configmap other
row R-12 rbac 'cannot get resource "secrets"' "a Secret" \
  -n atlas-system get secret other
row R-13 allow "" "status field through the main resource of ks whoami (ignored by the server)" \
  -n flux-system patch kustomization whoami $FM $DRY --type merge -p '{"status":{"observedGeneration":99}}'
row R-14 invalid 'spec.suspend' "suspend: \"yes\" (CRD schema)" \
  -n flux-system patch kustomization whoami $FM $DRY --type merge -p '{"spec":{"suspend":"yes"}}'

# --- added here --------------------------------------------------------------------------------------
cani X-1 "auth can-i --list -n atlas-system: plus get/update on the dedupe ConfigMap only" atlas-system \
  "configmaps [atlas-cluster-actuator-dedupe] [get update]
daemonsets.apps [] [get patch]
deployments.apps [] [get patch]
helmreleases.helm.toolkit.fluxcd.io [] [get patch]
kustomizations.kustomize.toolkit.fluxcd.io [] [get patch]
statefulsets.apps [] [get patch]"
row X-2 allow "" "get the dedupe ConfigMap" \
  -n atlas-system get configmap atlas-cluster-actuator-dedupe
row X-3 rbac 'cannot patch resource "configmaps"' "patch the dedupe ConfigMap (only get/update granted)" \
  -n atlas-system patch configmap atlas-cluster-actuator-dedupe $DRY --type merge -p '{"data":{"x":"y"}}'
row X-4 rbac 'cannot create resource "deployments"' "create a Deployment" \
  -n whoami create deployment extra --image=example.com/x:1 $DRY
row X-5 rbac 'cannot create resource "kustomizations"' "create a Kustomization" \
  -n flux-system create -f - $DRY <<<'{"apiVersion":"kustomize.toolkit.fluxcd.io/v1","kind":"Kustomization","metadata":{"name":"extra","namespace":"flux-system"},"spec":{"interval":"10m","prune":true,"sourceRef":{"kind":"GitRepository","name":"flux-system"}}}'
row X-6 rbac 'resource "kustomizations/status"' "status subresource of ks whoami" \
  -n flux-system patch kustomization whoami $FM $DRY --subresource status --type merge -p '{"status":{"observedGeneration":99}}'
row X-7 rbac 'resource "deployments/status"' "status subresource of deploy whoami" \
  -n whoami patch deployment whoami $FM $DRY --subresource status --type merge -p '{"status":{"replicas":0}}'
row X-8 policy "$M_WORKLOAD" "restartedAt plus a second template annotation on deploy whoami" \
  -n whoami patch deployment whoami $FM $DRY --type merge \
  -p '{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"'$T'","example.com/x":"y"}}}}}'
row X-9 policy "$M_META" "restartedAt as a metadata annotation of deploy whoami" \
  -n whoami patch deployment whoami $FM $DRY --type merge \
  -p '{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"'$T'"}}}'
row X-10 policy "$M_META" "requestedAt on a workload" \
  -n whoami patch deployment whoami $FM $DRY --type merge -p "$RECONCILE"
row X-11 policy "$M_WORKLOAD" "restartedAt removed from deploy external-dns" \
  -n external-dns patch deployment external-dns $FM $DRY --type merge \
  -p '{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":null}}}}}'
row X-12 policy "$M_META" "requestedAt removed from ks cert-manager" \
  -n flux-system patch kustomization cert-manager $FM $DRY --type merge \
  -p '{"metadata":{"annotations":{"reconcile.fluxcd.io/requestedAt":null}}}'
# The actuator sets deprecated.daemonset.template.generation itself, a jump of +5. Denied, by the
# managedFields rule: the actuator's entry would claim that annotation. The dsGeneration validation does
# not answer here because the API server's DaemonSet strategy discards a direct change of the template
# generation (a real write without that rule leaves the value unchanged; checked on 1.35.4), so the
# object admission sees still carries the old value. That validation stays as defence in depth.
dsgen=$(k -n otel get daemonset node-exporter -o jsonpath='{.metadata.annotations.deprecated\.daemonset\.template\.generation}')
row X-13 policy "$M_MF" "deprecated.daemonset.template.generation set directly to +5 ($dsgen -> $((dsgen + 5)))" \
  -n otel patch daemonset node-exporter $FM $DRY --type merge \
  -p '{"metadata":{"annotations":{"deprecated.daemonset.template.generation":"'$((dsgen + 5))'"}}}'
row X-14 policy "$M_WORKLOAD" "restartedAt plus an updateStrategy change on ds node-exporter" \
  -n otel patch daemonset node-exporter $FM $DRY --type merge \
  -p '{"spec":{"updateStrategy":{"type":"OnDelete"},"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"'$T'"}}}}}'
row X-15 policy "$M_NS" "restartedAt on a workload in flux-system" \
  -n flux-system patch deployment kustomize-controller $FM $DRY --type merge -p "$RESTART"

# A root Kustomization that is already suspended (an admin suspended it): the actuator may resume and
# reconcile it, and re-sending suspend=true changes nothing, so it stays admitted.
admin -n flux-system patch kustomization atlas-system --type merge -p "$SUSPEND"
row X-16 allow "" "resume ks atlas-system while it is suspended" \
  -n flux-system patch kustomization atlas-system $FM $DRY --type merge -p "$RESUME"
row X-17 allow "" "requestedAt on ks atlas-system while it is suspended" \
  -n flux-system patch kustomization atlas-system $FM $DRY --type merge -p "$RECONCILE"
row X-18 allow "" "suspend ks atlas-system again while it is suspended (no change)" \
  -n flux-system patch kustomization atlas-system $FM $DRY --type merge -p "$SUSPEND"
row X-19 policy "$M_FLUXSPEC" "resume plus a path change on ks atlas-system" \
  -n flux-system patch kustomization atlas-system $FM $DRY --type merge -p '{"spec":{"suspend":false,"path":"./x"}}'
admin -n flux-system patch kustomization atlas-system --type json -p '[{"op":"remove","path":"/spec/suspend"}]'
row X-20 policy "$M_ROOT" "suspend ks flux-system/atlas-system again after the admin resumed it" \
  -n flux-system patch kustomization atlas-system $FM $DRY --type merge -p "$SUSPEND"

# Real writes: a restart and a reconcile land, and a second one by the actuator (now owning the field)
# is admitted too; the specs are unchanged.
row X-21 allow "" "restartedAt on deploy whoami (real write)" \
  -n whoami patch deployment whoami $FM --type merge -p "$RESTART"
row X-22 allow "" "a second restart of deploy whoami (real write, actuator owns the field)" \
  -n whoami patch deployment whoami $FM --type merge \
  -p '{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"2026-11-14T00:05:00Z"}}}}}'
check X-23 "whoami after the real writes: replicas 1, restartedAt from X-22" "1 2026-11-14T00:05:00Z" \
  -n whoami get deployment whoami \
  -o jsonpath='{.spec.replicas} {.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}'
row X-24 allow "" "restartedAt on ds otel/node-exporter (real write)" \
  -n otel patch daemonset node-exporter $FM --type merge -p "$RESTART"
check X-25 "node-exporter template generation moved up by exactly one" "$((dsgen + 1))" \
  -n otel get daemonset node-exporter -o jsonpath='{.metadata.annotations.deprecated\.daemonset\.template\.generation}'
row X-26 allow "" "requestedAt on ks cert-manager (real write, takes the field from flux)" \
  -n flux-system patch kustomization cert-manager $FM --type merge -p "$RECONCILE"
row X-27 policy "$M_MF" "a forged second actuator entry claiming spec.interval on ks cert-manager" \
  -n flux-system patch kustomization cert-manager $FM $DRY --type json \
  -p '[{"op":"add","path":"/metadata/managedFields/-","value":{"manager":"atlas-cluster-actuator","operation":"Update","apiVersion":"kustomize.toolkit.fluxcd.io/v1","time":"'$T'","fieldsType":"FieldsV1","fieldsV1":{"f:spec":{"f:interval":{}}}}}]'

# The policy alone, with RBAC widened: a test-only ClusterRole grants this identity create, delete and
# subresource writes, so these requests reach admission and the policy's own denial is what answers.
admin apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: admission-test-widen
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "deployments/scale", "deployments/status", "daemonsets", "statefulsets"]
    verbs: ["get", "create", "delete", "patch", "update"]
  - apiGroups: ["kustomize.toolkit.fluxcd.io"]
    resources: ["kustomizations", "kustomizations/status"]
    verbs: ["get", "create", "delete", "patch", "update"]
  - apiGroups: ["helm.toolkit.fluxcd.io"]
    resources: ["helmreleases", "helmreleases/status"]
    verbs: ["get", "create", "delete", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admission-test-widen
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admission-test-widen
subjects:
  - kind: ServiceAccount
    name: atlas-cluster-actuator
    namespace: atlas-system
EOF
row P-1 policy "$M_MAIN" "create a Deployment (RBAC widened)" \
  -n whoami create deployment extra --image=example.com/x:1 $DRY
row P-2 policy "$M_MAIN" "delete deploy whoami (RBAC widened)" \
  -n whoami delete deployment whoami $DRY
row P-3 policy "$M_MAIN" "scale subresource of deploy whoami (RBAC widened)" \
  -n whoami patch deployment whoami $FM $DRY --subresource scale --type merge -p '{"spec":{"replicas":0}}'
row P-4 policy "$M_MAIN" "status subresource of ks whoami (RBAC widened)" \
  -n flux-system patch kustomization whoami $FM $DRY --subresource status --type merge -p '{"status":{"observedGeneration":99}}'
row P-5 policy "$M_MAIN" "delete ks whoami (RBAC widened)" \
  -n flux-system delete kustomization whoami $DRY
row P-6 policy "$M_MAIN" "create a HelmRelease (RBAC widened)" \
  -n arc-runners create -f - $DRY <<<'{"apiVersion":"helm.toolkit.fluxcd.io/v2","kind":"HelmRelease","metadata":{"name":"extra","namespace":"arc-runners"},"spec":{"interval":"1h","chartRef":{"kind":"OCIRepository","name":"x"}}}'
row P-7 allow "" "restartedAt on deploy whoami still admitted (RBAC widened)" \
  -n whoami patch deployment whoami $FM $DRY --type merge -p "$RESTART"
