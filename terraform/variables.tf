variable "aws_region" {
  description = "AWS region for EKS/VPC. The user's other demos in this account live in eu-west-1."
  type        = string
  default     = "eu-west-1"
}

variable "name" {
  description = "Short name prefix for every resource this stack creates."
  type        = string
  default     = "kubecon-agent-demo"
}

variable "vpc_cidr" {
  description = "CIDR for the demo VPC."
  type        = string
  default     = "10.70.0.0/16"
}

variable "availability_zone_count" {
  type    = number
  default = 2
}

variable "kubernetes_version" {
  description = "EKS control plane version."
  type        = string
  default     = "1.33"
}

variable "eks_node_instance_type" {
  description = "3x t3.large, not the old talk's 2x t3.medium: this stack runs Envoy Gateway + OPA + Kyverno + ArgoCD + CloudNativePG + SPIRE in addition to the app tier."
  type        = string
  default     = "t3.large"
}

variable "eks_node_count" {
  type    = number
  default = 3
}

variable "trust_domain" {
  description = "SPIFFE trust domain used by SPIRE and matched in the gateway's JWT issuer config."
  type        = string
  default     = "mahistores.demo"
}

variable "agent_namespace" {
  type    = string
  default = "agents"
}

variable "agent_service_account" {
  description = "The refund-agent's SPIFFE service account -- can look up orders AND issue refunds."
  type        = string
  default     = "ai-support-agent-secure"
}

variable "order_agent_service_account" {
  description = "The order-agent's SPIFFE service account -- read-only, cannot issue refunds. A genuinely separate SPIFFE identity, not a UI-level restriction -- see k8s/spire/values.yaml's two ClusterSPIFFEIDs and policy/rego's per-path rules."
  type        = string
  default     = "ai-order-agent"
}

# ---- public access ---------------------------------------------------------

variable "lbc_chart_version" {
  description = "aws-load-balancer-controller Helm chart version. CONFIRM against `helm search repo eks/aws-load-balancer-controller --versions`."
  type        = string
  default     = "3.6.2"
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version. CONFIRM against `helm search repo argo/argo-cd --versions`."
  type        = string
  default     = "10.11.6"
}

variable "alb_inbound_cidrs" {
  description = "CIDRs allowed to reach the public storefront ALB. The storefront exposes unauthenticated /api/admin/reset and similar endpoints, so leaving this at 0.0.0.0/0 means anyone who sees the URL can wipe the demo mid-talk. Narrow this to the presenter's current IP (`curl -s ifconfig.me`) right before the talk -- see docs/RUNBOOK.md."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
