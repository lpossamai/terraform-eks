locals {
  defaulted_node_groups = [
    for wg in var.node_groups :
    merge(var.node_group_defaults, wg)
  ]

  defaulted_managed_node_groups = [
    for mng in var.managed_node_groups :
    merge(var.managed_node_group_defaults, mng)
  ]

  defaulted_worker_groups = [
    for wg in local.defaulted_node_groups :
    {
      lifecycle = wg.lifecycle

      # Worker group specific values
      name                 = wg.name
      instance_type        = flatten([wg.instance_type])[0]
      asg_min_size         = wg.min_count
      asg_desired_capacity = wg.count
      asg_max_size         = wg.max_count
      subnets              = wg.subnets == null ? var.subnets : wg.subnets
      kubelet_extra_args = replace(
        <<-EOT
                                --node-labels=groupName=${wg.name},${wg.external_lb ? "" : "alpha.service-controller.kubernetes.io/exclude-balancer=true,"}instanceId=$(curl http://169.254.169.254/latest/meta-data/instance-id)
                                ${wg.dedicated ? " --register-with-taints=dedicated=${wg.name}:NoSchedule" : ""}
                                --eviction-hard=\"memory.available<5%\"
                                --eviction-soft=\"memory.available<10%\"
                                --eviction-soft-grace-period=\"memory.available=5m\"
                                --system-reserved=\"memory=500Mi\"
                              EOT
      , "\n", " ")

      tags = concat([
        {
          key                 = "groupName"
          value               = wg.name
          propagate_at_launch = true
        },
        {
          key                 = "alpha.service-controller.kubernetes.io/exclude-balancer"
          value               = wg.external_lb ? "false" : "true"
          propagate_at_launch = true
        },
        {
          key                 = "k8s.io/cluster-autoscaler/node-template/label"
          value               = wg.name
          propagate_at_launch = true
        },
        # Also forces nodes to not be created until cni is applied
        {
          key                 = "k8s.io/cni/genie"
          value               = var.genie_cni ? kubectl_manifest.genie_resources[0].uid : "false"
          propagate_at_launch = true
        },
        {
          key                 = "k8s.io/cni/calico"
          value               = var.calico_cni ? kubectl_manifest.calico_resources[0].uid : "false"
          propagate_at_launch = true
        },
        {
          key                 = "k8s.io/cni/aws"
          value               = kubectl_manifest.aws_cni_resources[0].uid
          propagate_at_launch = true
        }],
        wg.dedicated ? [{
          key                 = "k8s.io/cluster-autoscaler/node-template/taint/dedicated"
          value               = "${wg.name}:NoSchedule"
          propagate_at_launch = true
        }] : [],
        wg.autoscale ? [{
          key                 = "k8s.io/cluster-autoscaler/enabled"
          value               = "true"
          propagate_at_launch = false
          },
          {
            "key"                 = "k8s.io/cluster-autoscaler/${var.name}"
            "propagate_at_launch" = "false"
            "value"               = "true"
          },
          {
            "key"                 = "k8s.io/cluster-autoscaler/node-template/resources/ephemeral-storage"
            "propagate_at_launch" = "false"
            "value"               = "100Gi"
        }] : []
      )

      # Vars for all worker groups
      key_name             = var.nodes_key_name
      pre_userdata         = templatefile("${path.module}/workers_user_data.sh.tpl", { pre_userdata = var.pre_userdata })
      ami_id               = var.nodes_ami_id == "" ? (wg.gpu ? data.aws_ami.eks_gpu_worker.id : data.aws_ami.eks_worker.id) : var.nodes_ami_id
      termination_policies = ["OldestLaunchConfiguration", "Default"]

      enabled_metrics = [
        "GroupDesiredCapacity",
        "GroupInServiceInstances",
        "GroupMaxSize",
        "GroupMinSize",
        "GroupPendingInstances",
        "GroupStandbyInstances",
        "GroupTerminatingInstances",
        "GroupTotalInstances",
      ]

      # Spot specific vars (when relevant)
      spot_instance_pools                      = wg.spot_instance_pools
      on_demand_base_capacity                  = wg.on_demand_base_capacity
      on_demand_percentage_above_base_capacity = wg.on_demand_percentage_above_base_capacity
      override_instance_types                  = wg.override_instance_types == null ? flatten([wg.instance_type]) : wg.override_instance_types
    }
  ]
}

data "aws_caller_identity" "current" {
}

data "aws_partition" "current" {
}

data "aws_ami" "eks_worker" {
  filter {
    name   = "name"
    values = ["amazon-eks-node-${var.cluster_version}-v*"]
  }

  most_recent = true

  # Owner ID of AWS EKS team
  owners = ["602401143452"]
}

data "aws_ami" "eks_gpu_worker" {
  filter {
    name   = "name"
    values = ["amazon-eks-gpu-node-${var.cluster_version}-v*"]
  }

  most_recent = true

  # Owner ID of AWS EKS team
  owners = ["602401143452"]
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
  version                = "~> 1.10"
}

provider "kubectl" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
}


