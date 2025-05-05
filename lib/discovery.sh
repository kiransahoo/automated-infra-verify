#!/bin/bash

# Function to discover subscriptions
discover_subscriptions() {
    log "Discovering Azure subscriptions (with ${DISCOVERY_TIMEOUT}-second timeout)..."
    
    # Ensure output directory exists with proper permissions
    mkdir -p "$OUTPUT_DIR"
    chmod 755 "$OUTPUT_DIR" 2>/dev/null || true
    
    if [ -n "$SUBSCRIPTION_ID" ]; then
        log "Using specified subscription: $SUBSCRIPTION_ID"
        # Create a simple JSON array with the specified subscription
        echo "[{\"id\":\"$SUBSCRIPTION_ID\",\"name\":\"Specified Subscription\"}]" > "${OUTPUT_DIR}/subscriptions.json"
        echo "$SUBSCRIPTION_ID" > "${OUTPUT_DIR}/subscriptions.txt"
    else
        log "Discovering all accessible subscriptions..."
        # Use configurable timeout for az command with explicit error handling
        if run_az_command "az account list --query \"[?state=='Enabled'].{id:id,name:name}\" -o json" "${OUTPUT_DIR}/subscriptions.json" "${OUTPUT_DIR}/subscription_error.log" "$DISCOVERY_TIMEOUT" "Subscription discovery"; then
            log_debug "Successfully retrieved subscription list"
        else
            log_warning "Subscription discovery had issues. Checking if we got partial results."
            
            # Ensure the file exists with valid JSON
            if [ ! -f "${OUTPUT_DIR}/subscriptions.json" ]; then
                echo "[]" > "${OUTPUT_DIR}/subscriptions.json"
            elif [ ! -s "${OUTPUT_DIR}/subscriptions.json" ]; then
                echo "[]" > "${OUTPUT_DIR}/subscriptions.json"
            fi
        fi
        
        # Validate JSON before extracting data
        if [ "$JQ_AVAILABLE" = true ]; then
            if jq empty "${OUTPUT_DIR}/subscriptions.json" 2>/dev/null; then
                log "Valid JSON in subscriptions.json"
            else
                log_warning "Invalid JSON in subscriptions.json, resetting to empty array"
                echo "[]" > "${OUTPUT_DIR}/subscriptions.json"
            fi
            
            # Extract subscription IDs to text file using jq
            if [ -s "${OUTPUT_DIR}/subscriptions.json" ]; then
                if ! jq -r '.[].id' "${OUTPUT_DIR}/subscriptions.json" > "${OUTPUT_DIR}/subscriptions.txt" 2>"${OUTPUT_DIR}/jq_error.log"; then
                    log_warning "Error extracting subscription IDs with jq: $(cat "${OUTPUT_DIR}/jq_error.log")"
                    # Fall back to az CLI direct output
                    run_az_command "az account list --query \"[?state=='Enabled'].id\" -o tsv" "${OUTPUT_DIR}/subscriptions.txt" "${OUTPUT_DIR}/subscription_tsv_error.log" "$DISCOVERY_TIMEOUT" "Getting subscription IDs in TSV format"
                fi
            else
                # Create empty files to avoid errors
                echo "[]" > "${OUTPUT_DIR}/subscriptions.json"
                touch "${OUTPUT_DIR}/subscriptions.txt"
                log_error "No accessible subscriptions found or empty response received."
            fi
        else
            # Fallback method if jq is not available - use az CLI with TSV output
            log "Using fallback method to extract subscription IDs (jq not available)"
            run_az_command "az account list --query \"[?state=='Enabled'].id\" -o tsv" "${OUTPUT_DIR}/subscriptions.txt" "${OUTPUT_DIR}/subscription_tsv_error.log" "$DISCOVERY_TIMEOUT" "Getting subscription IDs in TSV format"
            
            # Also create a minimal subscriptions.json for later reference
            echo "[" > "${OUTPUT_DIR}/subscriptions.json"
            while IFS= read -r sub_id || [ -n "$sub_id" ]; do
                [ -z "$sub_id" ] && continue
                sub_name=""
                run_az_command "az account show --subscription \"$sub_id\" --query \"name\" -o tsv" "${OUTPUT_DIR}/sub_name_${sub_id}.txt" "${OUTPUT_DIR}/sub_name_${sub_id}.err" "$DISCOVERY_TIMEOUT" "Getting name for subscription $sub_id"
                sub_name=$(cat "${OUTPUT_DIR}/sub_name_${sub_id}.txt" 2>/dev/null || echo "Subscription $sub_id")
                echo "{\"id\":\"$sub_id\",\"name\":\"$sub_name\"}," >> "${OUTPUT_DIR}/subscriptions.json"
            done < "${OUTPUT_DIR}/subscriptions.txt"
            # Fix the trailing comma and close the JSON array
            sed -i 's/,$//' "${OUTPUT_DIR}/subscriptions.json" 2>/dev/null || sed -i '' 's/,$//' "${OUTPUT_DIR}/subscriptions.json" 2>/dev/null
            echo "]" >> "${OUTPUT_DIR}/subscriptions.json"
        fi
        
        if [ ! -s "${OUTPUT_DIR}/subscriptions.txt" ]; then
            log_error "No accessible subscriptions found."
        else
            sub_count=$(wc -l < "${OUTPUT_DIR}/subscriptions.txt" | tr -d ' ')
            log_success "Discovered $sub_count accessible subscriptions."
        fi
    fi
    
    # Create inaccessible subscriptions file (will be populated if needed)
    touch "${OUTPUT_DIR}/inaccessible_subscriptions.txt"
}

# Function to discover resource groups
discover_resource_groups() {
    log "Discovering resource groups (with ${DISCOVERY_TIMEOUT}-second timeout)..."
    
    # Create empty files
    > "${OUTPUT_DIR}/resource_groups.txt"
    > "${OUTPUT_DIR}/inaccessible_resource_groups.txt"
    
    # Ensure subscriptions.txt exists and is readable
    if [ ! -f "${OUTPUT_DIR}/subscriptions.txt" ]; then
        touch "${OUTPUT_DIR}/subscriptions.txt"
        log_warning "subscriptions.txt not found, creating empty file"
    fi
    
    if [ ! -s "${OUTPUT_DIR}/subscriptions.txt" ]; then
        log_warning "subscriptions.txt is empty, no subscriptions to process"
        return
    fi
    
    log "Processing $(wc -l < "${OUTPUT_DIR}/subscriptions.txt" | tr -d ' ') subscriptions from subscriptions.txt"
    
    while IFS= read -r sub || [ -n "$sub" ]; do
        # Skip empty lines and trim whitespace
        sub=$(echo "$sub" | tr -d ' \t\r\n')
        [ -z "$sub" ] && continue
        
        log "Processing subscription: $sub"
        
        # Set subscription context with explicit error handling
        run_az_command "az account set --subscription \"$sub\"" "${OUTPUT_DIR}/account_set_${sub}.log" "${OUTPUT_DIR}/account_set_${sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for $sub"
        
        if [ ! -s "${OUTPUT_DIR}/account_set_${sub}.log" ] && [ -s "${OUTPUT_DIR}/account_set_${sub}.err" ]; then
            log_warning "Failed to set subscription context for $sub ($(cat "${OUTPUT_DIR}/account_set_${sub}.err")), skipping"
            continue
        fi
        
        # Get subscription name with fallbacks
        sub_name=""
        
        # Method 1: Try to get from subscriptions.json using jq if available
        if [ "$JQ_AVAILABLE" = true ] && [ -f "${OUTPUT_DIR}/subscriptions.json" ]; then
            sub_name=$(jq -r --arg id "$sub" '.[] | select(.id == $id) | .name' "${OUTPUT_DIR}/subscriptions.json" 2>/dev/null)
        fi
        
        # Method 2: Fallback to direct Azure CLI query if needed
        if [ -z "$sub_name" ]; then
            run_az_command "az account show --subscription \"$sub\" --query \"name\" -o tsv" "${OUTPUT_DIR}/sub_name_query_${sub}.txt" "${OUTPUT_DIR}/sub_name_query_${sub}.err" "$DISCOVERY_TIMEOUT" "Getting name for subscription $sub"
            sub_name=$(cat "${OUTPUT_DIR}/sub_name_query_${sub}.txt" 2>/dev/null)
        fi
        
        # Method 3: Last resort - use subscription ID as name
        if [ -z "$sub_name" ]; then
            sub_name="Subscription $sub"
        fi
        
        log "Subscription name resolved as: $sub_name"
        
        if [ -n "$RESOURCE_GROUP" ]; then
            # Test specific resource group
            log "Testing specific resource group: $RESOURCE_GROUP"
            if run_az_command "az group show --name \"$RESOURCE_GROUP\"" "${OUTPUT_DIR}/rg_show_${sub}_${RESOURCE_GROUP}.json" "${OUTPUT_DIR}/rg_show_${sub}_${RESOURCE_GROUP}.err" "$DISCOVERY_TIMEOUT" "Checking resource group $RESOURCE_GROUP in subscription $sub"; then
                echo "${sub}|${RESOURCE_GROUP}|${sub_name}" >> "${OUTPUT_DIR}/resource_groups.txt"
                log "Resource group '$RESOURCE_GROUP' found in subscription $sub_name"
            else
                echo "${sub}|${RESOURCE_GROUP}|${sub_name}" >> "${OUTPUT_DIR}/inaccessible_resource_groups.txt"
                log_warning "Resource group '$RESOURCE_GROUP' not found or inaccessible in subscription $sub_name ($sub)"
            fi
        else
            # Get all resource groups with fallback methods
            log "Retrieving all resource groups for subscription $sub"
            
            # Try multiple output formats to ensure we get data
            # Method 1: TSV format (most reliable for parsing)
            run_az_command "az group list --query \"[].name\" -o tsv" "${OUTPUT_DIR}/rg_list_${sub}.txt" "${OUTPUT_DIR}/rg_error_${sub}.log" "$DISCOVERY_TIMEOUT" "Listing resource groups in subscription $sub (TSV)"
            
            if [ -s "${OUTPUT_DIR}/rg_list_${sub}.txt" ]; then
                rg_count=$(wc -l < "${OUTPUT_DIR}/rg_list_${sub}.txt" | tr -d ' ')
                log "Found $rg_count resource groups in subscription $sub using TSV format"
            else
                log_warning "No resource groups found in TSV output for subscription $sub_name ($sub)"
                
                # Method 2: Try JSON format as fallback
                run_az_command "az group list -o json" "${OUTPUT_DIR}/rg_list_${sub}.json" "${OUTPUT_DIR}/rg_json_error_${sub}.log" "$DISCOVERY_TIMEOUT" "Listing resource groups in subscription $sub (JSON)"
                
                if [ -s "${OUTPUT_DIR}/rg_list_${sub}.json" ]; then
                    if [ "$JQ_AVAILABLE" = true ]; then
                        # Extract names using jq
                        jq -r '.[].name' "${OUTPUT_DIR}/rg_list_${sub}.json" > "${OUTPUT_DIR}/rg_list_${sub}.txt" 2>/dev/null
                        log_debug "Extracted resource group names using jq"
                    else
                        # Fallback manual parsing using grep/sed if jq not available
                        grep -o '"name": *"[^"]*"' "${OUTPUT_DIR}/rg_list_${sub}.json" | sed 's/"name": *"\(.*\)"/\1/' > "${OUTPUT_DIR}/rg_list_${sub}.txt" 2>/dev/null
                        log_debug "Extracted resource group names using grep/sed"
                    fi
                    
                    if [ -s "${OUTPUT_DIR}/rg_list_${sub}.txt" ]; then
                        rg_count=$(wc -l < "${OUTPUT_DIR}/rg_list_${sub}.txt" | tr -d ' ')
                        log "Found $rg_count resource groups in subscription $sub using JSON parsing fallback"
                    else
                        log_warning "Failed to extract resource group names from JSON for subscription $sub"
                        
                        # Method 3: Try alternative query format
                        run_az_command "az group list --query \"[].[name]\" -o tsv" "${OUTPUT_DIR}/rg_list_alt_${sub}.txt" "${OUTPUT_DIR}/rg_alt_error_${sub}.log" "$DISCOVERY_TIMEOUT" "Listing resource groups in subscription $sub (alternative format)"
                        
                        if [ -s "${OUTPUT_DIR}/rg_list_alt_${sub}.txt" ]; then
                            cp "${OUTPUT_DIR}/rg_list_alt_${sub}.txt" "${OUTPUT_DIR}/rg_list_${sub}.txt"
                            rg_count=$(wc -l < "${OUTPUT_DIR}/rg_list_${sub}.txt" | tr -d ' ')
                            log "Found $rg_count resource groups in subscription $sub using alternative query format"
                        else
                            # Method 4: Try to extract resource groups from resource list (last resort)
                            log "Trying to extract resource groups from resource list..."
                            run_az_command "az resource list --subscription \"$sub\" --query \"[].resourceGroup\" -o tsv" "${OUTPUT_DIR}/rg_from_res_${sub}.txt" "${OUTPUT_DIR}/rg_from_res_${sub}.err" "$((DISCOVERY_TIMEOUT*2))" "Extracting resource groups from resource list"
                            
                            if [ -s "${OUTPUT_DIR}/rg_from_res_${sub}.txt" ]; then
                                # Sort and get unique resource group names
                                sort -u "${OUTPUT_DIR}/rg_from_res_${sub}.txt" > "${OUTPUT_DIR}/rg_list_${sub}.txt"
                                rg_count=$(wc -l < "${OUTPUT_DIR}/rg_list_${sub}.txt" | tr -d ' ')
                                log "Found $rg_count resource groups from resource list in subscription $sub"
                            else
                                log_warning "No resource groups found in subscription $sub_name ($sub) after all attempts"
                                echo "${sub}||${sub_name}" >> "${OUTPUT_DIR}/inaccessible_resource_groups.txt"
                            fi
                        fi
                    fi
                else
                    log_warning "Empty JSON response for resource groups in subscription $sub"
                    # Try one more fallback - list resources and extract groups
                    run_az_command "az resource list --subscription \"$sub\" --query \"[].resourceGroup\" -o tsv" "${OUTPUT_DIR}/rg_from_res_${sub}.txt" "${OUTPUT_DIR}/rg_from_res_${sub}.err" "$((DISCOVERY_TIMEOUT*2))" "Extracting resource groups from resource list"
                    
                    if [ -s "${OUTPUT_DIR}/rg_from_res_${sub}.txt" ]; then
                        # Sort and get unique resource group names
                        sort -u "${OUTPUT_DIR}/rg_from_res_${sub}.txt" > "${OUTPUT_DIR}/rg_list_${sub}.txt"
                        rg_count=$(wc -l < "${OUTPUT_DIR}/rg_list_${sub}.txt" | tr -d ' ')
                        log "Found $rg_count resource groups from resource list in subscription $sub"
                    else
                        log_warning "No resource groups found in subscription $sub_name ($sub) after all attempts"
                        echo "${sub}||${sub_name}" >> "${OUTPUT_DIR}/inaccessible_resource_groups.txt"
                    fi
                fi
            fi
            
            # Process resource groups found by any method
            if [ -s "${OUTPUT_DIR}/rg_list_${sub}.txt" ]; then
                while IFS= read -r rg || [ -n "$rg" ]; do
                    # Skip empty lines and trim whitespace
                    rg=$(echo "$rg" | tr -d ' \t\r\n')
                    [ -z "$rg" ] && continue
                    
                    echo "${sub}|${rg}|${sub_name}" >> "${OUTPUT_DIR}/resource_groups.txt"
                    log "Added resource group: $rg"
                done < "${OUTPUT_DIR}/rg_list_${sub}.txt"
            fi
        fi
    done < "${OUTPUT_DIR}/subscriptions.txt"
    
    # Check results
    if [ -f "${OUTPUT_DIR}/resource_groups.txt" ]; then
        if [ ! -s "${OUTPUT_DIR}/resource_groups.txt" ]; then
            log_warning "No accessible resource groups found."
        else
            rg_count=$(wc -l < "${OUTPUT_DIR}/resource_groups.txt" | tr -d ' ')
            log_success "Discovered $rg_count accessible resource groups."
        fi
    else
        log_warning "Resource groups file not created."
        touch "${OUTPUT_DIR}/resource_groups.txt"
    fi
}

