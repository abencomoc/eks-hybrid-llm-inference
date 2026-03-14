###############################################################
# Install Cilium CNI via Helm
###############################################################

resource "helm_release" "cilium" {
  name            = "cilium"
  repository      = "https://helm.cilium.io"
  chart           = "cilium"
  version         = "1.15.6"
  namespace       = "kube-system"
  wait            = false
  upgrade_install = true

  values = [templatefile("${path.module}/manifests/cilium-values.yaml", {
    remote_pod_cidr = var.remote_pod_cidr
  })]

  depends_on = [module.eks]
}

###############################################################
# Install NVIDIA GPU Operator via Helm
###############################################################

resource "helm_release" "gpu_operator" {
  name             = "gpu-operator"
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "gpu-operator"
  namespace        = "gpu-operator"
  create_namespace = true
  wait             = false
  upgrade_install  = true

  values = [file("${path.module}/manifests/gpu-operator-values.yaml")]

  depends_on = [module.eks]
}

###############################################################
# Apply GPU NodeClass and NodePool manifests
###############################################################

resource "kubectl_manifest" "gpu_nodeclass" {
  yaml_body = templatefile("${path.module}/manifests/gpu-nodeclass.yaml", {
    node_iam_role_name                = module.eks.node_iam_role_name
    node_security_group_id            = module.eks.node_security_group_id
    cluster_primary_security_group_id = module.eks.cluster_primary_security_group_id
    private_subnet_ids                = module.vpc.private_subnets
  })

  depends_on = [module.eks]
}

resource "kubectl_manifest" "gpu_nodepool" {
  yaml_body = templatefile("${path.module}/manifests/gpu-nodepool.yaml", {})

  depends_on = [kubectl_manifest.gpu_nodeclass]
}

###############################################################
# Apply ALB IngressClass and IngressClassParams manifests
###############################################################

resource "kubectl_manifest" "alb_ingressclassparams" {
  yaml_body = file("${path.module}/manifests/alb-ingressclassparams.yaml")

  depends_on = [module.eks]
}

resource "kubectl_manifest" "alb_ingressclass" {
  yaml_body = file("${path.module}/manifests/alb-ingressclass.yaml")

  depends_on = [kubectl_manifest.alb_ingressclassparams]
}
