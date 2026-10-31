#!/usr/bin/env bash
# Tears down every billable resource this repo creates: the storefront
# ALB, SPIRE's and CloudNativePG's PVCs, EKS (which takes everything
# ArgoCD installed down with it), the VPC. Run this after every
# rehearsal.
#
# Ported from the inherited Vault talk's destroy.sh, which confirmed
# these hazards the hard way (2026-10-18) -- three of its five still
# apply exactly; the two that don't (a Vault resource that can't be
# destroyed through its own API; a `vault_env` call needed before
# `terraform destroy` can even refresh state) disappeared along with
# Vault itself:
#   1. The storefront Ingress must be deleted first so the AWS Load
#      Balancer Controller deletes the ALB + target groups itself.
#      Deleting the controller (which `terraform destroy` does) does NOT
#      clean up an ALB whose Ingress still exists.
#   2. SPIRE's AND CloudNativePG's PVCs must be deleted explicitly. Helm
#      does not delete StatefulSet volumeClaimTemplate PVCs on uninstall
#      (SPIRE), and the CloudNativePG operator does not delete its
#      Cluster's PVC on namespace deletion either (CloudNativePG) --
#      deleting the EKS cluster does not delete the EBS volumes behind
#      either one.
#   3. Deleting a PVC doesn't mean the EBS volume behind it is gone
#      immediately -- the CSI driver needs time to actually process the
#      deletion, and if EKS (and the CSI driver running on it) is
#      destroyed before that finishes, the volume survives as an orphan.
#      The final sweep below actively deletes anything left in
#      `available` state, rather than just reporting it.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

warn "about to destroy the entire kubecon-demo stack (EKS, VPC, ALB, every PVC's EBS volume)."
read -r -p "type 'destroy' to continue: " confirm
[ "$confirm" = "destroy" ] || die "aborted"

log "deleting the storefront Ingress and waiting for the ALB to disappear"
kubectl -n nimbus delete ingress storefront --ignore-not-found --timeout=180s 2>/dev/null || true
for i in $(seq 1 60); do
  remaining="$(aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName, 'storefront')].LoadBalancerName" --output text 2>/dev/null || true)"
  [ -z "$remaining" ] && break
  sleep 5
done

log "deleting SPIRE's and CloudNativePG's PVCs"
kubectl -n spire-mgmt delete pvc --all --ignore-not-found --timeout=180s 2>/dev/null || true
kubectl -n data delete pvc --all --ignore-not-found --timeout=180s 2>/dev/null || true

terraform -chdir="$TF_DIR" destroy -auto-approve
DESTROY_STATUS=$?
[ "$DESTROY_STATUS" -eq 0 ] || warn "terraform destroy exited $DESTROY_STATUS -- check terraform state list in $TF_DIR for anything left behind before assuming this is fully torn down."

log "confirming nothing billable was left behind"
aws eks list-clusters --query 'clusters' --output table 2>/dev/null || true
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output table 2>/dev/null || true
aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupName' --output table 2>/dev/null || true

log "deleting any EBS volumes orphaned by a PVC whose CSI deletion didn't finish before the cluster did"
orphans="$(aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].{id:VolumeId,pvc:Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value}' --output json 2>/dev/null || echo '[]')"
echo "$orphans" | python3 -c '
import json, sys
for v in json.load(sys.stdin):
    if v.get("pvc"):
        print(v["id"])
' | while read -r vol_id; do
  warn "deleting orphaned volume $vol_id (was backing a PVC that no longer exists)"
  aws ec2 delete-volume --volume-id "$vol_id" 2>&1 || true
done
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].{id:VolumeId,size:Size,pvc:Tags[?Key==`kubernetes.io/created-for/pvc/name`]|[0].Value}' --output table 2>/dev/null || true

log "done. No KMS key this time (we dropped Vault, and with it the auto-unseal key) -- no 7-day pending-deletion tail to remember."