# Function to discover virtual machines with debug output
discover_vms() {
    if [[ "$TEST_VMS" != "true" ]]; then
        log "Skipping VM discovery as requested"
        > "${OUTPUT_DIR}/vms.txt"
        return
    fi
    
    log "Discovering virtual machines..."
    
    > "${OUTPUT_DIR}/vms.txt"
    
    if [ ! -s "${OUTPUT_DIR}/resource_groups.txt" ]; then
        log_warning "No resource groups found, skipping VM discovery."
        return
    fi
    
    while IFS='|' read -r sub rg other || [ -n "$sub" ]; do
        # Skip empty lines or lines with empty fields
        [ -z "$sub" ] || [ -z "$rg" ] && continue
        
        # Set subscription context
        run_az_command "az account set --subscription \"$sub\"" "${OUTPUT_DIR}/vm_account_set_${sub}.log" "${OUTPUT_DIR}/vm_account_set_${sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for VM discovery ($sub)"
        
        if [ ! -s "${OUTPUT_DIR}/vm_account_set_${sub}.log" ] && [ -s "${OUTPUT_DIR}/vm_account_set_${sub}.err" ]; then
            log_warning "Failed to set subscription context for $sub, skipping VM discovery"
            continue
        fi
        
        # Get VMs in resource group
        run_az_command "az vm list --resource-group \"$rg\" --query \"[].{name:name, id:id, privateIps:privateIps, publicIps:publicIps, vnet:virtualNetwork.name, subnet:subnet.name, osType:storageProfile.osDisk.osType}\" -o json" "${OUTPUT_DIR}/vm_list_${sub}_${rg}.json" "${OUTPUT_DIR}/vm_list_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Listing VMs in resource group $rg"
        
        if [ -s "${OUTPUT_DIR}/vm_list_${sub}_${rg}.json" ]; then
            # Process each VM
            if [ "$JQ_AVAILABLE" = true ]; then
                # Parse with jq
                jq -c '.[]' "${OUTPUT_DIR}/vm_list_${sub}_${rg}.json" 2>/dev/null | while read -r vm_json; do
                    vm_name=$(echo "$vm_json" | jq -r '.name')
                    vm_id=$(echo "$vm_json" | jq -r '.id')
                    private_ips=$(echo "$vm_json" | jq -r '.privateIps // "unknown"')
                    public_ips=$(echo "$vm_json" | jq -r '.publicIps // "none"')
                    vnet=$(echo "$vm_json" | jq -r '.vnet // "unknown"')
                    subnet=$(echo "$vm_json" | jq -r '.subnet // "unknown"')
                    os_type=$(echo "$vm_json" | jq -r '.osType // "unknown"')
                    
                    # Get proper network interface info if not available in initial query
                    if [ "$private_ips" = "unknown" ] || [ "$vnet" = "unknown" ] || [ "$subnet" = "unknown" ]; then
                        # Get network interface information
                        run_az_command "az vm show --resource-group \"$rg\" --name \"$vm_name\" --query \"networkProfile.networkInterfaces[0].id\" -o tsv" "${OUTPUT_DIR}/vm_nic_${sub}_${rg}_${vm_name}.txt" "${OUTPUT_DIR}/vm_nic_${sub}_${rg}_${vm_name}.err" "$DISCOVERY_TIMEOUT" "Getting network interface for VM $vm_name"
                        
                        nic_info=$(cat "${OUTPUT_DIR}/vm_nic_${sub}_${rg}_${vm_name}.txt" 2>/dev/null)
                        if [ -n "$nic_info" ]; then
                            nic_name=$(echo "$nic_info" | awk -F/ '{print $NF}')
                            
                            run_az_command "az network nic show --ids \"$nic_info\" -o json" "${OUTPUT_DIR}/nic_details_${sub}_${rg}_${vm_name}.json" "${OUTPUT_DIR}/nic_details_${sub}_${rg}_${vm_name}.err" "$DISCOVERY_TIMEOUT" "Getting NIC details for VM $vm_name"
                            
                            nic_details_file="${OUTPUT_DIR}/nic_details_${sub}_${rg}_${vm_name}.json"
                            if [ -s "$nic_details_file" ]; then
                                if [ "$JQ_AVAILABLE" = true ]; then
                                    private_ips=$(jq -r '.ipConfigurations[0].privateIpAddress' "$nic_details_file" 2>/dev/null)
                                    vnet=$(jq -r '.ipConfigurations[0].subnet.id' "$nic_details_file" 2>/dev/null | awk -F/ '{print $(NF-2)}')
                                    subnet=$(jq -r '.ipConfigurations[0].subnet.id' "$nic_details_file" 2>/dev/null | awk -F/ '{print $NF}')
                                    
                                    # Get public IP
                                    public_ip_id=$(jq -r '.ipConfigurations[0].publicIpAddress.id' "$nic_details_file" 2>/dev/null)
                                    if [ -n "$public_ip_id" ] && [ "$public_ip_id" != "null" ]; then
                                        run_az_command "az network public-ip show --ids \"$public_ip_id\" --query \"ipAddress\" -o tsv" "${OUTPUT_DIR}/pubip_${sub}_${rg}_${vm_name}.txt" "${OUTPUT_DIR}/pubip_${sub}_${rg}_${vm_name}.err" "$DISCOVERY_TIMEOUT" "Getting public IP for VM $vm_name"
                                        public_ips=$(cat "${OUTPUT_DIR}/pubip_${sub}_${rg}_${vm_name}.txt" 2>/dev/null || echo "none")
                                    fi
                                fi
                            fi
                        fi
                    fi
                    
                    # Add VM to the list
                    echo "${sub}|${rg}|${vm_name}|${vm_id}|${private_ips}|${public_ips}|${vnet}|${subnet}|${os_type}" >> "${OUTPUT_DIR}/vms.txt"
                    log "Found VM: $vm_name in resource group $rg"
                done
            else
                # Fallback parsing without jq
                # Extract VMs using grep and process them line by line
                log_debug "Using fallback method to extract VM details without jq"
                
                # Get VM names directly with TSV output
                run_az_command "az vm list --resource-group \"$rg\" --query \"[].name\" -o tsv" "${OUTPUT_DIR}/vm_names_${sub}_${rg}.txt" "${OUTPUT_DIR}/vm_names_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Getting VM names in resource group $rg"
                
                if [ -s "${OUTPUT_DIR}/vm_names_${sub}_${rg}.txt" ]; then
                    while IFS= read -r vm_name || [ -n "$vm_name" ]; do
                        # Skip empty lines
                        [ -z "$vm_name" ] && continue
                        
                        # Get detailed VM info
                        run_az_command "az vm show -g \"$rg\" -n \"$vm_name\" -o json" "${OUTPUT_DIR}/vm_details_${sub}_${rg}_${vm_name}.json" "${OUTPUT_DIR}/vm_details_${sub}_${rg}_${vm_name}.err" "$DISCOVERY_TIMEOUT" "Getting VM details for $vm_name"
                        
                        vm_details_file="${OUTPUT_DIR}/vm_details_${sub}_${rg}_${vm_name}.json"
                        if [ -s "$vm_details_file" ]; then
                            # Extract basic info
                            vm_id=$(grep -o '"id": *"[^"]*"' "$vm_details_file" | head -1 | sed 's/"id": *"\(.*\)"/\1/')
                            os_type=$(grep -o '"osType": *"[^"]*"' "$vm_details_file" | sed 's/"osType": *"\(.*\)"/\1/')
                            
                            # Get network interface
                            run_az_command "az vm show -g \"$rg\" -n \"$vm_name\" --query \"networkProfile.networkInterfaces[0].id\" -o tsv" "${OUTPUT_DIR}/vm_nic_${sub}_${rg}_${vm_name}.txt" "${OUTPUT_DIR}/vm_nic_${sub}_${rg}_${vm_name}.err" "$DISCOVERY_TIMEOUT" "Getting network interface for VM $vm_name"
                            
                            nic_id=$(cat "${OUTPUT_DIR}/vm_nic_${sub}_${rg}_${vm_name}.txt" 2>/dev/null)
                            
                            private_ips="unknown"
                            public_ips="none"
                            vnet="unknown"
                            subnet="unknown"
                            
                            if [ -n "$nic_id" ]; then
                                run_az_command "az network nic show --ids \"$nic_id\" -o json" "${OUTPUT_DIR}/nic_details_${sub}_${rg}_${vm_name}.json" "${OUTPUT_DIR}/nic_details_${sub}_${rg}_${vm_name}.err" "$DISCOVERY_TIMEOUT" "Getting NIC details for VM $vm_name"
                                
                                nic_details_file="${OUTPUT_DIR}/nic_details_${sub}_${rg}_${vm_name}.json"
                                if [ -s "$nic_details_file" ]; then
                                    # Extract IP info
                                    private_ips=$(grep -o '"privateIpAddress": *"[^"]*"' "$nic_details_file" | head -1 | sed 's/"privateIpAddress": *"\(.*\)"/\1/')
                                    
                                    # Extract subnet ID and parse for vnet/subnet names
                                    subnet_id=$(grep -o '"subnet": *{[^}]*}' "$nic_details_file" | grep -o '"id": *"[^"]*"' | sed 's/"id": *"\(.*\)"/\1/')
                                    if [ -n "$subnet_id" ]; then
                                        vnet=$(echo "$subnet_id" | awk -F/ '{print $(NF-2)}')
                                        subnet=$(echo "$subnet_id" | awk -F/ '{print $NF}')
                                    fi
                                    
                                    # Check for public IP
                                    if grep -q '"publicIpAddress": *{' "$nic_details_file"; then
                                        public_ip_id=$(grep -o '"publicIpAddress": *{[^}]*}' "$nic_details_file" | grep -o '"id": *"[^"]*"' | sed 's/"id": *"\(.*\)"/\1/')
                                        if [ -n "$public_ip_id" ]; then
                                            run_az_command "az network public-ip show --ids \"$public_ip_id\" --query \"ipAddress\" -o tsv" "${OUTPUT_DIR}/pubip_${sub}_${rg}_${vm_name}.txt" "${OUTPUT_DIR}/pubip_${sub}_${rg}_${vm_name}.err" "$DISCOVERY_TIMEOUT" "Getting public IP for VM $vm_name"
                                            public_ips=$(cat "${OUTPUT_DIR}/pubip_${sub}_${rg}_${vm_name}.txt" 2>/dev/null || echo "none")
                                        fi
                                    fi
                                fi
                            fi
                            
                            # Add VM to the list
                            echo "${sub}|${rg}|${vm_name}|${vm_id}|${private_ips}|${public_ips}|${vnet}|${subnet}|${os_type}" >> "${OUTPUT_DIR}/vms.txt"
                            log "Found VM: $vm_name in resource group $rg"
                        fi
                    done < "${OUTPUT_DIR}/vm_names_${sub}_${rg}.txt"
                fi
            fi
        else
            log_warning "No VMs found in resource group $rg or empty response"
        fi
    done < "${OUTPUT_DIR}/resource_groups.txt"
    
    # Count discovered VMs
    if [ -s "${OUTPUT_DIR}/vms.txt" ]; then
        vm_count=$(wc -l < "${OUTPUT_DIR}/vms.txt" | tr -d ' ')
        log_success "Discovered $vm_count virtual machines."
    else
        log_warning "No virtual machines found."
    fi
}

