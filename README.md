# devops-eks-cluster

# EKS Cluster Automation

Automated creation and deletion of an Amazon EKS cluster using Bash scripts, with automatic kubeconfig context management. Designed for **cost-optimized DevOps practice** and on-demand Kubernetes environments.

## Features
- Create EKS cluster with managed node group
- Automatically update `kubectl` context on cluster creation
- Cleanly remove kubeconfig context on cluster deletion
- Reduce AWS costs by creating clusters only when needed

## Prerequisites
- AWS CLI
- kubectl
- eksctl
- AWS credentials configured (`aws configure`)

## Usage

### Create Cluster
```bash
chmod +x create-eks.sh
./create-eks.sh
```

### Delete Cluster
```bash
chmod +x delete-eks.sh
./delete-eks.sh
```
