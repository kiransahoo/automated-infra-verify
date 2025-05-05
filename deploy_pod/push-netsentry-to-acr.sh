#!/bin/bash
set -e

# Default parameters - customize these or they'll be auto-generated
LOCATION="eastus"
RESOURCE_GROUP="myAKSResourceGroup"  # Will be auto-generated if empty
ACR_NAME=""        # Will be auto-generated if empty
IMAGE_NAME="netsentry"  # Stylish name for a network tools image
IMAGE_TAG="latest"
AKS_CLUSTER_NAME="myAKSCluster" # Your AKS cluster name
SECRET_NAME="acr-auth" # Name of the Kubernetes secret for ACR authentication
TEST_POD_IMAGE="" # This will be set automatically later - leave empty

# Colors for better output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}===== Azure NetSentry Image Push Script =====${NC}"

# Install Azure CLI if not installed
if ! command -v az &> /dev/null; then
    echo -e "${YELLOW}Installing Azure CLI...${NC}"
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
fi

# Create temporary Dockerfile
echo -e "${YELLOW}Creating Dockerfile...${NC}"
cat > Dockerfile << 'EOF'
FROM ubuntu:22.04
# Install all necessary testing tools
RUN apt-get update && apt-get install -y \
    curl \
    iputils-ping \
    dnsutils \
    netcat-openbsd \
    traceroute \
    nmap \
    tcpdump \
    telnet \
    procps \
    && rm -rf /var/lib/apt/lists/*
# Set entrypoint to keep container running
ENTRYPOINT ["sleep", "3600"]
EOF

# Login to Azure
echo -e "${YELLOW}Logging in to Azure...${NC}"
az login --use-device-code

# Auto-generate resource group name if not provided
if [ -z "$RESOURCE_GROUP" ]; then
    RESOURCE_GROUP="netsentry-rg-$(date +%Y%m%d%H%M)"
    echo -e "${YELLOW}Auto-generated resource group name: ${GREEN}$RESOURCE_GROUP${NC}"
fi

# Check if resource group exists, create if it doesn't
if ! az group show --name "$RESOURCE_GROUP" &> /dev/null; then
    echo -e "${YELLOW}Creating resource group: ${GREEN}$RESOURCE_GROUP${NC}"
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION"
else
    echo -e "${YELLOW}Using existing resource group: ${GREEN}$RESOURCE_GROUP${NC}"
fi

# Auto-generate ACR name if not provided (must be globally unique and alphanumeric)
if [ -z "$ACR_NAME" ]; then
    # Generate a unique name with random suffix
    RANDOM_SUFFIX=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 5 | head -n 1)
    ACR_NAME="netsentry${RANDOM_SUFFIX}"
    echo -e "${YELLOW}Auto-generated ACR name: ${GREEN}$ACR_NAME${NC}"
fi

# Check if ACR exists, create if it doesn't
if ! az acr show --name "$ACR_NAME" &> /dev/null; then
    echo -e "${YELLOW}Creating Azure Container Registry: ${GREEN}$ACR_NAME${NC}"
    # Create Standard tier which has good performance/price balance
    az acr create --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --sku Standard --admin-enabled true
else
    echo -e "${YELLOW}Using existing Azure Container Registry: ${GREEN}$ACR_NAME${NC}"
fi

# Make ACR accessible (enable admin for simple access across resource groups)
echo -e "${YELLOW}Ensuring ACR is accessible across resource groups...${NC}"
az acr update --name "$ACR_NAME" --admin-enabled true

# Get ACR credentials
ACR_USERNAME=$(az acr credential show --name "$ACR_NAME" --query "username" -o tsv)
ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --query "passwords[0].value" -o tsv)

# Get ACR login server
ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv)
echo -e "${YELLOW}ACR Login Server: ${GREEN}$ACR_LOGIN_SERVER${NC}"

# Set the TEST_POD_IMAGE variable for use in the connectivity test script
TEST_POD_IMAGE="$ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG"
echo -e "${YELLOW}Image reference for tests: ${GREEN}$TEST_POD_IMAGE${NC}"

# Docker login with credentials
echo -e "${YELLOW}Logging in to Docker registry...${NC}"
echo "$ACR_PASSWORD" | docker login "$ACR_LOGIN_SERVER" --username "$ACR_USERNAME" --password-stdin

# Build the Docker image locally
echo -e "${YELLOW}Building Docker image...${NC}"
docker build -t "$IMAGE_NAME:$IMAGE_TAG" .

# Tag the image for ACR
echo -e "${YELLOW}Tagging image for ACR...${NC}"
docker tag "$IMAGE_NAME:$IMAGE_TAG" "$ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG"

# Push the image to ACR
echo -e "${YELLOW}Pushing image to ACR...${NC}"
docker push "$ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG"

# Clean up
echo -e "${YELLOW}Cleaning up local files...${NC}"
rm Dockerfile

# ===== ENHANCED AKS-ACR INTEGRATION SECTION =====
echo -e "${GREEN}===== Setting up AKS-ACR Integration =====${NC}"

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo -e "${YELLOW}Installing kubectl...${NC}"
    az aks install-cli
fi

# Check if we're connected to the cluster
echo -e "${YELLOW}Getting AKS credentials...${NC}"
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" --overwrite-existing

# Try primary approach: attach ACR to AKS (managed identity)
echo -e "${YELLOW}Trying to attach ACR to AKS using managed identity...${NC}"
if az aks update -n "$AKS_CLUSTER_NAME" -g "$RESOURCE_GROUP" --attach-acr "$ACR_NAME"; then
    echo -e "${GREEN}Successfully attached ACR to AKS using managed identity!${NC}"
    echo -e "You can now use ${GREEN}$ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG${NC} directly in your pod specs without secrets."
    echo -e "${YELLOW}However, we'll still create the secret as a fallback in case of issues...${NC}"
else
    echo -e "${YELLOW}Managed identity approach failed. Will use Kubernetes secret for authentication.${NC}"
fi

# ALWAYS create Kubernetes secret for ACR auth as a fallback
echo -e "${YELLOW}Creating/updating Kubernetes secret for ACR authentication...${NC}"
# First delete any existing secret to avoid conflicts
kubectl delete secret $SECRET_NAME --ignore-not-found=true --namespace=default

# Create secret in the default namespace
kubectl create secret docker-registry $SECRET_NAME \
  --docker-server="$ACR_LOGIN_SERVER" \
  --docker-username="$ACR_USERNAME" \
  --docker-password="$ACR_PASSWORD" \
  --docker-email="user@example.com" \
  --namespace=default

echo -e "${GREEN}Created Kubernetes secret '$SECRET_NAME' for ACR authentication in default namespace${NC}"

# Create the same secret in the kube-system namespace for system pods
kubectl delete secret $SECRET_NAME --ignore-not-found=true --namespace=kube-system
kubectl create secret docker-registry $SECRET_NAME \
  --docker-server="$ACR_LOGIN_SERVER" \
  --docker-username="$ACR_USERNAME" \
  --docker-password="$ACR_PASSWORD" \
  --docker-email="user@example.com" \
  --namespace=kube-system

echo -e "${GREEN}Created Kubernetes secret '$SECRET_NAME' for ACR authentication in kube-system namespace${NC}"

# Create a test pod to verify authentication
echo -e "${YELLOW}Creating test pod to verify authentication...${NC}"
# First remove any existing test pod
kubectl delete pod acr-auth-test --ignore-not-found=true --grace-period=0 --force

# Create the test pod with imagePullSecrets
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: acr-auth-test
  labels:
    app: acr-auth-test
spec:
  containers:
  - name: acr-auth-test
    image: $ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG
  imagePullSecrets:
  - name: $SECRET_NAME
  restartPolicy: Never
EOF

echo -e "${YELLOW}Waiting for pod to start (20 seconds timeout)...${NC}"
for i in {1..20}; do
    PHASE=$(kubectl get pod acr-auth-test -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    if [[ "$PHASE" == "Running" ]]; then
        echo -e "${GREEN}Pod is running successfully! Image pull succeeded.${NC}"
        break
    elif [[ "$PHASE" == "Failed" ]]; then
        echo -e "${RED}Pod failed to start.${NC}"
        break
    fi
    
    # Check for ImagePullBackOff
    REASON=$(kubectl get pod acr-auth-test -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
    if [[ "$REASON" == "ImagePullBackOff" || "$REASON" == "ErrImagePull" ]]; then
        echo -e "${RED}Image pull failed. Checking details...${NC}"
        kubectl describe pod acr-auth-test
        break
    fi
    
    echo -n "."
    sleep 1
done

echo -e "\n${YELLOW}Final status of test pod:${NC}"
kubectl get pod acr-auth-test

echo -e "${GREEN}===== Setup Complete =====${NC}"
echo -e "Image: ${GREEN}$ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG${NC}"
echo -e "Registry: ${GREEN}$ACR_NAME${NC}"
echo -e "Resource Group: ${GREEN}$RESOURCE_GROUP${NC}"
echo -e "Secret Name: ${GREEN}$SECRET_NAME${NC}"

# Create a helper script for updating the connectivity test script
echo -e "${YELLOW}Creating helper script to modify your connectivity test script...${NC}"
cat > update-connectivity-test.sh << EOF
#!/bin/bash
# Helper script to modify the test_aks_to_storage_connectivity function

# Create a backup of the original file
cp tests.sh tests.sh.bak

# Update the kubectl run command to include imagePullSecrets
sed -i 's/kubectl run \$POD_NAME --image=\$TEST_POD_IMAGE/kubectl run \$POD_NAME --image=\$TEST_POD_IMAGE --overrides='"'"'{"spec":{"imagePullSecrets":[{"name":"$SECRET_NAME"}]}}'"'"'/g' tests.sh

# Add TEST_POD_IMAGE definition at the top of the file if not present
if ! grep -q "TEST_POD_IMAGE=" tests.sh; then
    sed -i '1s/^/# Image to use for test pods\nTEST_POD_IMAGE="$ACR_LOGIN_SERVER\/$IMAGE_NAME:$IMAGE_TAG"\n\n/' tests.sh
fi

echo "Updated tests.sh with imagePullSecrets. Original saved as tests.sh.bak"
EOF

chmod +x update-connectivity-test.sh
echo -e "${GREEN}Created helper script: ${YELLOW}update-connectivity-test.sh${NC}"
echo -e "Run it to automatically update your connectivity test script\n"

echo -e "${YELLOW}IMPORTANT: For your connectivity tests, use this kubectl command format:${NC}"
echo -e "${GREEN}kubectl run \$POD_NAME --image=\$TEST_POD_IMAGE --overrides='{\"spec\":{\"imagePullSecrets\":[{\"name\":\"$SECRET_NAME\"}]}}'${NC}"

echo -e "\n${YELLOW}To manually add this to your existing pod creation code, add the following section:${NC}"
cat << EOF
When creating your test pod:
1. Make sure TEST_POD_IMAGE is set to "$ACR_LOGIN_SERVER/$IMAGE_NAME:$IMAGE_TAG"
2. Change the kubectl run line to:
   kubectl run \$POD_NAME --image=\$TEST_POD_IMAGE \\
     --overrides='{"spec":{"imagePullSecrets":[{"name":"$SECRET_NAME"}]}}' \\
     > "\${OUTPUT_DIR}/pod_create_\${aks_name}.log" 2> "\${OUTPUT_DIR}/pod_create_\${aks_name}.err"
EOF

echo -e "\n${GREEN}All setup complete. You should now be able to use the image in your connectivity tests.${NC}"