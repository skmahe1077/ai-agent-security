#!/usr/bin/env bash
# Tears down every billable resource this repo creates: the storefront
# ALB, SPIRE's and CloudNativePG's PVCs, EKS (which takes everything
# ArgoCD installed down with it), the VPC. Run this after every
# rehearsal.
#
# Four well-known AWS/Kubernetes teardown hazards, guarded against
# explicitly rather than left to `terraform destroy` alone:
#   1. The storefront Ingress must be deleted first so the AWS Load
#      Balancer Controller deletes the ALB + target groups itself.
#      Deleting the controller (which `terraform destroy` does) does NOT
#      clean up an ALB whose Ingress still exists.
#   2. Envoy Gateway's own Gateway resource provisions its own NLB (a
#      Service type=LoadBalancer, separate from the storefront's ALB
#      above) -- confirmed live that this, and the security groups the
#      same controller creates for it, survive `terraform destroy` as
#      orphans and block the VPC's subnets, then the VPC itself, from
#      deleting. Swept by tag (`kubernetes.io/cluster/<name>=owned`)
#      before `terraform destroy` runs, not after.
#   3. SPIRE's AND CloudNativePG's PVCs must be deleted explicitly. Helm
#      does not delete StatefulSet volumeClaimTemplate PVCs on uninstall
#      (SPIRE), and the CloudNativePG operator does not delete its
#      Cluster's PVC on namespace deletion either (CloudNativePG) --
#      deleting the EKS cluster does not delete the EBS volumes behind
#      either one.
#   4. Deleting a PVC doesn't mean the EBS volume behind it is gone
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

# Envoy Gateway's own Gateway resource provisions ITS OWN Service
# type=LoadBalancer (an NLB), entirely separate from the storefront's ALB
# above -- terraform never manages it, so it (and the security groups the
# same controller creates for it) survive `terraform destroy` as orphans
# and their ENIs block the VPC's subnets, then the security groups
# themselves block the VPC, from deleting at all. Confirmed the hard way,
# TWICE on two separate teardowns:
#
# Run 1: a first `terraform destroy` got through EKS/ALB/nodes cleanly and
# then failed at the VPC/subnet step with DependencyViolation, once for
# the subnets' leftover NLB ENIs and once more for the VPC's leftover
# security groups once those ENIs were gone. Fixed by sweeping both,
# tagged `kubernetes.io/cluster/<name>=owned`, before `terraform destroy`
# runs -- the legacy tag convention the in-tree cloud provider and
# Ingress-provisioned AWS Load Balancer Controller resources use.
#
# Run 2: the SAME failure recurred even with that sweep in place --
# confirmed live that it deleted 2 security groups (real resources, tag
# matched) but missed 2 NLBs and 3 MORE security groups entirely, which
# then blocked `terraform destroy` exactly as before. Root cause: the AWS
# Load Balancer Controller uses a SECOND, different tag convention,
# `elbv2.k8s.aws/cluster=<name>` (no `owned`/`shared` value), for anything
# it provisions from a Service type=LoadBalancer rather than an Ingress --
# which is exactly how Envoy Gateway's own Gateway resource gets its NLB.
# Both conventions coexist on the same cluster depending on which
# Kubernetes resource triggered the provisioning, so both are swept below.
log "deleting any load balancers an in-cluster controller provisioned for this EKS cluster (not just the storefront's ALB)"
CLUSTER_NAME="$(terraform -chdir="$TF_DIR" output -raw eks_cluster_name 2>/dev/null || true)"
if [ -n "$CLUSTER_NAME" ]; then
  lb_arns="$({
    aws resourcegroupstaggingapi get-resources \
      --resource-type-filters elasticloadbalancing:loadbalancer \
      --tag-filters "Key=kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
      --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null
    aws resourcegroupstaggingapi get-resources \
      --resource-type-filters elasticloadbalancing:loadbalancer \
      --tag-filters "Key=elbv2.k8s.aws/cluster,Values=${CLUSTER_NAME}" \
      --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null
  } | tr '\t' '\n' | sort -u)"
  for arn in $lb_arns; do
    warn "deleting load balancer $arn (provisioned by an in-cluster controller, not terraform)"
    aws elbv2 delete-load-balancer --load-balancer-arn "$arn" 2>&1 || true
  done
  if [ -n "$lb_arns" ]; then
    log "waiting for their ENIs to clear before touching security groups"
    for i in $(seq 1 30); do
      # Matched by description, not tag -- every ENI an ELB/NLB owns is
      # named "ELB ..." regardless of which tag convention provisioned
      # the load balancer itself, so this catches both without needing
      # to enumerate tag conventions a second time.
      remaining="$(aws ec2 describe-network-interfaces \
        --filters "Name=description,Values=ELB*" \
        --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0)"
      [ "$remaining" = "0" ] && break
      sleep 10
    done
  fi

  log "deleting any security groups an in-cluster controller provisioned for this EKS cluster"
  sg_ids="$({
    aws ec2 describe-security-groups \
      --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
      --query 'SecurityGroups[].GroupId' --output text 2>/dev/null
    aws ec2 describe-security-groups \
      --filters "Name=tag:elbv2.k8s.aws/cluster,Values=${CLUSTER_NAME}" \
      --query 'SecurityGroups[].GroupId' --output text 2>/dev/null
  } | tr '\t' '\n' | sort -u)"
  for sg in $sg_ids; do
    warn "deleting security group $sg (provisioned by an in-cluster controller, not terraform)"
    aws ec2 delete-security-group --group-id "$sg" 2>&1 || true
  done
else
  warn "couldn't read eks_cluster_name from terraform output -- skipping the tagged load-balancer/security-group sweep. If 'terraform destroy' below fails on the VPC or its subnets with DependencyViolation, check for orphaned 'k8s-*' load balancers and security groups by hand (both the kubernetes.io/cluster/<name>=owned and elbv2.k8s.aws/cluster=<name> tag conventions)."
fi

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
