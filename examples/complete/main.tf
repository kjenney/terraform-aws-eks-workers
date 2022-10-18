provider "aws" {
  region = var.region
}

module "label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  attributes = ["cluster"]

  context = module.this.context
}

locals {
  # The usage of the specific kubernetes.io/cluster/* resource tags below are required
  # for EKS and Kubernetes to discover and manage networking resources
  # https://aws.amazon.com/premiumsupport/knowledge-center/eks-vpc-subnet-discovery/
  # https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/main/docs/deploy/subnet_discovery.md
  tags = { "kubernetes.io/cluster/${module.label.id}" = "shared" }

  # required tags to make ALB ingress work https://docs.aws.amazon.com/eks/latest/userguide/alb-ingress.html
  public_subnets_additional_tags = {
    "kubernetes.io/role/elb" : 1
  }
  private_subnets_additional_tags = {
    "kubernetes.io/role/internal-elb" : 1
  }
}

module "vpc" {
  source  = "cloudposse/vpc/aws"
  version = "1.1.0"

  cidr_block = "172.16.0.0/16"
  tags       = local.tags

  context = module.this.context
}

module "subnets" {
  source  = "cloudposse/dynamic-subnets/aws"
  version = "2.0.2"

  availability_zones   = var.availability_zones
  vpc_id               = module.vpc.vpc_id
  igw_id               = [module.vpc.igw_id]
  ipv4_cidr_block      = [module.vpc.vpc_cidr_block]
  nat_gateway_enabled  = false
  nat_instance_enabled = false
  tags                 = local.tags

  context = module.this.context
}

module "eks_cluster" {
    source = "cloudposse/eks-cluster/aws"
    version = "2.5.0"

    name       = var.cluster_name

    vpc_id     = module.vpc.vpc_id
    subnet_ids = module.subnets.public_subnet_ids

    kubernetes_version    = var.kubernetes_version
    oidc_provider_enabled = true

    region      = var.region

    context = module.label.context
  }

module "eks_workers" {
  source = "cloudposse/eks-workers/aws"
  version = "1.0.0-rc2"

  instance_type                          = var.instance_type
  vpc_id                                 = module.vpc.vpc_id
  subnet_ids                             = module.subnets.public_subnet_ids
  health_check_type                      = var.health_check_type
  min_size                               = var.min_size
  max_size                               = var.max_size
  wait_for_capacity_timeout              = var.wait_for_capacity_timeout
  cluster_name                           = module.eks_cluster.eks_cluster_id
  cluster_endpoint                       = module.eks_cluster.eks_cluster_endpoint
  cluster_certificate_authority_data     = module.eks_cluster.eks_cluster_certificate_authority_data
  cluster_security_group_id              = module.eks_cluster.eks_cluster_managed_security_group_id
  cluster_security_group_ingress_enabled = var.cluster_security_group_ingress_enabled
  bootstrap_extra_args                   = "--use-max-pods false"
  kubelet_extra_args                     = "--node-labels=purpose=ci-worker"

  # Auto-scaling policies and CloudWatch metric alarms
  autoscaling_policies_enabled           = var.autoscaling_policies_enabled
  cpu_utilization_high_threshold_percent = var.cpu_utilization_high_threshold_percent
  cpu_utilization_low_threshold_percent  = var.cpu_utilization_low_threshold_percent

  # Mixed instance policy

  mixed_instances_policy = ({
    instances_distribution = ({
      on_demand_allocation_strategy            = "prioritized"
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 25
      spot_allocation_strategy                 = "capacity-optimized"
      spot_instance_pools                      = 0
      spot_max_price                           = "1.20"
    })
    override = [({
      instance_type     = var.instance_type
      weighted_capacity = var.mixed_instance_policy_weighted_capacity
    })]
  })

  context = module.this.context
}
