terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0" # the eks module (~> 21.0) pulls in a >= 6.59.0 constraint
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    helm = {
      source = "hashicorp/helm"
      # 2.x, not 3.x: v3 moved to the plugin framework and the
      # `kubernetes { ... }` block became a `kubernetes = { ... }`
      # attribute. 2.17 is the well-trodden schema -- switch deliberately,
      # not by an unpinned upgrade.
      version = "~> 2.17"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# `exec` plugin auth, not a static data source: `aws eks get-token` is
# requested fresh on every provider call, so it survives an apply that
# creates EKS (~12 min) and then installs Helm charts -- a baked-in
# aws_eks_cluster_auth token (good for ~15 min) would not.
locals {
  eks_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = local.eks_exec.api_version
    command     = local.eks_exec.command
    args        = local.eks_exec.args
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = local.eks_exec.api_version
      command     = local.eks_exec.command
      args        = local.eks_exec.args
    }
  }
}