# Function to discover AKS clusters with debug output
discover_aks() {
    if [[ "$TEST_AKS" != "true" ]]; then
        log "Skipping AKS discovery as requested"
        > "${OUTPUT_DIR}/aks_clusters.txt"
        return
    fi
    
    log "Discovering AKS clusters..."
    
    > "${OUTPUT_DIR}/aks_clusters.txt"
    
    if [ ! -s "${OUTPUT_DIR}/resource_groups.txt" ]; then
        log_warning "No resource groups found, skipping AKS discovery."
        return
    fi
    
    while IFS='|' read -r sub rg other || [ -n "$sub" ]; do
        # Skip empty lines or lines with empty fields
        [ -z "$sub" ] || [ -z "$rg" ] && continue
        
        # Set subscription context
        run_az_command "az account set --subscription \"$sub\"" "${OUTPUT_DIR}/aks_account_set_${sub}.log" "${OUTPUT_DIR}/aks_account_set_${sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for AKS discovery ($sub)"
        
        if [ ! -s "${OUTPUT_DIR}/aks_account_set_${sub}.log" ] && [ -s "${OUTPUT_DIR}/aks_account_set_${sub}.err" ]; then
            log_warning "Failed to set subscription context for $sub, skipping AKS discovery"
            continue
        fi
        
        # Get AKS clusters in resource group
        run_az_command "az aks list --resource-group \"$rg\" --query \"[].{name:name, nodeResourceGroup:nodeResourceGroup, fqdn:fqdn, apiServerAddress:apiServerAddress, networkPlugin:networkProfile.networkPlugin}\" -o json" "${OUTPUT_DIR}/aks_list_${sub}_${rg}.json" "${OUTPUT_DIR}/aks_list_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Listing AKS clusters in resource group $rg"
        
        if [ -s "${OUTPUT_DIR}/aks_list_${sub}_${rg}.json" ]; then
            # Process each AKS cluster
            if [ "$JQ_AVAILABLE" = true ]; then
                # Parse with jq
                jq -c '.[]' "${OUTPUT_DIR}/aks_list_${sub}_${rg}.json" 2>/dev/null | while read -r aks_json; do
                    aks_name=$(echo "$aks_json" | jq -r '.name')
                    node_rg=$(echo "$aks_json" | jq -r '.nodeResourceGroup // "unknown"')
                    fqdn=$(echo "$aks_json" | jq -r '.fqdn // "unknown"')
                    api_server=$(echo "$aks_json" | jq -r '.apiServerAddress // "unknown"')
                    network_plugin=$(echo "$aks_json" | jq -r '.networkPlugin // "unknown"')
                    
                    # Add AKS cluster to the list
                    echo "${sub}|${rg}|${aks_name}|${node_rg}|${fqdn}|${api_server}|${network_plugin}" >> "${OUTPUT_DIR}/aks_clusters.txt"
                    log "Found AKS cluster: $aks_name in resource group $rg"
                done
            else
                # Fallback parsing without jq - use direct CLI commands
                run_az_command "az aks list --resource-group \"$rg\" --query \"[].name\" -o tsv" "${OUTPUT_DIR}/aks_names_${sub}_${rg}.txt" "${OUTPUT_DIR}/aks_names_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Getting AKS cluster names in resource group $rg"
                
                if [ -s "${OUTPUT_DIR}/aks_names_${sub}_${rg}.txt" ]; then
                    while IFS= read -r aks_name || [ -n "$aks_name" ]; do
                        # Skip empty lines
                        [ -z "$aks_name" ] && continue
                        
                        # Get details for each cluster
                        run_az_command "az aks show -g \"$rg\" -n \"$aks_name\" --query \"{nodeResourceGroup:nodeResourceGroup, fqdn:fqdn, apiServerAddress:apiServerAddress, networkPlugin:networkProfile.networkPlugin}\" -o json" "${OUTPUT_DIR}/aks_details_${sub}_${rg}_${aks_name}.json" "${OUTPUT_DIR}/aks_details_${sub}_${rg}_${aks_name}.err" "$DISCOVERY_TIMEOUT" "Getting details for AKS cluster $aks_name"
                        
                        aks_details_file="${OUTPUT_DIR}/aks_details_${sub}_${rg}_${aks_name}.json"
                        if [ -s "$aks_details_file" ]; then
                            # Extract cluster details
                            node_rg=$(grep -o '"nodeResourceGroup": *"[^"]*"' "$aks_details_file" | sed 's/"nodeResourceGroup": *"\(.*\)"/\1/' || echo "unknown")
                            fqdn=$(grep -o '"fqdn": *"[^"]*"' "$aks_details_file" | sed 's/"fqdn": *"\(.*\)"/\1/' || echo "unknown")
                            api_server=$(grep -o '"apiServerAddress": *"[^"]*"' "$aks_details_file" | sed 's/"apiServerAddress": *"\(.*\)"/\1/' || echo "unknown")
                            network_plugin=$(grep -o '"networkPlugin": *"[^"]*"' "$aks_details_file" | sed 's/"networkPlugin": *"\(.*\)"/\1/' || echo "unknown")
                            
                            # Add AKS cluster to the list
                            echo "${sub}|${rg}|${aks_name}|${node_rg}|${fqdn}|${api_server}|${network_plugin}" >> "${OUTPUT_DIR}/aks_clusters.txt"
                            log "Found AKS cluster: $aks_name in resource group $rg"
                        fi
                    done < "${OUTPUT_DIR}/aks_names_${sub}_${rg}.txt"
                fi
            fi
        else
            log_warning "No AKS clusters found in resource group $rg or empty response"
        fi
    done < "${OUTPUT_DIR}/resource_groups.txt"
    
    # Count discovered AKS clusters
    if [ -s "${OUTPUT_DIR}/aks_clusters.txt" ]; then
        aks_count=$(wc -l < "${OUTPUT_DIR}/aks_clusters.txt" | tr -d ' ')
        log_success "Discovered $aks_count AKS clusters."
    else
        log_warning "No AKS clusters found."
    fi
}

# Function to discover SQL servers with debug output
discover_sql() {
    if [[ "$TEST_SQL" != "true" ]]; then
        log "Skipping SQL discovery as requested"
        > "${OUTPUT_DIR}/sql_servers.txt"
        return
    fi
    
    log "Discovering SQL servers..."
    
    > "${OUTPUT_DIR}/sql_servers.txt"
    
    if [ ! -s "${OUTPUT_DIR}/resource_groups.txt" ]; then
        log_warning "No resource groups found, skipping SQL server discovery."
        return
    fi
    
    while IFS='|' read -r sub rg other || [ -n "$sub" ]; do
        # Skip empty lines or lines with empty fields
        [ -z "$sub" ] || [ -z "$rg" ] && continue
        
        # Set subscription context
        run_az_command "az account set --subscription \"$sub\"" "${OUTPUT_DIR}/sql_account_set_${sub}.log" "${OUTPUT_DIR}/sql_account_set_${sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for SQL discovery ($sub)"
        
        if [ ! -s "${OUTPUT_DIR}/sql_account_set_${sub}.log" ] && [ -s "${OUTPUT_DIR}/sql_account_set_${sub}.err" ]; then
            log_warning "Failed to set subscription context for $sub, skipping SQL discovery"
            continue
        fi
        
        # Get SQL servers in resource group
        run_az_command "az sql server list --resource-group \"$rg\" --query \"[].{name:name, fullyQualifiedDomainName:fullyQualifiedDomainName, id:id, version:version, privateEndpointConnections:privateEndpointConnections}\" -o json" "${OUTPUT_DIR}/sql_list_${sub}_${rg}.json" "${OUTPUT_DIR}/sql_list_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Listing SQL servers in resource group $rg"
        
        if [ -s "${OUTPUT_DIR}/sql_list_${sub}_${rg}.json" ]; then
            # Process each SQL server
            if [ "$JQ_AVAILABLE" = true ]; then
                # Parse with jq
                jq -c '.[]' "${OUTPUT_DIR}/sql_list_${sub}_${rg}.json" 2>/dev/null | while read -r sql_json; do
                    sql_name=$(echo "$sql_json" | jq -r '.name')
                    fqdn=$(echo "$sql_json" | jq -r '.fullyQualifiedDomainName // "unknown"')
                    sql_id=$(echo "$sql_json" | jq -r '.id')
                    version=$(echo "$sql_json" | jq -r '.version // "12.0"')
                    private_ep=$(echo "$sql_json" | jq -r 'if .privateEndpointConnections | length > 0 then "true" else "false" end')
                    
                    # Add SQL server to the list
                    echo "${sub}|${rg}|${sql_name}|${sql_id}|${fqdn}|${version}|${private_ep}" >> "${OUTPUT_DIR}/sql_servers.txt"
                    log "Found SQL server: $sql_name in resource group $rg"
                done
            else
                # Fallback parsing without jq
                run_az_command "az sql server list --resource-group \"$rg\" --query \"[].name\" -o tsv" "${OUTPUT_DIR}/sql_names_${sub}_${rg}.txt" "${OUTPUT_DIR}/sql_names_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Getting SQL server names in resource group $rg"
                
                if [ -s "${OUTPUT_DIR}/sql_names_${sub}_${rg}.txt" ]; then
                    while IFS= read -r sql_name || [ -n "$sql_name" ]; do
                        # Skip empty lines
                        [ -z "$sql_name" ] && continue
                        
                        # Get details for each SQL server
                        run_az_command "az sql server show -g \"$rg\" -n \"$sql_name\" -o json" "${OUTPUT_DIR}/sql_details_${sub}_${rg}_${sql_name}.json" "${OUTPUT_DIR}/sql_details_${sub}_${rg}_${sql_name}.err" "$DISCOVERY_TIMEOUT" "Getting details for SQL server $sql_name"
                        
                        sql_details_file="${OUTPUT_DIR}/sql_details_${sub}_${rg}_${sql_name}.json"
                        if [ -s "$sql_details_file" ]; then
                            # Extract SQL server details
                            fqdn=$(grep -o '"fullyQualifiedDomainName": *"[^"]*"' "$sql_details_file" | sed 's/"fullyQualifiedDomainName": *"\(.*\)"/\1/' || echo "unknown")
                            sql_id=$(grep -o '"id": *"[^"]*"' "$sql_details_file" | head -1 | sed 's/"id": *"\(.*\)"/\1/')
                            version=$(grep -o '"version": *"[^"]*"' "$sql_details_file" | sed 's/"version": *"\(.*\)"/\1/' || echo "12.0")
                            
                            # Check for private endpoints
                            if grep -q '"privateEndpointConnections": *\[' "$sql_details_file" && ! grep -q '"privateEndpointConnections": *\[\]' "$sql_details_file"; then
                                private_ep="true"
                            else
                                private_ep="false"
                            fi
                            
                            # Add SQL server to the list
                            echo "${sub}|${rg}|${sql_name}|${sql_id}|${fqdn}|${version}|${private_ep}" >> "${OUTPUT_DIR}/sql_servers.txt"
                            log "Found SQL server: $sql_name in resource group $rg"
                        fi
                    done < "${OUTPUT_DIR}/sql_names_${sub}_${rg}.txt"
                fi
            fi
        else
            log_warning "No SQL servers found in resource group $rg or empty response"
        fi
    done < "${OUTPUT_DIR}/resource_groups.txt"
    
    # Count discovered SQL servers
    if [ -s "${OUTPUT_DIR}/sql_servers.txt" ]; then
        sql_count=$(wc -l < "${OUTPUT_DIR}/sql_servers.txt" | tr -d ' ')
        log_success "Discovered $sql_count SQL servers."
    else
        log_warning "No SQL servers found."
    fi
}

