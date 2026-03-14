#!/bin/bash
apt-get update
apt-get install -y linux-headers-$(uname -r) build-essential unzip

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

curl -OL 'https://hybrid-assets.eks.amazonaws.com/releases/latest/bin/linux/amd64/nodeadm'
chmod +x nodeadm
mv nodeadm /usr/bin/

nodeadm install ${kubernetes_version} --credential-provider ssm

cat <<EOF > /root/nodeConfig.yaml
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${cluster_name}
    region: ${region}
  hybrid:
    ssm:
      activationCode: ${ssm_activation_code}
      activationId: ${ssm_activation_id}
EOF

nodeadm init -c file:///root/nodeConfig.yaml
