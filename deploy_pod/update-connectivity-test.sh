#!/bin/bash
# Helper script to modify the test_aks_to_storage_connectivity function

# Create a backup of the original file
cp tests.sh tests.sh.bak

# Update the kubectl run command to include imagePullSecrets
sed -i 's/kubectl run $POD_NAME --image=$TEST_POD_IMAGE/kubectl run $POD_NAME --image=$TEST_POD_IMAGE --overrides='"'"'{"spec":{"imagePullSecrets":[{"name":"acr-auth"}]}}'"'"'/g' tests.sh

# Add TEST_POD_IMAGE definition at the top of the file if not present
if ! grep -q "TEST_POD_IMAGE=" tests.sh; then
    sed -i '1s/^/# Image to use for test pods\nTEST_POD_IMAGE="netsentry.azurecr.io\/netsentry:latest"\n\n/' tests.sh
fi

echo "Updated tests.sh with imagePullSecrets. Original saved as tests.sh.bak"
