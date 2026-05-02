#!/usr/bin/env bash
set -euo pipefail

############################################
# SAFE MODE – IDEMPOTENT EKS CREATION SCRIPT
############################################
# Principles:
# 1. EKS addons OWN their ServiceAccounts
# 2. Script owns IAM roles & Helm-managed SAs
# 3. Re-runnable without conflicts
############################################

############################################
# CONFIG
############################################
CLUSTER_NAME="devops-eks-cluster"
REGION="ap-south-1"
AZ="ap-south-1a,ap-south-1b"
K8S_VERSION="1.29"
NODEGROUP_NAME="devops-ng"
NODE_TYPE="t3.medium"
DESIRED_NODES=1
MIN_NODES=1
MAX_NODES=3

EBS_ROLE_NAME="AmazonEKS_EBS_CSI_DriverRole"
ALB_POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
EFS_ROLE_NAME="AmazonEKS_EFS_CSI_DriverRole"

LOCKFILE="/tmp/${CLUSTER_NAME}.lock"

############################################
# LOCK
############################################
if [[ -f "$LOCKFILE" ]]; then
  echo "❌ Script already running"
  exit 1
fi
trap "rm -f $LOCKFILE" EXIT
touch "$LOCKFILE"

############################################
# PREREQS
############################################
for cmd in aws kubectl eksctl helm jq; do
  command -v $cmd >/dev/null || { echo "❌ $cmd missing"; exit 1; }
done

aws sts get-caller-identity >/dev/null || { echo "❌ AWS auth failed"; exit 1; }
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

############################################
# HELPERS
############################################
cluster_exists() {
  eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1
}

addon_exists() {
  aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name "$1" --region "$REGION" >/dev/null 2>&1
}

iam_role_exists() {
  aws iam get-role --role-name "$1" >/dev/null 2>&1
}

############################################
# PreCheck - CloudFormation stack
############################################

if aws cloudformation describe-stacks \
  --stack-name eksctl-${CLUSTER_NAME}-cluster \
  --region "$REGION" >/dev/null 2>&1; then
  echo "❌ CloudFormation stack exists. Clean it before proceeding."
  exit 1
fi


############################################
# PHASE 1: CLUSTER
############################################

## Removing this cluster creation with nodegroup. Updated script to create cl
# if ! cluster_exists; then
#   echo "🚀 Creating EKS cluster"
#   eksctl create cluster \
#     --name "$CLUSTER_NAME" \
#     --region "$REGION" \
#     --version "$K8S_VERSION" \
#     --zones "$AZ" \
#     --nodegroup-name "$NODEGROUP_NAME" \
#     --node-type "$NODE_TYPE" \
#     --nodes "$DESIRED_NODES" \
#     --nodes-min "$MIN_NODES" \
#     --nodes-max "$MAX_NODES" \
#     --managed \
#     --node-private-networking
# else
#   echo "✅ Cluster exists"
# fi


REGION="ap-south-1"
CLUSTER="devops-eks-cluster"

##################################
# AUTO FIND VPC
##################################

VPC=$(aws ec2 describe-vpcs \
--filters Name=tag:Name,Values=eksctl-devops-eks-cluster-cluster/VPC \
--query "Vpcs[0].VpcId" \
--output text)

echo "Using VPC $VPC"

##################################
# FIND SUBNETS
##################################

PRIVATE=$(aws ec2 describe-subnets \
--filters Name=vpc-id,Values=$VPC \
Name=tag:kubernetes.io/role/internal-elb,Values=1 \
--query "Subnets[].SubnetId" \
--output text | tr '\t' ',')

PUBLIC=$(aws ec2 describe-subnets \
--filters Name=vpc-id,Values=$VPC \
Name=tag:kubernetes.io/role/elb,Values=1 \
--query "Subnets[].SubnetId" \
--output text | tr '\t' ',')

##################################
# CREATE CLUSTER
##################################

eksctl create cluster \
--name $CLUSTER \
--region $REGION \
--without-nodegroup \
--vpc-private-subnets=$PRIVATE \
--vpc-public-subnets=$PUBLIC

