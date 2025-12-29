#!/bin/bash
set -e

CLUSTER_NAME="devops-eks-cluster"
REGION="ap-south-1"
NODEGROUP_NAME="devops-ng"
NODE_TYPE="t3.small"
NODES=2
NODES_MIN=1
NODES_MAX=3
K8S_VERSION="1.29"

echo "🚀 Creating EKS Cluster: $CLUSTER_NAME"

eksctl create cluster \
  --name $CLUSTER_NAME \
  --region $REGION \
  --version $K8S_VERSION \
  --nodegroup-name $NODEGROUP_NAME \
  --node-type $NODE_TYPE \
  --nodes $NODES \
  --nodes-min $NODES_MIN \
  --nodes-max $NODES_MAX \
  --managed

echo "🔄 Updating kubeconfig on local machine"
aws eks update-kubeconfig \
  --region $REGION \
  --name $CLUSTER_NAME

echo "📌 Current kubectl context:"
kubectl config current-context

echo "📋 Nodes in cluster:"
kubectl get nodes

echo "✅ Cluster creation & context update complete"