# Function to discover storage accounts with debug output
discover_storage() {
    if [[ "$TEST_STORAGE" != "true" ]]; then
        log "Skipping Storage discovery as requested"
        > "${OUTPUT_DIR}/storage_accounts.txt"
        return
    fi
    
    log "Discovering storage accounts..."
    
    > "${OUTPUT_DIR}/storage_accounts.txt"
    
    if [ ! -s "${OUTPUT_DIR}/resource_groups.txt" ]; then
        log_warning "No resource groups found, skipping storage account discovery."
        return
    fi
    
    while IFS='|' read -r sub rg other || [ -n "$sub" ]; do
        # Skip empty lines or lines with empty fields
        [ -z "$sub" ] || [ -z "$rg" ] && continue
        
        # Set subscription context
        run_az_command "az account set --subscription \"$sub\"" "${OUTPUT_DIR}/storage_account_set_${sub}.log" "${OUTPUT_DIR}/storage_account_set_${sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for storage discovery ($sub)"
        
        if [ ! -s "${OUTPUT_DIR}/storage_account_set_${sub}.log" ] && [ -s "${OUTPUT_DIR}/storage_account_set_${sub}.err" ]; then
            log_warning "Failed to set subscription context for $sub, skipping storage discovery"
            continue
        fi
        
        # Get storage accounts in resource group
        run_az_command "az storage account list --resource-group \"$rg\" --query \"[].{name:name, id:id, location:location, primaryEndpoints:primaryEndpoints.blob, privateEndpointConnections:privateEndpointConnections, isHnsEnabled:isHnsEnabled}\" -o json" "${OUTPUT_DIR}/storage_list_${sub}_${rg}.json" "${OUTPUT_DIR}/storage_list_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Listing storage accounts in resource group $rg"
        
        if [ -s "${OUTPUT_DIR}/storage_list_${sub}_${rg}.json" ]; then
            # Process each storage account
            if [ "$JQ_AVAILABLE" = true ]; then
                # Parse with jq
                jq -c '.[]' "${OUTPUT_DIR}/storage_list_${sub}_${rg}.json" 2>/dev/null | while read -r storage_json; do
                    storage_name=$(echo "$storage_json" | jq -r '.name')
                    storage_id=$(echo "$storage_json" | jq -r '.id')
                    location=$(echo "$storage_json" | jq -r '.location // "unknown"')
                    private_ep=$(echo "$storage_json" | jq -r 'if .privateEndpointConnections | length > 0 then "true" else "false" end')
                    is_hns=$(echo "$storage_json" | jq -r '.isHnsEnabled // false')
                    blob_endpoint=$(echo "$storage_json" | jq -r '.primaryEndpoints // "unknown"')
                    
                    # Extract hostname from blob endpoint
                    if [ "$blob_endpoint" != "unknown" ]; then
                        blob_hostname=$(echo "$blob_endpoint" | sed -E 's|https://([^/]*)/.*|\1|')
                    else
                        blob_hostname="${storage_name}.blob.core.windows.net"
                    fi
                    
                    # Add storage account to the list
                    echo "${sub}|${rg}|${storage_name}|${storage_id}|${location}|${private_ep}|${is_hns}|${blob_hostname}" >> "${OUTPUT_DIR}/storage_accounts.txt"
                    log "Found storage account: $storage_name in resource group $rg"
                done
            else
                # Fallback parsing without jq
                run_az_command "az storage account list --resource-group \"$rg\" --query \"[].name\" -o tsv" "${OUTPUT_DIR}/storage_names_${sub}_${rg}.txt" "${OUTPUT_DIR}/storage_names_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Getting storage account names in resource group $rg"
                
                if [ -s "${OUTPUT_DIR}/storage_names_${sub}_${rg}.txt" ]; then
                    while IFS= read -r storage_name || [ -n "$storage_name" ]; do
                        # Skip empty lines
                        [ -z "$storage_name" ] && continue
                        
                        # Get details for each storage account
                        run_az_command "az storage account show -g \"$rg\" -n \"$storage_name\" -o json" "${OUTPUT_DIR}/storage_details_${sub}_${rg}_${storage_name}.json" "${OUTPUT_DIR}/storage_details_${sub}_${rg}_${storage_name}.err" "$DISCOVERY_TIMEOUT" "Getting details for storage account $storage_name"
                        
                        storage_details_file="${OUTPUT_DIR}/storage_details_${sub}_${rg}_${storage_name}.json"
                        if [ -s "$storage_details_file" ]; then
                            # Extract storage account details
                            storage_id=$(grep -o '"id": *"[^"]*"' "$storage_details_file" | head -1 | sed 's/"id": *"\(.*\)"/\1/')
                            location=$(grep -o '"location": *"[^"]*"' "$storage_details_file" | sed 's/"location": *"\(.*\)"/\1/' || echo "unknown")
                            
                            # Check for private endpoints
                            if grep -q '"privateEndpointConnections": *\[' "$storage_details_file" && ! grep -q '"privateEndpointConnections": *\[\]' "$storage_details_file"; then
                                private_ep="true"
                            else
                                private_ep="false"
                            fi
                            
                            # Check HNS
                            if grep -q '"isHnsEnabled": *true' "$storage_details_file"; then
                                is_hns="true"
                            else
                                is_hns="false"
                            fi
                            
                            # Extract blob endpoint
                            blob_endpoint=$(grep -o '"blob": *"[^"]*"' "$storage_details_file" | sed 's/"blob": *"\(.*\)"/\1/' || echo "https://${storage_name}.blob.core.windows.net/")
                            blob_hostname=$(echo "$blob_endpoint" | sed -E 's|https://([^/]*)/.*|\1|')
                            
                            # Add storage account to the list
                            echo "${sub}|${rg}|${storage_name}|${storage_id}|${location}|${private_ep}|${is_hns}|${blob_hostname}" >> "${OUTPUT_DIR}/storage_accounts.txt"
                            log "Found storage account: $storage_name in resource group $rg"
                        fi
                    done < "${OUTPUT_DIR}/storage_names_${sub}_${rg}.txt"
                fi
            fi
        else
            log_warning "No storage accounts found in resource group $rg or empty response"
        fi
    done < "${OUTPUT_DIR}/resource_groups.txt"
    
    # Count discovered storage accounts
    if [ -s "${OUTPUT_DIR}/storage_accounts.txt" ]; then
        storage_count=$(wc -l < "${OUTPUT_DIR}/storage_accounts.txt" | tr -d ' ')
        log_success "Discovered $storage_count storage accounts."
    else
        log_warning "No storage accounts found."
    fi
}

# Function to discover Service Bus namespaces with debug output
discover_servicebus() {
    if [[ "$TEST_SERVICEBUS" != "true" ]]; then
        log "Skipping Service Bus discovery as requested"
        > "${OUTPUT_DIR}/servicebus.txt"
        return
    fi
    
    log "Discovering Service Bus namespaces..."
    
    > "${OUTPUT_DIR}/servicebus.txt"
    
    if [ ! -s "${OUTPUT_DIR}/resource_groups.txt" ]; then
        log_warning "No resource groups found, skipping Service Bus discovery."
        return
    fi
    
    while IFS='|' read -r sub rg other || [ -n "$sub" ]; do
        # Skip empty lines or lines with empty fields
        [ -z "$sub" ] || [ -z "$rg" ] && continue
        
        # Set subscription context
        run_az_command "az account set --subscription \"$sub\"" "${OUTPUT_DIR}/sb_account_set_${sub}.log" "${OUTPUT_DIR}/sb_account_set_${sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for Service Bus discovery ($sub)"
        
        if [ ! -s "${OUTPUT_DIR}/sb_account_set_${sub}.log" ] && [ -s "${OUTPUT_DIR}/sb_account_set_${sub}.err" ]; then
            log_warning "Failed to set subscription context for $sub, skipping Service Bus discovery"
            continue
        fi
        
        # Get Service Bus namespaces in resource group
        run_az_command "az servicebus namespace list --resource-group \"$rg\" --query \"[].{name:name, id:id, serviceBusEndpoint:serviceBusEndpoint, privateEndpointConnections:privateEndpointConnections}\" -o json" "${OUTPUT_DIR}/servicebus_list_${sub}_${rg}.json" "${OUTPUT_DIR}/servicebus_list_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Listing Service Bus namespaces in resource group $rg"
        
        if [ -s "${OUTPUT_DIR}/servicebus_list_${sub}_${rg}.json" ]; then
            # Process each Service Bus namespace
            if [ "$JQ_AVAILABLE" = true ]; then
                # Parse with jq
                jq -c '.[]' "${OUTPUT_DIR}/servicebus_list_${sub}_${rg}.json" 2>/dev/null | while read -r sb_json; do
                    sb_name=$(echo "$sb_json" | jq -r '.name')
                    sb_id=$(echo "$sb_json" | jq -r '.id')
                    fqdn=$(echo "$sb_json" | jq -r '.serviceBusEndpoint // "unknown"')
                    private_ep=$(echo "$sb_json" | jq -r 'if .privateEndpointConnections | length > 0 then "true" else "false" end')
                    
                    # Clean up the FQDN
                    fqdn=$(echo "$fqdn" | sed -e 's|^https://||' -e 's|^sb://||' -e 's|/$||')
                    if [ -z "$fqdn" ] || [ "$fqdn" = "unknown" ]; then
                        fqdn="${sb_name}.servicebus.windows.net"
                    fi
                    
                    # Add Service Bus namespace to the list
                    echo "${sub}|${rg}|${sb_name}|${sb_id}|${fqdn}|${private_ep}" >> "${OUTPUT_DIR}/servicebus.txt"
                    log "Found Service Bus namespace: $sb_name in resource group $rg"
                done
            else
                # Fallback parsing without jq
                run_az_command "az servicebus namespace list --resource-group \"$rg\" --query \"[].name\" -o tsv" "${OUTPUT_DIR}/sb_names_${sub}_${rg}.txt" "${OUTPUT_DIR}/sb_names_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Getting Service Bus namespace names in resource group $rg"
                
                if [ -s "${OUTPUT_DIR}/sb_names_${sub}_${rg}.txt" ]; then
                    while IFS= read -r sb_name || [ -n "$sb_name" ]; do
                        # Skip empty lines
                        [ -z "$sb_name" ] && continue
                        
                        # Get details for each Service Bus namespace
                        run_az_command "az servicebus namespace show -g \"$rg\" -n \"$sb_name\" -o json" "${OUTPUT_DIR}/sb_details_${sub}_${rg}_${sb_name}.json" "${OUTPUT_DIR}/sb_details_${sub}_${rg}_${sb_name}.err" "$DISCOVERY_TIMEOUT" "Getting details for Service Bus namespace $sb_name"
                        
                        sb_details_file="${OUTPUT_DIR}/sb_details_${sub}_${rg}_${sb_name}.json"
                        if [ -s "$sb_details_file" ]; then
                            # Extract Service Bus namespace details
                            sb_id=$(grep -o '"id": *"[^"]*"' "$sb_details_file" | head -1 | sed 's/"id": *"\(.*\)"/\1/')
                            fqdn=$(grep -o '"serviceBusEndpoint": *"[^"]*"' "$sb_details_file" | sed 's/"serviceBusEndpoint": *"\(.*\)"/\1/' || echo "unknown")
                            
                            # Clean up the FQDN
                            fqdn=$(echo "$fqdn" | sed -e 's|^https://||' -e 's|^sb://||' -e 's|/$||')
                            if [ -z "$fqdn" ] || [ "$fqdn" = "unknown" ]; then
                                fqdn="${sb_name}.servicebus.windows.net"
                            fi
                            
                            # Check for private endpoints
                            if grep -q '"privateEndpointConnections": *\[' "$sb_details_file" && ! grep -q '"privateEndpointConnections": *\[\]' "$sb_details_file"; then
                                private_ep="true"
                            else
                                private_ep="false"
                            fi
                            
                            # Add Service Bus namespace to the list
                            echo "${sub}|${rg}|${sb_name}|${sb_id}|${fqdn}|${private_ep}" >> "${OUTPUT_DIR}/servicebus.txt"
                            log "Found Service Bus namespace: $sb_name in resource group $rg"
                        fi
                    done < "${OUTPUT_DIR}/sb_names_${sub}_${rg}.txt"
                fi
            fi
        else
            log_warning "No Service Bus namespaces found in resource group $rg or empty response"
        fi
    done < "${OUTPUT_DIR}/resource_groups.txt"
    
    # Add custom Service Bus endpoints if specified
    for endpoint in "${SERVICEBUS_ENDPOINTS[@]}"; do
        IFS=':' read -r sb_hostname sb_port sb_rg sb_sub <<< "$endpoint"
        sb_name=$(echo "$sb_hostname" | sed 's/\.servicebus\.windows\.net//')
        echo "${sb_sub:-unknown}|${sb_rg:-unknown}|${sb_name}|unknown|${sb_hostname}|false" >> "${OUTPUT_DIR}/servicebus.txt"
        log "Added custom Service Bus endpoint: $sb_hostname"
    done
    
    # Count discovered Service Bus namespaces
    if [ -s "${OUTPUT_DIR}/servicebus.txt" ]; then
        sb_count=$(wc -l < "${OUTPUT_DIR}/servicebus.txt" | tr -d ' ')
        log_success "Discovered $sb_count Service Bus namespaces."
    else
        log_warning "No Service Bus namespaces found."
    fi
}

