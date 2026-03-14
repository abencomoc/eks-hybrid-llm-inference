# EKS Hybrid LLM Inference Demo

## Introduction

This demo showcases **Amazon EKS** managing GPU infrastructure across both on-premises and cloud nodes — leveraging **EKS Hybrid Nodes**, **EKS Auto Mode**, and **NVIDIA NIM** to bring it to life.

It demonstrates how EKS Hybrid Nodes lets you extend a Kubernetes cluster to infrastructure outside of AWS, enabling a unified operational model for workloads that span on-prem and cloud.

---

## Part 1 — Create GPU-Enabled EKS Hybrid Cluster

#### Step 1 — Run Terraform

```bash
cd infra-tf
terraform init
terraform apply --auto-approve
```

Terraform creates all required infrastructure and deploys the necessary cluster components to manage GPUs on both cloud and hybrid nodes.

Main actions:

**Create EKS Cluster**
- VPC, subnets, security groups
- EKS Auto Mode to fully manage the EKS data plane in the cloud — GPU nodes, networking, storage, and more
- GPU NodeClass and NodePool for cloud GPU provisioning
- EKS Hybrid Nodes enabled at cluster creation by providing remote node CIDR and remote pod CIDR

**Set Up Hybrid Nodes**
- Simulate EKS Hybrid Nodes using AWS resources (for demo purposes only): remote VPC + EC2 ASG
- Network connectivity via VPC peering and routing tables
- Hybrid node IAM role, EKS access entry, and SSM activation for node registration
- Bootstrap hybrid nodes using the EKS Hybrid Node CLI (`nodeadm`), automated via UserData script
- Networking addons for hybrid nodes: Cilium CNI, CoreDNS, kube-proxy

**Deploy NVIDIA GPU Operator**
- NVIDIA drivers for the hybrid node OS
- Container toolkit for containerd runtime
- Kubernetes device plugin to expose GPUs to Kubernetes scheduler



#### Step 2 — Configure kubectl

```bash
$(terraform output -raw configure_kubectl)
```

#### Step 3 — Verify Hybrid Nodes

```bash
kubectl get nodes -l eks.amazonaws.com/compute-type=hybrid
```

#### Step 4 — Verify GPU Capacity on Both Nodes

Run `nvidia-smi` on the cloud node (Auto Mode):

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nvidia-smi-cloud
spec:
  restartPolicy: OnFailure
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: eks.amazonaws.com/compute-type
            operator: In
            values:
            - auto
  tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  containers:
  - name: nvidia-smi
    image: nvidia/cuda:12.9.1-base-ubuntu20.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: "1"
EOF
kubectl logs nvidia-smi-cloud
```

Run `nvidia-smi` on the hybrid node (on-prem):

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nvidia-smi-hybrid
spec:
  restartPolicy: OnFailure
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: eks.amazonaws.com/compute-type
            operator: In
            values:
            - hybrid
  containers:
  - name: nvidia-smi
    image: nvidia/cuda:12.9.1-base-ubuntu20.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: "1"
EOF
kubectl logs nvidia-smi-hybrid
```

At this point you have GPU-enabled nodes — both hybrid and cloud — fully managed by a single EKS cluster, ready to receive AI workloads.

---

## Part 2 — Deploy LLM Inference Microservices Using NVIDIA NIMs

#### Step 1 — Set Up NGC Credentials

```bash
kubectl create namespace nim-service

NGC_API_KEY=<your-ngc-api-key>

kubectl create secret -n nim-service docker-registry ngc-secret \
    --docker-server=nvcr.io \
    --docker-username='$oauthtoken' \
    --docker-password=$NGC_API_KEY

kubectl create secret -n nim-service generic ngc-api-secret \
    --from-literal=NGC_API_KEY=$NGC_API_KEY
```

#### Step 2 — Install NIM Operator

The NIM Operator manages the lifecycle of NIM deployments on Kubernetes.

```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

helm upgrade --install nim-operator nvidia/k8s-nim-operator \
    -n nim-operator --create-namespace --version=3.1.0

kubectl get pods -n nim-operator
```

#### Step 3 — Deploy NIM Services

Deploy both models with a single command:

```bash
kubectl apply -f deploy-nim/
```

This deploys:
- **Gemma 2 2B** (`nvcr.io/nim/google/gemma-2-2b-instruct`) → cloud GPU node (Auto Mode), pinned via `eks.amazonaws.com/compute-type: auto`
- **Llama 3.2 3B** (`nvcr.io/nim/meta/llama-3.2-3b-instruct`) → hybrid GPU node (on-prem), pinned via `eks.amazonaws.com/compute-type: hybrid`

Monitor rollout:
```bash
kubectl get pods -n nim-service -w
```

#### Step 4 — Run Inference in Cloud (Gemma on Auto Mode)

Get the Load Balancer URL for the Gemma Open WebUI:

```bash
kubectl get svc cloud-gemma-ui -n nim-service \
    -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}{"\n"}'
```

Open the URL in your browser to chat with **Gemma 2 2B** running on a cloud GPU node.

#### Step 5 — Run Inference on Hybrid Nodes (Llama on-prem)

Get the public IP of the hybrid node and access the Llama Open WebUI via NodePort:

```bash
aws ec2 describe-instances \
    --filters 'Name=tag:aws:autoscaling:groupName,Values=hybrid-llm-hybrid-node-asg' \
              'Name=instance-state-name,Values=running' \
    --query 'Reservations[*].Instances[*].PublicIpAddress' \
    --output text | awk '{print "http://"$1":30080"}'
```

Open the URL in your browser to chat with **Llama 3.2 3B** running on the on-prem GPU node.

---

## Part 3 — Burst to Cloud

*Coming soon.*

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    EKS Control Plane                        │
│                  hybrid-llm-eks-cluster                     │
└──────────────────────┬──────────────────────────────────────┘
                       │
          ┌────────────┴────────────┐
          │                         │
┌─────────▼──────────┐   ┌──────────▼─────────┐
│  EKS Auto Mode     │   │  EKS Hybrid Nodes  │
│  Cloud GPU Node    │   │  On-Prem GPU Node  │
│  (g5/g6 via Auto)  │   │  (EC2 in remote    │
│                    │   │   VPC via SSM)     │
│  Gemma 2 2B NIM    │   │  Llama 3.2 3B NIM  │
│  Open WebUI (ALB)  │   │  Open WebUI (:30080)│
└────────────────────┘   └────────────────────┘
     10.226.0.0/24            172.17.0.0/16
                              pods: 172.18.0.0/16
```

## Prerequisites

- AWS CLI configured with sufficient permissions
- Terraform >= 1.3
- `kubectl`
- `helm`
- An NGC API key from [ngc.nvidia.com](https://ngc.nvidia.com)
- An EC2 key pair in the target region (default: `us-west-2`)
