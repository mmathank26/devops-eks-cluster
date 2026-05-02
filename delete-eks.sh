#!/bin/bash
set -euo pipefail

### CONFIGURATION (SAFE MODE DEFAULTS)
CLUSTER_NAME="devops-eks-cluster"
REGION="ap-south-1"

#ALB_SA_NAME="aws-load-balancer-controller"
ALB_NAMESPACE="kube-system"

EBS_ROLE_NAME="AmazonEKS_EBS_CSI_DriverRole"
ALB_POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"

DELETE_IAM=false   # ⚠️ set true ONLY for full teardown

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

cluster_exists() {
  aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1
}

log "Starting SAFE delete for EKS cluster: $CLUSTER_NAME"

if cluster_exists; then
  log "Cluster exists. Attempting graceful in-cluster cleanup"

  if command -v kubectl >/dev/null 2>&1; then
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" || true
  fi

  if command -v helm >/dev/null 2>&1; then
    if helm status aws-load-balancer-controller -n "$ALB_NAMESPACE" >/dev/null 2>&1; then
      log "Deleting AWS Load Balancer Controller Helm release"
      helm uninstall aws-load-balancer-controller -n "$ALB_NAMESPACE" || true
    fi
  fi

  log "Deleting EKS cluster via eksctl"
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" || true
else
  log "Cluster does not exist. Skipping cluster delete"
fi

log "Waiting for CloudFormation stacks to settle"
sleep 10

if [[ "$DELETE_IAM" == "true" ]]; then
  log "FULL DESTROY enabled → Cleaning IAM resources"

  if aws iam get-role --role-name "$EBS_ROLE_NAME" >/dev/null 2>&1; then
    log "Deleting EBS CSI IAM role"
    aws iam detach-role-policy \
      --role-name "$EBS_ROLE_NAME" \
      --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy || true
    aws iam delete-role --role-name "$EBS_ROLE_NAME" || true
  fi

  POLICY_ARN=$(aws iam list-policies \
    --scope Local \
    --query "Policies[?PolicyName=='$ALB_POLICY_NAME'].Arn" \
    --output text)

  if [[ -n "$POLICY_ARN" ]]; then
    log "Deleting ALB IAM policy"
    aws iam delete-policy --policy-arn "$POLICY_ARN" || true
  fi
else
  log "SAFE MODE → IAM resources preserved"
fi

log "Delete script completed cleanly"