# Function to discover Cosmos DB accounts with debug output
discover_cosmosdb() {
    if [[ "$TEST_COSMOSDB" != "true" ]]; then
        log "Skipping Cosmos DB discovery as requested"
        > "${OUTPUT_DIR}/cosmosdb.txt"
        return
    fi
    
    log "Discovering Cosmos DB accounts..."
    
    > "${OUTPUT_DIR}/cosmosdb.txt"
    
    if [ ! -s "${OUTPUT_DIR}/resource_groups.txt" ]; then
        log_warning "No resource groups found, skipping Cosmos DB discovery."
        return
    fi
    
    while IFS='|' read -r sub rg other || [ -n "$sub" ]; do
        # Skip empty lines or lines with empty fields
        [ -z "$sub" ] || [ -z "$rg" ] && continue
        
        # Set subscription context
        run_az_command "az account set --subscription \"$sub\"" "${OUTPUT_DIR}/cosmos_account_set_${sub}.log" "${OUTPUT_DIR}/cosmos_account_set_${sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for Cosmos DB discovery ($sub)"
        
        if [ ! -s "${OUTPUT_DIR}/cosmos_account_set_${sub}.log" ] && [ -s "${OUTPUT_DIR}/cosmos_account_set_${sub}.err" ]; then
            log_warning "Failed to set subscription context for $sub, skipping Cosmos DB discovery"
            continue
        fi
        
        # Get Cosmos DB accounts in resource group
        run_az_command "az cosmosdb list --resource-group \"$rg\" --query \"[].{name:name, id:id, documentEndpoint:documentEndpoint, privateEndpointConnections:privateEndpointConnections}\" -o json" "${OUTPUT_DIR}/cosmosdb_list_${sub}_${rg}.json" "${OUTPUT_DIR}/cosmosdb_list_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Listing Cosmos DB accounts in resource group $rg"
        
        if [ -s "${OUTPUT_DIR}/cosmosdb_list_${sub}_${rg}.json" ]; then
            # Process each Cosmos DB account
            if [ "$JQ_AVAILABLE" = true ]; then
                # Parse with jq
                jq -c '.[]' "${OUTPUT_DIR}/cosmosdb_list_${sub}_${rg}.json" 2>/dev/null | while read -r cosmos_json; do
                    cosmos_name=$(echo "$cosmos_json" | jq -r '.name')
                    cosmos_id=$(echo "$cosmos_json" | jq -r '.id')
                    endpoint=$(echo "$cosmos_json" | jq -r '.documentEndpoint // "unknown"')
                    private_ep=$(echo "$cosmos_json" | jq -r 'if .privateEndpointConnections | length > 0 then "true" else "false" end')
                    
                    # Clean up the endpoint
                    fqdn=$(echo "$endpoint" | sed -e 's|^https://||' -e 's|/$||')
                    
                    # Add Cosmos DB account to the list
                    echo "${sub}|${rg}|${cosmos_name}|${cosmos_id}|${fqdn}|${private_ep}" >> "${OUTPUT_DIR}/cosmosdb.txt"
                    log "Found Cosmos DB account: $cosmos_name in resource group $rg"
                done
            else
                # Fallback parsing without jq
                run_az_command "az cosmosdb list --resource-group \"$rg\" --query \"[].name\" -o tsv" "${OUTPUT_DIR}/cosmos_names_${sub}_${rg}.txt" "${OUTPUT_DIR}/cosmos_names_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Getting Cosmos DB account names in resource group $rg"
                
                if [ -s "${OUTPUT_DIR}/cosmos_names_${sub}_${rg}.txt" ]; then
                    while IFS= read -r cosmos_name || [ -n "$cosmos_name" ]; do
                        # Skip empty lines
                        [ -z "$cosmos_name" ] && continue
                        
                        # Get details for each Cosmos DB account
                        run_az_command "az cosmosdb show -g \"$rg\" -n \"$cosmos_name\" -o json" "${OUTPUT_DIR}/cosmos_details_${sub}_${rg}_${cosmos_name}.json" "${OUTPUT_DIR}/cosmos_details_${sub}_${rg}_${cosmos_name}.err" "$DISCOVERY_TIMEOUT" "Getting details for Cosmos DB account $cosmos_name"
                        
                        cosmos_details_file="${OUTPUT_DIR}/cosmos_details_${sub}_${rg}_${cosmos_name}.json"
                        if [ -s "$cosmos_details_file" ]; then
                            # Extract Cosmos DB account details
                            cosmos_id=$(grep -o '"id": *"[^"]*"' "$cosmos_details_file" | head -1 | sed 's/"id": *"\(.*\)"/\1/')
                            endpoint=$(grep -o '"documentEndpoint": *"[^"]*"' "$cosmos_details_file" | sed 's/"documentEndpoint": *"\(.*\)"/\1/' || echo "unknown")
                            
                            # Clean up the endpoint
                            fqdn=$(echo "$endpoint" | sed -e 's|^https://||' -e 's|/$||')
                            
                            # Check for private endpoints
                            if grep -q '"privateEndpointConnections": *\[' "$cosmos_details_file" && ! grep -q '"privateEndpointConnections": *\[\]' "$cosmos_details_file"; then
                                private_ep="true"
                            else
                                private_ep="false"
                            fi
                            
                            # Add Cosmos DB account to the list
                            echo "${sub}|${rg}|${cosmos_name}|${cosmos_id}|${fqdn}|${private_ep}" >> "${OUTPUT_DIR}/cosmosdb.txt"
                            log "Found Cosmos DB account: $cosmos_name in resource group $rg"
                        fi
                    done < "${OUTPUT_DIR}/cosmos_names_${sub}_${rg}.txt"
                fi
            fi
        else
            log_warning "No Cosmos DB accounts found in resource group $rg or empty response"
        fi
    done < "${OUTPUT_DIR}/resource_groups.txt"
    
    # Count discovered Cosmos DB accounts
    if [ -s "${OUTPUT_DIR}/cosmosdb.txt" ]; then
        cosmos_count=$(wc -l < "${OUTPUT_DIR}/cosmosdb.txt" | tr -d ' ')
        log_success "Discovered $cosmos_count Cosmos DB accounts."
    else
        log_warning "No Cosmos DB accounts found."
    fi
}

# Function to discover Event Hub namespaces
discover_eventhub() {
    if [[ "$TEST_EVENTHUB" != "true" ]]; then
        log "Skipping Event Hub discovery as requested"
        > "${OUTPUT_DIR}/eventhub.txt"
        return
    fi
    
    log "Discovering Event Hub namespaces..."
    
    > "${OUTPUT_DIR}/eventhub.txt"
    
    if [ ! -s "${OUTPUT_DIR}/resource_groups.txt" ]; then
        log_warning "No resource groups found, skipping Event Hub discovery."
        return
    fi
    
    while IFS='|' read -r sub rg other || [ -n "$sub" ]; do
        # Skip empty lines or lines with empty fields
        [ -z "$sub" ] || [ -z "$rg" ] && continue
        
        # Set subscription context
        run_az_command "az account set --subscription \"$sub\"" "${OUTPUT_DIR}/eh_account_set_${sub}.log" "${OUTPUT_DIR}/eh_account_set_${sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for Event Hub discovery ($sub)"
        
        if [ ! -s "${OUTPUT_DIR}/eh_account_set_${sub}.log" ] && [ -s "${OUTPUT_DIR}/eh_account_set_${sub}.err" ]; then
            log_warning "Failed to set subscription context for $sub, skipping Event Hub discovery"
            continue
        fi
        
        # Get Event Hub namespaces in resource group
        run_az_command "az eventhubs namespace list --resource-group \"$rg\" --query \"[].{name:name, id:id, serviceBusEndpoint:serviceBusEndpoint, privateEndpointConnections:privateEndpointConnections}\" -o json" "${OUTPUT_DIR}/eventhub_list_${sub}_${rg}.json" "${OUTPUT_DIR}/eventhub_list_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Listing Event Hub namespaces in resource group $rg"
        
        if [ -s "${OUTPUT_DIR}/eventhub_list_${sub}_${rg}.json" ]; then
            # Process each Event Hub namespace
            if [ "$JQ_AVAILABLE" = true ]; then
                # Parse with jq
                jq -c '.[]' "${OUTPUT_DIR}/eventhub_list_${sub}_${rg}.json" 2>/dev/null | while read -r eh_json; do
                    eh_name=$(echo "$eh_json" | jq -r '.name')
                    eh_id=$(echo "$eh_json" | jq -r '.id')
                    fqdn=$(echo "$eh_json" | jq -r '.serviceBusEndpoint // "unknown"')
                    private_ep=$(echo "$eh_json" | jq -r 'if .privateEndpointConnections | length > 0 then "true" else "false" end')
                    
                    # Clean up the FQDN
                    fqdn=$(echo "$fqdn" | sed -e 's|^https://||' -e 's|^sb://||' -e 's|/$||')
                    if [ -z "$fqdn" ] || [ "$fqdn" = "unknown" ]; then
                        fqdn="${eh_name}.servicebus.windows.net"
                    fi
                    
                    # Add Event Hub namespace to the list
                    echo "${sub}|${rg}|${eh_name}|${eh_id}|${fqdn}|${private_ep}" >> "${OUTPUT_DIR}/eventhub.txt"
                    log "Found Event Hub namespace: $eh_name in resource group $rg"
                done
            else
                # Fallback parsing without jq
                run_az_command "az eventhubs namespace list --resource-group \"$rg\" --query \"[].name\" -o tsv" "${OUTPUT_DIR}/eh_names_${sub}_${rg}.txt" "${OUTPUT_DIR}/eh_names_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Getting Event Hub namespace names in resource group $rg"
                
                if [ -s "${OUTPUT_DIR}/eh_names_${sub}_${rg}.txt" ]; then
                    while IFS= read -r eh_name || [ -n "$eh_name" ]; do
                        # Skip empty lines
                        [ -z "$eh_name" ] && continue
                        
                        # Get details for each Event Hub namespace
                        run_az_command "az eventhubs namespace show -g \"$rg\" -n \"$eh_name\" -o json" "${OUTPUT_DIR}/eh_details_${sub}_${rg}_${eh_name}.json" "${OUTPUT_DIR}/eh_details_${sub}_${rg}_${eh_name}.err" "$DISCOVERY_TIMEOUT" "Getting details for Event Hub namespace $eh_name"
                        
                        eh_details_file="${OUTPUT_DIR}/eh_details_${sub}_${rg}_${eh_name}.json"
                        if [ -s "$eh_details_file" ]; then
                            # Extract Event Hub namespace details
                            eh_id=$(grep -o '"id": *"[^"]*"' "$eh_details_file" | head -1 | sed 's/"id": *"\(.*\)"/\1/')
                            fqdn=$(grep -o '"serviceBusEndpoint": *"[^"]*"' "$eh_details_file" | sed 's/"serviceBusEndpoint": *"\(.*\)"/\1/' || echo "unknown")
                            
                            # Clean up the FQDN
                            fqdn=$(echo "$fqdn" | sed -e 's|^https://||' -e 's|^sb://||' -e 's|/$||')
                            if [ -z "$fqdn" ] || [ "$fqdn" = "unknown" ]; then
                                fqdn="${eh_name}.servicebus.windows.net"
                            fi
                            
                            # Check for private endpoints
                            if grep -q '"privateEndpointConnections": *\[' "$eh_details_file" && ! grep -q '"privateEndpointConnections": *\[\]' "$eh_details_file"; then
                                private_ep="true"
                            else
                                private_ep="false"
                            fi
                            
                            # Add Event Hub namespace to the list
                            echo "${sub}|${rg}|${eh_name}|${eh_id}|${fqdn}|${private_ep}" >> "${OUTPUT_DIR}/eventhub.txt"
                            log "Found Event Hub namespace: $eh_name in resource group $rg"
                        fi
                    done < "${OUTPUT_DIR}/eh_names_${sub}_${rg}.txt"
                fi
            fi
        else
            log_warning "No Event Hub namespaces found in resource group $rg or empty response"
        fi
    done < "${OUTPUT_DIR}/resource_groups.txt"
    
    # Count discovered Event Hub namespaces
    if [ -s "${OUTPUT_DIR}/eventhub.txt" ]; then
        eh_count=$(wc -l < "${OUTPUT_DIR}/eventhub.txt" | tr -d ' ')
        log_success "Discovered $eh_count Event Hub namespaces."
    else
        log_warning "No Event Hub namespaces found."
    fi
}

