#!/bin/bash
set -e

CLUSTER_NAME="devops-eks-cluster"
REGION="ap-south-1"
KUBE_CONTEXT="arn:aws:eks:${REGION}:$(aws sts get-caller-identity --query Account --output text):cluster/${CLUSTER_NAME}"

echo "🔥 Deleting EKS Cluster: $CLUSTER_NAME"

eksctl delete cluster \
  --name $CLUSTER_NAME \
  --region $REGION

echo "🧹 Cleaning kubeconfig context: $KUBE_CONTEXT"

# Remove context
kubectl config delete-context "$KUBE_CONTEXT" || true

# Remove cluster entry
kubectl config delete-cluster "$KUBE_CONTEXT" || true

# Remove user entry
kubectl config delete-user "$KUBE_CONTEXT" || true

echo "📌 Remaining kubectl contexts:"
kubectl config get-contexts

echo "✅ Cluster deleted & kubeconfig cleaned"
