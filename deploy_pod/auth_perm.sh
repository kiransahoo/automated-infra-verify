#!/bin/bash
set -e

# Required variables - change these
ACR_NAME="netsentry"  # Your ACR name
AKS_CLUSTER_NAME="myAKSCluster"  # Your AKS cluster name
RESOURCE_GROUP="myAKSResourceGroup"  # Resource group containing both
SECRET_NAME="acr-auth"  # Name for the Kubernetes secret

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== AKS-ACR Authentication Fix Script ===${NC}"

# Get ACR details
echo -e "${YELLOW}Getting ACR details...${NC}"
ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv)
ACR_USERNAME=$(az acr credential show --name "$ACR_NAME" --query username -o tsv)
ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --query passwords[0].value -o tsv)

echo -e "${YELLOW}ACR Login Server: ${GREEN}$ACR_LOGIN_SERVER${NC}"

# Make sure admin is enabled
echo -e "${YELLOW}Ensuring ACR admin is enabled...${NC}"
az acr update --name "$ACR_NAME" --admin-enabled true

# Get AKS credentials
echo -e "${YELLOW}Getting AKS credentials...${NC}"
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" --overwrite-existing

# Create Kubernetes secret
echo -e "${YELLOW}Creating Kubernetes secret...${NC}"
kubectl delete secret $SECRET_NAME --ignore-not-found=true

kubectl create secret docker-registry $SECRET_NAME \
  --docker-server="$ACR_LOGIN_SERVER" \
  --docker-username="$ACR_USERNAME" \
  --docker-password="$ACR_PASSWORD" \
  --docker-email="user@example.com"

echo -e "${GREEN}Successfully created secret '$SECRET_NAME' for ACR authentication${NC}"

# Test if it works
echo -e "${YELLOW}Testing image pull with secret...${NC}"
kubectl delete pod test-acr-auth --ignore-not-found=true --force --grace-period=0
sleep 2

kubectl run test-acr-auth \
  --image="$ACR_LOGIN_SERVER/netsentry:latest" \
  --restart=Never \
  --overrides="{\"spec\":{\"imagePullSecrets\":[{\"name\":\"$SECRET_NAME\"}]}}"

echo -e "${YELLOW}Waiting for pod to start...${NC}"
sleep 10
kubectl get pod test-acr-auth

echo -e "\n${YELLOW}===== INSTRUCTIONS FOR YOUR TEST SCRIPTS =====${NC}"
echo -e "For your connectivity test script, modify the kubectl run command like this:\n"
echo -e "${GREEN}kubectl run \$POD_NAME --image=\$TEST_POD_IMAGE --overrides='{\"spec\":{\"imagePullSecrets\":[{\"name\":\"$SECRET_NAME\"}]}}' > \"\${OUTPUT_DIR}/pod_create_\${aks_name}.log\" 2> \"\${OUTPUT_DIR}/pod_create_\${aks_name}.err\"${NC}"
echo -e "\nThis is the critical change needed to make your tests work."