# Function to discover VPN Gateways and ExpressRoute circuits with debug output
discover_hybrid_connectivity() {
    log "Discovering hybrid connectivity resources (VPN/ExpressRoute)..."
    
    > "${OUTPUT_DIR}/gateways.txt"
    
    if [ ! -s "${OUTPUT_DIR}/resource_groups.txt" ]; then
        log_warning "No resource groups found, skipping hybrid connectivity discovery."
        return
    fi
    
    while IFS='|' read -r sub rg other || [ -n "$sub" ]; do
        # Skip empty lines or lines with empty fields
        [ -z "$sub" ] || [ -z "$rg" ] && continue
        
        # Set subscription context
        run_az_command "az account set --subscription \"$sub\"" "${OUTPUT_DIR}/gateway_account_set_${sub}.log" "${OUTPUT_DIR}/gateway_account_set_${sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for gateway discovery ($sub)"
        
        if [ ! -s "${OUTPUT_DIR}/gateway_account_set_${sub}.log" ] && [ -s "${OUTPUT_DIR}/gateway_account_set_${sub}.err" ]; then
            log_warning "Failed to set subscription context for $sub, skipping gateway discovery"
            continue
        fi
        
        # Get VPN gateways in resource group
        run_az_command "az network vnet-gateway list --resource-group \"$rg\" --query \"[].{name:name, id:id, type:gatewayType, vpnType:vpnType, bgpSettings:bgpSettings, ipConfigurations:ipConfigurations}\" -o json" "${OUTPUT_DIR}/vpn_gw_list_${sub}_${rg}.json" "${OUTPUT_DIR}/vpn_gw_list_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Listing VPN gateways in resource group $rg"
        
        if [ -s "${OUTPUT_DIR}/vpn_gw_list_${sub}_${rg}.json" ]; then
            # Process each VPN gateway
            if [ "$JQ_AVAILABLE" = true ]; then
                # Parse with jq
                jq -c '.[]' "${OUTPUT_DIR}/vpn_gw_list_${sub}_${rg}.json" 2>/dev/null | while read -r gw_json; do
                    gw_name=$(echo "$gw_json" | jq -r '.name')
                    gw_id=$(echo "$gw_json" | jq -r '.id')
                    gw_type=$(echo "$gw_json" | jq -r '.type // "VirtualNetworkGateway"')
                    vpn_type=$(echo "$gw_json" | jq -r '.vpnType // "RouteBased"')
                    
                    # Get public IP if available
                    public_ip="unknown"
                    ip_config=$(echo "$gw_json" | jq -r '.ipConfigurations[0].publicIpAddress.id' 2>/dev/null)
                    if [ -n "$ip_config" ] && [ "$ip_config" != "null" ]; then
                        run_az_command "az network public-ip show --ids \"$ip_config\" --query \"ipAddress\" -o tsv" "${OUTPUT_DIR}/gateway_pubip_${sub}_${rg}_${gw_name}.txt" "${OUTPUT_DIR}/gateway_pubip_${sub}_${rg}_${gw_name}.err" "$DISCOVERY_TIMEOUT" "Getting public IP for gateway $gw_name"
                        public_ip=$(cat "${OUTPUT_DIR}/gateway_pubip_${sub}_${rg}_${gw_name}.txt" 2>/dev/null || echo "unknown")
                    fi
                    
                    # Get VNet name
                    vnet_name="unknown"
                    vnet_id=$(echo "$gw_json" | jq -r '.ipConfigurations[0].subnet.id' 2>/dev/null)
                    if [ -n "$vnet_id" ] && [ "$vnet_id" != "null" ]; then
                        vnet_name=$(echo "$vnet_id" | awk -F'/' '{print $(NF-2)}')
                    fi
                    
                    # Add gateway to the list
                    echo "${sub}|${rg}|${gw_name}|${gw_id}|${gw_type}|${vpn_type}|${public_ip}|${vnet_name}" >> "${OUTPUT_DIR}/gateways.txt"
                    log "Found VPN gateway: $gw_name in resource group $rg"
                done
            else
                # Fallback parsing without jq
                run_az_command "az network vnet-gateway list --resource-group \"$rg\" --query \"[].name\" -o tsv" "${OUTPUT_DIR}/gateway_names_${sub}_${rg}.txt" "${OUTPUT_DIR}/gateway_names_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Getting VPN gateway names in resource group $rg"
                
                if [ -s "${OUTPUT_DIR}/gateway_names_${sub}_${rg}.txt" ]; then
                    while IFS= read -r gw_name || [ -n "$gw_name" ]; do
                        # Skip empty lines
                        [ -z "$gw_name" ] && continue
                        
                        # Get details for each VPN gateway
                        run_az_command "az network vnet-gateway show -g \"$rg\" -n \"$gw_name\" -o json" "${OUTPUT_DIR}/gateway_details_${sub}_${rg}_${gw_name}.json" "${OUTPUT_DIR}/gateway_details_${sub}_${rg}_${gw_name}.err" "$DISCOVERY_TIMEOUT" "Getting details for VPN gateway $gw_name"
                        
                        gateway_details_file="${OUTPUT_DIR}/gateway_details_${sub}_${rg}_${gw_name}.json"
                        if [ -s "$gateway_details_file" ]; then
                            # Extract VPN gateway details
                            gw_id=$(grep -o '"id": *"[^"]*"' "$gateway_details_file" | head -1 | sed 's/"id": *"\(.*\)"/\1/')
                            gw_type=$(grep -o '"gatewayType": *"[^"]*"' "$gateway_details_file" | sed 's/"gatewayType": *"\(.*\)"/\1/' || echo "VirtualNetworkGateway")
                            vpn_type=$(grep -o '"vpnType": *"[^"]*"' "$gateway_details_file" | sed 's/"vpnType": *"\(.*\)"/\1/' || echo "RouteBased")
                            
                            # Get public IP
                            public_ip="unknown"
                            run_az_command "az network vnet-gateway show -g \"$rg\" -n \"$gw_name\" --query \"ipConfigurations[0].publicIpAddress.id\" -o tsv" "${OUTPUT_DIR}/gateway_pip_id_${sub}_${rg}_${gw_name}.txt" "${OUTPUT_DIR}/gateway_pip_id_${sub}_${rg}_${gw_name}.err" "$DISCOVERY_TIMEOUT" "Getting public IP ID for gateway $gw_name"
                            ip_id=$(cat "${OUTPUT_DIR}/gateway_pip_id_${sub}_${rg}_${gw_name}.txt" 2>/dev/null)
                            if [ -n "$ip_id" ]; then
                                run_az_command "az network public-ip show --ids \"$ip_id\" --query \"ipAddress\" -o tsv" "${OUTPUT_DIR}/gateway_pubip_${sub}_${rg}_${gw_name}.txt" "${OUTPUT_DIR}/gateway_pubip_${sub}_${rg}_${gw_name}.err" "$DISCOVERY_TIMEOUT" "Getting public IP for gateway $gw_name"
                                public_ip=$(cat "${OUTPUT_DIR}/gateway_pubip_${sub}_${rg}_${gw_name}.txt" 2>/dev/null || echo "unknown")
                            fi
                            
                            # Get VNet name
                            vnet_name="unknown"
                            run_az_command "az network vnet-gateway show -g \"$rg\" -n \"$gw_name\" --query \"ipConfigurations[0].subnet.id\" -o tsv" "${OUTPUT_DIR}/gateway_subnet_id_${sub}_${rg}_${gw_name}.txt" "${OUTPUT_DIR}/gateway_subnet_id_${sub}_${rg}_${gw_name}.err" "$DISCOVERY_TIMEOUT" "Getting subnet ID for gateway $gw_name"
                            subnet_id=$(cat "${OUTPUT_DIR}/gateway_subnet_id_${sub}_${rg}_${gw_name}.txt" 2>/dev/null)
                            if [ -n "$subnet_id" ]; then
                                vnet_name=$(echo "$subnet_id" | awk -F'/' '{print $(NF-2)}')
                            fi
                            
                            # Add gateway to the list
                            echo "${sub}|${rg}|${gw_name}|${gw_id}|${gw_type}|${vpn_type}|${public_ip}|${vnet_name}" >> "${OUTPUT_DIR}/gateways.txt"
                            log "Found VPN gateway: $gw_name in resource group $rg"
                        fi
                    done < "${OUTPUT_DIR}/gateway_names_${sub}_${rg}.txt"
                fi
            fi
        fi
        
        # Get ExpressRoute circuits in resource group
        run_az_command "az network express-route list --resource-group \"$rg\" --query \"[].{name:name, id:id, circuitProvisioningState:circuitProvisioningState, serviceProviderProvisioningState:serviceProviderProvisioningState}\" -o json" "${OUTPUT_DIR}/er_list_${sub}_${rg}.json" "${OUTPUT_DIR}/er_list_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Listing ExpressRoute circuits in resource group $rg"
        
        if [ -s "${OUTPUT_DIR}/er_list_${sub}_${rg}.json" ]; then
            # Process each ExpressRoute circuit
            if [ "$JQ_AVAILABLE" = true ]; then
                # Parse with jq
                jq -c '.[]' "${OUTPUT_DIR}/er_list_${sub}_${rg}.json" 2>/dev/null | while read -r er_json; do
                    er_name=$(echo "$er_json" | jq -r '.name')
                    er_id=$(echo "$er_json" | jq -r '.id')
                    er_state=$(echo "$er_json" | jq -r '.circuitProvisioningState // "unknown"')
                    er_sp_state=$(echo "$er_json" | jq -r '.serviceProviderProvisioningState // "unknown"')
                    
                    # Add ExpressRoute circuit to the list
                    echo "${sub}|${rg}|${er_name}|${er_id}|ExpressRoute|${er_state}|${er_sp_state}|unknown" >> "${OUTPUT_DIR}/gateways.txt"
                    log "Found ExpressRoute circuit: $er_name in resource group $rg"
                done
            else
                # Fallback parsing without jq
                run_az_command "az network express-route list --resource-group \"$rg\" --query \"[].name\" -o tsv" "${OUTPUT_DIR}/er_names_${sub}_${rg}.txt" "${OUTPUT_DIR}/er_names_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Getting ExpressRoute circuit names in resource group $rg"
                
                if [ -s "${OUTPUT_DIR}/er_names_${sub}_${rg}.txt" ]; then
                    while IFS= read -r er_name || [ -n "$er_name" ]; do
                        # Skip empty lines
                        [ -z "$er_name" ] && continue
                        
                        # Get details for each ExpressRoute circuit
                        run_az_command "az network express-route show -g \"$rg\" -n \"$er_name\" -o json" "${OUTPUT_DIR}/er_details_${sub}_${rg}_${er_name}.json" "${OUTPUT_DIR}/er_details_${sub}_${rg}_${er_name}.err" "$DISCOVERY_TIMEOUT" "Getting details for ExpressRoute circuit $er_name"
                        
                        er_details_file="${OUTPUT_DIR}/er_details_${sub}_${rg}_${er_name}.json"
                        if [ -s "$er_details_file" ]; then
                            # Extract ExpressRoute circuit details
                            er_id=$(grep -o '"id": *"[^"]*"' "$er_details_file" | head -1 | sed 's/"id": *"\(.*\)"/\1/')
                            er_state=$(grep -o '"circuitProvisioningState": *"[^"]*"' "$er_details_file" | sed 's/"circuitProvisioningState": *"\(.*\)"/\1/' || echo "unknown")
                            er_sp_state=$(grep -o '"serviceProviderProvisioningState": *"[^"]*"' "$er_details_file" | sed 's/"serviceProviderProvisioningState": *"\(.*\)"/\1/' || echo "unknown")
                            
                            # Add ExpressRoute circuit to the list
                            echo "${sub}|${rg}|${er_name}|${er_id}|ExpressRoute|${er_state}|${er_sp_state}|unknown" >> "${OUTPUT_DIR}/gateways.txt"
                            log "Found ExpressRoute circuit: $er_name in resource group $rg"
                        fi
                    done < "${OUTPUT_DIR}/er_names_${sub}_${rg}.txt"
                fi
            fi
        fi
    done < "${OUTPUT_DIR}/resource_groups.txt"
    
    # Count discovered gateways
    if [ -s "${OUTPUT_DIR}/gateways.txt" ]; then
        vpn_count=$(grep -v "ExpressRoute" "${OUTPUT_DIR}/gateways.txt" | wc -l | tr -d ' ')
        er_count=$(grep "ExpressRoute" "${OUTPUT_DIR}/gateways.txt" | wc -l | tr -d ' ')
        log_success "Discovered $vpn_count VPN gateways and $er_count ExpressRoute circuits."
    else
        log_warning "No VPN gateways or ExpressRoute circuits found."
    fi
}