##################################
# SYSTEM NODEGROUP
##################################

eksctl create nodegroup \
--cluster $CLUSTER \
--name system-ng \
--node-type t3.medium \
--nodes-min 1 \
--nodes 2 \
--nodes-max 3 \
--node-labels workload=system \
--subnet-ids $PRIVATE \
--node-private-networking \
--managed

##################################
# JENKINS NODEGROUP
##################################
# Uncomment it if you want to create a separate nodegroup for Jenkins. By default, Jenkins will be scheduled on system-ng nodegroup with label workload=system

# eksctl create nodegroup \
# --cluster $CLUSTER \
# --name jenkins-ng \
# --node-type t3.large \
# --nodes-min 1 \
# --nodes 1 \
# --nodes-max 3 \
# --node-labels workload=jenkins \
# --node-zones ap-south-1a \
# --managed

aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"

############################################
# PHASE 2: OIDC
############################################
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION" \
  --approve || true

############################################
# PHASE 3: EBS CSI DRIVER (SAFE MODE)
############################################
echo "🔧 EBS CSI Driver"

if ! iam_role_exists "$EBS_ROLE_NAME"; then
  echo "➕ Creating IAM role for EBS CSI"
  eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" \
    --namespace kube-system \
    --name ebs-csi-controller-sa \
    --region "$REGION" \
    --role-name "$EBS_ROLE_NAME" \
    --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
    --approve \
    --role-only
else
  echo "✅ EBS IAM role exists"
fi

if ! addon_exists aws-ebs-csi-driver; then
  echo "➕ Installing EBS CSI addon"
  aws eks create-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name aws-ebs-csi-driver \
    --service-account-role-arn "arn:aws:iam::$ACCOUNT_ID:role/$EBS_ROLE_NAME" \
    --resolve-conflicts OVERWRITE \
    --region "$REGION"
else
  echo "✅ EBS CSI addon exists"
fi

############################################
# STORAGECLASS
############################################
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-gp3
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF

############################################
# PHASE 4: AWS LOAD BALANCER CONTROLLER
############################################
echo "🔧 AWS Load Balancer Controller"

if ! aws iam get-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/$ALB_POLICY_NAME >/dev/null 2>&1; then
  echo "➕ Creating ALB IAM policy"
  curl -s https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json \
    -o /tmp/alb-policy.json
  aws iam create-policy \
    --policy-name "$ALB_POLICY_NAME" \
    --policy-document file:///tmp/alb-policy.json
fi

POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$ALB_POLICY_NAME"

if ! kubectl get sa aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
  eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" \
    --namespace kube-system \
    --name aws-load-balancer-controller \
    --attach-policy-arn "$POLICY_ARN" \
    --approve
else
  echo "✅ ALB ServiceAccount exists"
fi

helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update

if ! helm status aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
  helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName="$CLUSTER_NAME" \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller
else
  echo "✅ ALB Controller installed"
fi


############################################
# PHASE 5: AWS EFS CSI DRIVER
############################################

if ! iam_role_exists "$EFS_ROLE_NAME"; then
  echo "Creating IAM role for EFS CSI"
  eksctl create iamserviceaccount \
    --cluster "$CLUSTER_NAME" \
    --namespace kube-system \
    --region "$REGION" \
    --name efs-csi-controller-sa \
    --role-name "$EFS_ROLE_NAME" \
    --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy \
    --approve \
   
else  
  echo "✅ EFS IAM role exists"
fi

if ! addon_exists aws-efs-csi-driver; then
  echo "Installing EFS CSI addon"
  aws eks create-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name aws-efs-csi-driver \
    --service-account-role-arn "arn:aws:iam::$ACCOUNT_ID:role/$EFS_ROLE_NAME" \
    --resolve-conflicts OVERWRITE \
    --region "$REGION"
else
  echo "✅ EFS CSI addon exists"
fi



############################################
# VERIFICATION
############################################
echo "🔍 Verifying"
kubectl get nodes
kubectl get pods -n kube-system | greo -E 'ebs|load-balancer'

############################################
# DONE
############################################
echo "🎉 SAFE MODE EKS CLUSTER READY"