module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "16.2.0"

  cluster_name    = var.name
  cluster_version = var.cluster_version

  vpc_id  = var.vpc_id
  subnets = var.subnets

  #We need to manage auth ourselves since we create the workers later their role wont be added
  # manage_aws_auth = "true"
  map_users    = var.map_users
  map_roles    = var.map_roles
  map_accounts = var.map_accounts

  write_kubeconfig   = "true"
  config_output_path = abspath("${path.root}/${var.name}.kubeconfig")

  kubeconfig_aws_authenticator_env_variables = {
    AWS_PROFILE = var.aws_profile
  }

  enable_irsa = var.enable_irsa

  worker_additional_security_group_ids = var.nodes_additional_security_group_ids

  # This will launch an autoscaling group with only On-Demand instances
  worker_groups = [
    for wg in local.defaulted_worker_groups : wg if wg.lifecycle != "spot"
  ]

  # This will launch an autoscaling group with Spot instances
  worker_groups_launch_template = [
    for wg in local.defaulted_worker_groups :
    merge(wg, {
      suspended_processes : ["AZRebalance"],
      kubelet_extra_args : replace(wg.kubelet_extra_args, "--node-labels=", "--node-labels=node.kubernetes.io/lifecycle=spot,")
    })
    if wg.lifecycle == "spot"
  ]

  node_groups = [
    for mng in local.defaulted_managed_node_groups :
    {
      # Worker group specific values
      name             = mng.name
      min_capacity     = mng.min_count
      desired_capacity = mng.count
      max_capacity     = mng.max_count
      instance_type    = mng.instance_type
      disk_size        = mng.disk_size
      subnets          = mng.subnets == null ? var.subnets : mng.subnets

      additional_tags = merge({
        "name"                                                    = "${var.name}-${mng.name}-eks-managed",
        "groupName"                                               = mng.name,
        "alpha.service-controller.kubernetes.io/exclude-balancer" = mng.external_lb ? "false" : "true",
        "k8s.io/cluster-autoscaler/node-template/label"           = mng.name,
        }, mng.dedicated ? {
        "k8s.io/cluster-autoscaler/node-template/taint/dedicated" = "${mng.name}:NoSchedule"
        } : {
        }, mng.autoscale ? {
        "k8s.io/cluster-autoscaler/enabled"                                   = "true",
        "k8s.io/cluster-autoscaler/${var.name}"                               = "true",
        "k8s.io/cluster-autoscaler/node-template/resources/ephemeral-storage" = "${mng.disk_size}Gi"
      } : {})

      # TODO register with taints
      # https://github.com/aws/containers-roadmap/issues/585
      # https://github.com/aws/containers-roadmap/issues/864

      # TODO SSM Support
      # https://github.com/aws/containers-roadmap/issues/593

      # TODO verify autoscaling working
      # TODO verify load balancer tag works

      k8s_labels = merge(
        { "groupName" = mng.name },
        mng.external_lb ? {} : {
          "alpha.service-controller.kubernetes.io/exclude-balancer" = "true"
        },
        mng.additional_labels
      )

      key_name = var.allow_ssh ? var.nodes_key_name : null
    }
  ]

  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = {
    Owner       = "Terraform"
    Environment = var.environment
  }
}