# Function to detect on-premises networks with debug output
detect_onprem_networks() {
    if [[ "$TEST_ONPREM" != "true" ]]; then
        log "Skipping on-premises network detection as requested"
        > "${OUTPUT_DIR}/onprem_networks.txt"
        return
    fi
    
    log "Detecting on-premises networks..."
    
    > "${OUTPUT_DIR}/onprem_networks.txt"
    
    if [ ! -s "${OUTPUT_DIR}/gateways.txt" ]; then
        log_warning "No gateways found, skipping on-premises network detection."
        return
    fi
    
    # Method 1: Look for custom routes to on-premises
    if [ -s "${OUTPUT_DIR}/resource_groups.txt" ]; then
        while IFS='|' read -r sub rg other || [ -n "$sub" ]; do
            # Skip empty lines
            [ -z "$sub" ] || [ -z "$rg" ] && continue
            
            # Set subscription context
            run_az_command "az account set --subscription \"$sub\"" "${OUTPUT_DIR}/onprem_account_set_${sub}.log" "${OUTPUT_DIR}/onprem_account_set_${sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for on-premises network detection ($sub)"
            
            if [ ! -s "${OUTPUT_DIR}/onprem_account_set_${sub}.log" ] && [ -s "${OUTPUT_DIR}/onprem_account_set_${sub}.err" ]; then
                log_warning "Failed to set subscription context for $sub, skipping route table analysis"
                continue
            fi
            
            # Get route tables with routes that have next hop type VirtualNetworkGateway
            run_az_command "az network route-table list --resource-group \"$rg\" --query \"[].{name:name, id:id}\" -o json" "${OUTPUT_DIR}/route_tables_${sub}_${rg}.json" "${OUTPUT_DIR}/route_tables_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Listing route tables in resource group $rg"
            
            if [ -s "${OUTPUT_DIR}/route_tables_${sub}_${rg}.json" ]; then
                if [ "$JQ_AVAILABLE" = true ]; then
                    # Parse with jq
                    jq -c '.[]' "${OUTPUT_DIR}/route_tables_${sub}_${rg}.json" 2>/dev/null | while read -r rt_json; do
                        rt_name=$(echo "$rt_json" | jq -r '.name')
                        rt_id=$(echo "$rt_json" | jq -r '.id')
                        
                        # Get routes with next hop type VirtualNetworkGateway
                        run_az_command "az network route-table route list --ids \"$rt_id\" --query \"[?nextHopType=='VirtualNetworkGateway'].{name:name, addressPrefix:addressPrefix}\" -o json" "${OUTPUT_DIR}/routes_${sub}_${rg}_${rt_name}.json" "${OUTPUT_DIR}/routes_${sub}_${rg}_${rt_name}.err" "$DISCOVERY_TIMEOUT" "Listing routes with next hop type VirtualNetworkGateway in route table $rt_name"
                        
                        if [ -s "${OUTPUT_DIR}/routes_${sub}_${rg}_${rt_name}.json" ]; then
                            jq -c '.[]' "${OUTPUT_DIR}/routes_${sub}_${rg}_${rt_name}.json" 2>/dev/null | while read -r route_json; do
                                route_prefix=$(echo "$route_json" | jq -r '.addressPrefix')
                                route_name=$(echo "$route_json" | jq -r '.name')
                                
                                # Add to on-premises networks
                                echo "${sub}|${rg}|${route_prefix}|from_route_table_${rt_name}_${route_name}" >> "${OUTPUT_DIR}/onprem_networks.txt"
                                log "Found on-premises network: $route_prefix from route table $rt_name"
                            done
                        fi
                    done
                else
                    # Fallback parsing without jq
                    run_az_command "az network route-table list --resource-group \"$rg\" --query \"[].name\" -o tsv" "${OUTPUT_DIR}/rt_names_${sub}_${rg}.txt" "${OUTPUT_DIR}/rt_names_${sub}_${rg}.err" "$DISCOVERY_TIMEOUT" "Getting route table names in resource group $rg"
                    
                    if [ -s "${OUTPUT_DIR}/rt_names_${sub}_${rg}.txt" ]; then
                        while IFS= read -r rt_name || [ -n "$rt_name" ]; do
                            # Skip empty lines
                            [ -z "$rt_name" ] && continue
                            
                            # Get route table ID
                            run_az_command "az network route-table show -g \"$rg\" -n \"$rt_name\" --query \"id\" -o tsv" "${OUTPUT_DIR}/rt_id_${sub}_${rg}_${rt_name}.txt" "${OUTPUT_DIR}/rt_id_${sub}_${rg}_${rt_name}.err" "$DISCOVERY_TIMEOUT" "Getting ID for route table $rt_name"
                            
                            rt_id=$(cat "${OUTPUT_DIR}/rt_id_${sub}_${rg}_${rt_name}.txt" 2>/dev/null)
                            if [ -n "$rt_id" ]; then
                                # Get routes with next hop type VirtualNetworkGateway
                                run_az_command "az network route-table route list --ids \"$rt_id\" --query \"[?nextHopType=='VirtualNetworkGateway'].[name, addressPrefix]\" -o tsv" "${OUTPUT_DIR}/gateway_routes_${sub}_${rg}_${rt_name}.txt" "${OUTPUT_DIR}/gateway_routes_${sub}_${rg}_${rt_name}.err" "$DISCOVERY_TIMEOUT" "Getting routes with next hop type VirtualNetworkGateway in route table $rt_name"
                                
                                if [ -s "${OUTPUT_DIR}/gateway_routes_${sub}_${rg}_${rt_name}.txt" ]; then
                                    paste -d " " - - < "${OUTPUT_DIR}/gateway_routes_${sub}_${rg}_${rt_name}.txt" | while read -r route_name route_prefix; do
                                        [ -z "$route_name" ] || [ -z "$route_prefix" ] && continue
                                        
                                        # Add to on-premises networks
                                        echo "${sub}|${rg}|${route_prefix}|from_route_table_${rt_name}_${route_name}" >> "${OUTPUT_DIR}/onprem_networks.txt"
                                        log "Found on-premises network: $route_prefix from route table $rt_name"
                                    done
                                fi
                            fi
                        done < "${OUTPUT_DIR}/rt_names_${sub}_${rg}.txt"
                    fi
                fi
            fi
        done < "${OUTPUT_DIR}/resource_groups.txt"
    fi
    
    # Method 2: Look for VPN connection local network gateways
    while IFS='|' read -r sub rg gw_name gw_id gw_type vpn_type public_ip vnet_name || [ -n "$sub" ]; do
        # Skip ExpressRoute and empty lines
        [ -z "$sub" ] || [ -z "$rg" ] || [ -z "$gw_name" ] || [ "$gw_type" = "ExpressRoute" ] && continue
        
        # Set subscription context
        run_az_command "az account set --subscription \"$sub\"" "${OUTPUT_DIR}/vpn_connection_account_set_${sub}.log" "${OUTPUT_DIR}/vpn_connection_account_set_${sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for VPN connection analysis ($sub)"
        
        if [ ! -s "${OUTPUT_DIR}/vpn_connection_account_set_${sub}.log" ] && [ -s "${OUTPUT_DIR}/vpn_connection_account_set_${sub}.err" ]; then
            log_warning "Failed to set subscription context for $sub, skipping VPN connection analysis"
            continue
        fi
        
        # Get VPN connections for this gateway
        run_az_command "az network vpn-connection list --resource-group \"$rg\" --query \"[?contains(virtualNetworkGateway1.id, '${gw_name}')].{name:name, id:id, connectionStatus:connectionStatus, localNetworkGateway2:localNetworkGateway2}\" -o json" "${OUTPUT_DIR}/vpn_connections_${sub}_${rg}_${gw_name}.json" "${OUTPUT_DIR}/vpn_connections_${sub}_${rg}_${gw_name}.err" "$DISCOVERY_TIMEOUT" "Listing VPN connections for gateway $gw_name"
        
        if [ -s "${OUTPUT_DIR}/vpn_connections_${sub}_${rg}_${gw_name}.json" ]; then
            if [ "$JQ_AVAILABLE" = true ]; then
                # Parse with jq
                jq -c '.[]' "${OUTPUT_DIR}/vpn_connections_${sub}_${rg}_${gw_name}.json" 2>/dev/null | while read -r conn_json; do
                    conn_name=$(echo "$conn_json" | jq -r '.name')
                    conn_status=$(echo "$conn_json" | jq -r '.connectionStatus // "unknown"')
                    lng_id=$(echo "$conn_json" | jq -r '.localNetworkGateway2.id // ""')
                    
                    # Skip if no local network gateway
                    [ -z "$lng_id" ] || [ "$lng_id" = "null" ] && continue
                    
                    # Extract local network gateway details
                    lng_rg=$(echo "$lng_id" | awk -F'/' '{for(i=1;i<=NF;i++) if($i=="resourceGroups") print $(i+1)}')
                    lng_name=$(echo "$lng_id" | awk -F'/' '{print $NF}')
                    
                    # Get local network gateway address prefixes
                    if [ -n "$lng_rg" ] && [ -n "$lng_name" ]; then
                        run_az_command "az network local-gateway show --resource-group \"$lng_rg\" --name \"$lng_name\" --query \"localNetworkAddressSpace.addressPrefixes\" -o json" "${OUTPUT_DIR}/lng_prefixes_${sub}_${lng_rg}_${lng_name}.json" "${OUTPUT_DIR}/lng_prefixes_${sub}_${lng_rg}_${lng_name}.err" "$DISCOVERY_TIMEOUT" "Getting address prefixes for local network gateway $lng_name"
                        
                        if [ -s "${OUTPUT_DIR}/lng_prefixes_${sub}_${lng_rg}_${lng_name}.json" ]; then
                            jq -r '.[]' "${OUTPUT_DIR}/lng_prefixes_${sub}_${lng_rg}_${lng_name}.json" 2>/dev/null | while read -r prefix; do
                                # Add to on-premises networks
                                echo "${sub}|${rg}|${prefix}|from_vpn_connection_${conn_name}_${conn_status}" >> "${OUTPUT_DIR}/onprem_networks.txt"
                                log "Found on-premises network: $prefix from VPN connection $conn_name (status: $conn_status)"
                            done
                        fi
                    fi
                done
            else
                # Fallback parsing without jq
                run_az_command "az network vpn-connection list --resource-group \"$rg\" --query \"[?contains(virtualNetworkGateway1.id, '${gw_name}')].[name, connectionStatus, localNetworkGateway2.id]\" -o tsv" "${OUTPUT_DIR}/vpn_connections_tsv_${sub}_${rg}_${gw_name}.txt" "${OUTPUT_DIR}/vpn_connections_tsv_${sub}_${rg}_${gw_name}.err" "$DISCOVERY_TIMEOUT" "Listing VPN connections for gateway $gw_name (TSV)"
                
                if [ -s "${OUTPUT_DIR}/vpn_connections_tsv_${sub}_${rg}_${gw_name}.txt" ]; then
                    while IFS=$'\t' read -r conn_name conn_status lng_id || [ -n "$conn_name" ]; do
                        # Skip empty lines or connections without local network gateway
                        [ -z "$conn_name" ] || [ -z "$lng_id" ] && continue
                        
                        # Extract local network gateway details
                        lng_rg=$(echo "$lng_id" | awk -F'/' '{for(i=1;i<=NF;i++) if($i=="resourceGroups") print $(i+1)}')
                        lng_name=$(echo "$lng_id" | awk -F'/' '{print $NF}')
                        
                        # Get local network gateway address prefixes
                        if [ -n "$lng_rg" ] && [ -n "$lng_name" ]; then
                            run_az_command "az network local-gateway show --resource-group \"$lng_rg\" --name \"$lng_name\" --query \"localNetworkAddressSpace.addressPrefixes\" -o tsv" "${OUTPUT_DIR}/lng_prefixes_tsv_${sub}_${lng_rg}_${lng_name}.txt" "${OUTPUT_DIR}/lng_prefixes_tsv_${sub}_${lng_rg}_${lng_name}.err" "$DISCOVERY_TIMEOUT" "Getting address prefixes for local network gateway $lng_name (TSV)"
                            
                            if [ -s "${OUTPUT_DIR}/lng_prefixes_tsv_${sub}_${lng_rg}_${lng_name}.txt" ]; then
                                while IFS= read -r prefix || [ -n "$prefix" ]; do
                                    # Skip empty lines
                                    [ -z "$prefix" ] && continue
                                    
                                    # Add to on-premises networks
                                    echo "${sub}|${rg}|${prefix}|from_vpn_connection_${conn_name}_${conn_status}" >> "${OUTPUT_DIR}/onprem_networks.txt"
                                    log "Found on-premises network: $prefix from VPN connection $conn_name (status: $conn_status)"
                                done < "${OUTPUT_DIR}/lng_prefixes_tsv_${sub}_${lng_rg}_${lng_name}.txt"
                            fi
                        fi
                    done < "${OUTPUT_DIR}/vpn_connections_tsv_${sub}_${rg}_${gw_name}.txt"
                fi
            fi
        fi
    done < "${OUTPUT_DIR}/gateways.txt"
    
    # Method 3: Look for ExpressRoute circuit address prefixes
    while IFS='|' read -r sub rg er_name er_id er_type er_state er_sp_state other || [ -n "$sub" ]; do
        # Skip non-ExpressRoute and empty lines
        [ -z "$sub" ] || [ -z "$rg" ] || [ -z "$er_name" ] || [ "$er_type" != "ExpressRoute" ] && continue
        
        # Set subscription context
        run_az_command "az account set --subscription \"$sub\"" "${OUTPUT_DIR}/er_peers_account_set_${sub}.log" "${OUTPUT_DIR}/er_peers_account_set_${sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for ExpressRoute peering analysis ($sub)"
        
        if [ ! -s "${OUTPUT_DIR}/er_peers_account_set_${sub}.log" ] && [ -s "${OUTPUT_DIR}/er_peers_account_set_${sub}.err" ]; then
            log_warning "Failed to set subscription context for $sub, skipping ExpressRoute peering analysis"
            continue
        fi
        
        # Get ExpressRoute peerings
        run_az_command "az network express-route peering list --resource-group \"$rg\" --circuit-name \"$er_name\" --query \"[?peeringType=='AzurePrivatePeering'].{name:name, peeringType:peeringType, microsoftPeeringConfig:microsoftPeeringConfig}\" -o json" "${OUTPUT_DIR}/er_peerings_${sub}_${rg}_${er_name}.json" "${OUTPUT_DIR}/er_peerings_${sub}_${rg}_${er_name}.err" "$DISCOVERY_TIMEOUT" "Listing ExpressRoute peerings for circuit $er_name"
        
        if [ -s "${OUTPUT_DIR}/er_peerings_${sub}_${rg}_${er_name}.json" ]; then
            if [ "$JQ_AVAILABLE" = true ]; then
                # Parse with jq
                if jq -e '.[] | select(.microsoftPeeringConfig != null) | .microsoftPeeringConfig.advertisedPublicPrefixes' "${OUTPUT_DIR}/er_peerings_${sub}_${rg}_${er_name}.json" >/dev/null 2>&1; then
                    # Extract prefixes using jq
                    jq -r '.[] | select(.microsoftPeeringConfig != null) | .microsoftPeeringConfig.advertisedPublicPrefixes[]' "${OUTPUT_DIR}/er_peerings_${sub}_${rg}_${er_name}.json" 2>/dev/null | while read -r prefix; do
                        # Skip empty lines
                        [ -z "$prefix" ] && continue
                        
                        # Add to on-premises networks
                        echo "${sub}|${rg}|${prefix}|from_expressroute_${er_name}" >> "${OUTPUT_DIR}/onprem_networks.txt"
                        log "Found on-premises network: $prefix from ExpressRoute circuit $er_name"
                    done
                else
                    # Fallback to connection-specific prefixes
                    run_az_command "az network express-route list-route-tables --resource-group \"$rg\" --name \"$er_name\" --peering-name \"AzurePrivatePeering\" --path \"primary\" -o json" "${OUTPUT_DIR}/er_routes_${sub}_${rg}_${er_name}.json" "${OUTPUT_DIR}/er_routes_${sub}_${rg}_${er_name}.err" "$DISCOVERY_TIMEOUT" "Listing ExpressRoute routes for circuit $er_name"
                    
                    if [ -s "${OUTPUT_DIR}/er_routes_${sub}_${rg}_${er_name}.json" ]; then
                        jq -r '.[] | select(.path == "Primary" or .path == "primary") | .network' "${OUTPUT_DIR}/er_routes_${sub}_${rg}_${er_name}.json" 2>/dev/null | while read -r prefix; do
                            # Skip empty lines
                            [ -z "$prefix" ] && continue
                            
                            # Add to on-premises networks
                            echo "${sub}|${rg}|${prefix}|from_expressroute_route_${er_name}" >> "${OUTPUT_DIR}/onprem_networks.txt"
                            log "Found on-premises network: $prefix from ExpressRoute route for circuit $er_name"
                        done
                    fi
                fi
            else
                # Fallback parsing without jq
                # Try to extract prefixes from Microsoft peering config
                if grep -q '"advertisedPublicPrefixes"' "${OUTPUT_DIR}/er_peerings_${sub}_${rg}_${er_name}.json"; then
                    grep -o '"advertisedPublicPrefixes": *\[[^]]*\]' "${OUTPUT_DIR}/er_peerings_${sub}_${rg}_${er_name}.json" | grep -o '"[^"]*"' | sed 's/"//g' | while read -r prefix; do
                        # Skip empty lines
                        [ -z "$prefix" ] && continue
                        
                        # Add to on-premises networks
                        echo "${sub}|${rg}|${prefix}|from_expressroute_${er_name}" >> "${OUTPUT_DIR}/onprem_networks.txt"
                        log "Found on-premises network: $prefix from ExpressRoute circuit $er_name"
                    done
                else
                    # Fallback to connection-specific prefixes
                    run_az_command "az network express-route list-route-tables --resource-group \"$rg\" --name \"$er_name\" --peering-name \"AzurePrivatePeering\" --path \"primary\" --query \"[].network\" -o tsv" "${OUTPUT_DIR}/er_routes_tsv_${sub}_${rg}_${er_name}.txt" "${OUTPUT_DIR}/er_routes_tsv_${sub}_${rg}_${er_name}.err" "$DISCOVERY_TIMEOUT" "Listing ExpressRoute routes for circuit $er_name (TSV)"
                    
                    if [ -s "${OUTPUT_DIR}/er_routes_tsv_${sub}_${rg}_${er_name}.txt" ]; then
                        while IFS= read -r prefix || [ -n "$prefix" ]; do
                            # Skip empty lines
                            [ -z "$prefix" ] && continue
                            
                            # Add to on-premises networks
                            echo "${sub}|${rg}|${prefix}|from_expressroute_route_${er_name}" >> "${OUTPUT_DIR}/onprem_networks.txt"
                            log "Found on-premises network: $prefix from ExpressRoute route for circuit $er_name"
                        done < "${OUTPUT_DIR}/er_routes_tsv_${sub}_${rg}_${er_name}.txt"
                    fi
                fi
            fi
        fi
    done < "${OUTPUT_DIR}/gateways.txt"
    
    # Method 4: Add custom on-premises network definitions if available
    if [ ${#ONPREM_NETWORKS[@]} -gt 0 ]; then
        log "Adding custom on-premises networks"
        for prefix in "${ONPREM_NETWORKS[@]}"; do
            echo "custom|custom|${prefix}|custom_defined" >> "${OUTPUT_DIR}/onprem_networks.txt"
            log "Added custom on-premises network: $prefix"
        done
    fi
    
    # If on-premises resource file exists, use it to detect networks
    if [ -f "$ONPREM_RESOURCES_FILE" ]; then
        log "Reading on-premises resources from $ONPREM_RESOURCES_FILE"
        grep -v "^#" "$ONPREM_RESOURCES_FILE" | while IFS='|' read -r onprem_name onprem_type onprem_address onprem_port; do
            # Skip empty lines or lines with missing fields
            [ -z "$onprem_name" ] || [ -z "$onprem_address" ] && continue
            
            # Is this an IP address or hostname?
            if [[ "$onprem_address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                # IP address - convert to /32 prefix
                echo "custom|custom|${onprem_address}/32|from_onprem_resources_file" >> "${OUTPUT_DIR}/onprem_networks.txt"
                log "Added on-premises network from resources file: ${onprem_address}/32 (${onprem_name})"
            elif [[ "$onprem_address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                # It's already a network prefix
                echo "custom|custom|${onprem_address}|from_onprem_resources_file" >> "${OUTPUT_DIR}/onprem_networks.txt"
                log "Added on-premises network from resources file: ${onprem_address} (${onprem_name})"
            fi
        done
    else
        log_debug "On-premises resources file $ONPREM_RESOURCES_FILE not found, creating an empty template."
        # Create an empty onprem_resources.txt template if it doesn't exist
        if [ ! -f "${OUTPUT_DIR}/onprem_resources.txt" ]; then
            cat > "${OUTPUT_DIR}/onprem_resources.txt" << EOF
# On-premises resources file
# Format: name|type|address|port
# Example:
# sqlserver1|SQL|10.10.10.10|1433
# oracle1|Oracle|db.example.com|1521
# san1|Storage|10.20.30.40|445
EOF
        fi
    fi
    
    # Remove duplicates if any
    if [ -s "${OUTPUT_DIR}/onprem_networks.txt" ]; then
        sort -u -t '|' -k3,3 "${OUTPUT_DIR}/onprem_networks.txt" > "${OUTPUT_DIR}/onprem_networks_unique.txt"
        mv "${OUTPUT_DIR}/onprem_networks_unique.txt" "${OUTPUT_DIR}/onprem_networks.txt"
    fi
    
    # Count discovered on-premises networks
    if [ -s "${OUTPUT_DIR}/onprem_networks.txt" ]; then
        onprem_count=$(wc -l < "${OUTPUT_DIR}/onprem_networks.txt" | tr -d ' ')
        log_success "Discovered $onprem_count on-premises networks."
    else
        log_warning "No on-premises networks found. If you need to test connectivity to on-premises, please add them manually using --onprem-networks or create an on-premises resources file."
    fi
}