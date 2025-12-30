#!/bin/bash
set -x

CLUSTER_NAME="devops-eks-cluster"
REGION="ap-south-1"
NODEGROUP_NAME="devops-ng"
NODE_TYPE="t3.small"
NODES=2
NODES_MIN=1
NODES_MAX=3
K8S_VERSION="1.29"

STACK_NAME="eksctl-${CLUSTER_NAME}-cluster"
LOCKFILE="/tmp/${CLUSTER_NAME}.lock"



# =========================
# GUARDS
# =========================

# Prevent parallel execution
if [ -f "$LOCKFILE" ]; then
  echo "❌ Script already running. Lock file exists."
  exit 1
fi
trap "rm -f $LOCKFILE" EXIT
touch "$LOCKFILE"

# Required tools check
for cmd in aws kubectl eksctl; do
  if ! command -v $cmd >/dev/null 2>&1; then
    echo "❌ Required command '$cmd' not found"
    exit 1
  fi
done

# AWS credentials check
aws sts get-caller-identity >/dev/null 2>&1 || {
  echo "❌ AWS credentials not configured or expired"
  exit 1
}

# Cluster existence check
if eksctl get cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "❌ EKS cluster '$CLUSTER_NAME' already exists"
  exit 1
fi

# CloudFormation stack existence check
STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].StackStatus" \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$STACK_STATUS" != "NOT_FOUND" ]]; then
  echo "❌ CloudFormation stack already exists with status: $STACK_STATUS"
  echo "👉 Clean it using eksctl delete cluster"
  exit 1
fi

# =========================
# CREATE CLUSTER
# =========================

echo "🚀 Creating EKS cluster: $CLUSTER_NAME"

eksctl create cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --version "$K8S_VERSION" \
  --nodegroup-name "$NODEGROUP_NAME" \
  --node-type "$NODE_TYPE" \
  --nodes "$NODES" \
  --nodes-min "$NODES_MIN" \
  --nodes-max "$NODES_MAX" \
  --managed

# =========================
# UPDATE KUBECONFIG
# =========================

echo "🔄 Updating kubeconfig"
aws eks update-kubeconfig \
  --region "$REGION" \
  --name "$CLUSTER_NAME"

echo "📌 Current kubectl context:"
kubectl config current-context

echo "📋 Cluster nodes:"
kubectl get nodes

echo "✅ EKS cluster creation completed successfully"
