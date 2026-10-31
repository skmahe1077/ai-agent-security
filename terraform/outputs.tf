output "aws_region" {
  value = var.aws_region
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_update_kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

# ArgoCD's initial admin password lives in a Secret the chart creates
# (argocd-initial-admin-secret), not a Terraform resource attribute --
# nothing to output here beyond how to reach the UI.
output "argocd_portforward_command" {
  value = "kubectl -n argocd port-forward svc/argocd-server 8080:80"
}

output "argocd_namespace" {
  # Deliberately a resource attribute, not the bare var the way the old
  # repo's vault_k8s_namespace output had to be -- see that file's comment:
  # Terraform only writes an output during a -target'ed apply if it's
  # reachable from a targeted resource.
  value = helm_release.argocd.namespace
}
