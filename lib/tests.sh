#!/bin/bash

TEST_POD_IMAGE="netsentry.azurecr.io/netsentry:latest"

# Function to check if Network Watcher is available with debug output
check_network_watcher_availability() {
    log "Checking Network Watcher availability..."
    
    # Get the first available subscription
    local first_sub=""
    if [ -s "${OUTPUT_DIR}/subscriptions.txt" ]; then
        first_sub=$(head -1 "${OUTPUT_DIR}/subscriptions.txt" | tr -d ' \t\r\n')
    fi
    
    # Check if we have a subscription to work with
    if [ -z "$first_sub" ]; then
        log_error "No subscriptions available to check Network Watcher"
        return 1
    fi
    
    # Check if Network Watcher is enabled
    run_az_command "az account set --subscription \"$first_sub\"" "${OUTPUT_DIR}/nw_account_set.log" "${OUTPUT_DIR}/nw_account_set.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for Network Watcher check"
    
    if [ ! -s "${OUTPUT_DIR}/nw_account_set.log" ] && [ -s "${OUTPUT_DIR}/nw_account_set.err" ]; then
        log_error "Failed to set subscription context for Network Watcher check"
        return 1
    fi
    
    # Try to list Network Watchers
    run_az_command "az network watcher list --query \"[].id\" -o tsv" "${OUTPUT_DIR}/network_watchers.txt" "${OUTPUT_DIR}/network_watchers.err" "$DISCOVERY_TIMEOUT" "Listing Network Watchers"
    
    if [ -s "${OUTPUT_DIR}/network_watchers.txt" ]; then
        log_success "Network Watcher is available."
        return 0
    else
        log_error "Network Watcher is not available in this subscription. Please enable Network Watcher."
        
        # Try to list all regions and suggest enabling Network Watcher
        run_az_command "az account list-locations --query \"[].name\" -o tsv" "${OUTPUT_DIR}/azure_regions.txt" "${OUTPUT_DIR}/azure_regions.err" "$DISCOVERY_TIMEOUT" "Listing Azure regions"
        
        if [ -s "${OUTPUT_DIR}/azure_regions.txt" ]; then
            log "To enable Network Watcher, run the following commands for each region:"
            head -5 "${OUTPUT_DIR}/azure_regions.txt" | while read -r region; do
                echo "az network watcher configure --resource-group NetworkWatcherRG --locations $region --enabled true"
            done
            log "... (repeat for other regions as needed)"
        fi
        
        return 1
    fi
}

# Function to test connectivity using Network Watcher with debug output
test_connectivity() {
    local source_id="$1"
    local dest_address="$2"
    local dest_port="$3"
    local protocol="${4:-Tcp}"
    local source_type="$5"
    local dest_type="$6"
    local test_name="$7"
    
    log_test_result "Connectivity - $test_name" "RUNNING" "Testing connectivity from $source_type to $dest_type" "NetworkWatcher" "$source_type" "$dest_type"
    
    # Set subscription to source resource's subscription
    local source_sub=$(echo "$source_id" | awk -F'/' '{print $3}')
    if [ -z "$source_sub" ]; then
        log_test_result "Connectivity - $test_name" "SKIPPED" "Invalid source ID format" "NetworkWatcher" "$source_type" "$dest_type"
        return 1
    fi
    
    run_az_command "az account set --subscription \"$source_sub\"" "${OUTPUT_DIR}/conn_account_set_${test_name}.log" "${OUTPUT_DIR}/conn_account_set_${test_name}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for connectivity test ($test_name)"
    
    if [ ! -s "${OUTPUT_DIR}/conn_account_set_${test_name}.log" ] && [ -s "${OUTPUT_DIR}/conn_account_set_${test_name}.err" ]; then
        log_test_result "Connectivity - $test_name" "SKIPPED" "Failed to set subscription context" "NetworkWatcher" "$source_type" "$dest_type"
        return 1
    fi
    
    # Run Network Watcher connectivity test
    log "Running Network Watcher connectivity test from $source_type to $dest_type ($dest_address:$dest_port)"
    run_az_command "az network watcher test-connectivity --source-resource \"$source_id\" --dest-address \"$dest_address\" --dest-port \"$dest_port\" --protocol \"$protocol\" -o json" "${OUTPUT_DIR}/conn_test_${test_name}.json" "${OUTPUT_DIR}/conn_test_${test_name}.err" "$TIMEOUT_SECONDS" "Network Watcher connectivity test ($test_name)"
    
    local temp_output="${OUTPUT_DIR}/conn_test_${test_name}.json"
    if [ ! -s "$temp_output" ]; then
        log_test_result "Connectivity - $test_name" "FAILED" "Network Watcher test failed - no output returned" "NetworkWatcher" "$source_type" "$dest_type"
        return 1
    fi
    
    # Parse results - with fallbacks for if jq is not available
    local connection_status=""
    local avg_latency=""
    local min_latency=""
    local max_latency=""
    local probes_sent=""
    local probes_succeeded=""
    local hops_info=""
    
    if [ "$JQ_AVAILABLE" = true ]; then
        connection_status=$(jq -r '.connectionStatus' "$temp_output" 2>/dev/null)
        avg_latency=$(jq -r '.avgLatencyInMs' "$temp_output" 2>/dev/null)
        min_latency=$(jq -r '.minLatencyInMs' "$temp_output" 2>/dev/null)
        max_latency=$(jq -r '.maxLatencyInMs' "$temp_output" 2>/dev/null)
        probes_sent=$(jq -r '.probesSent' "$temp_output" 2>/dev/null)
        probes_succeeded=$(jq -r '.probesSucceeded' "$temp_output" 2>/dev/null)
        
        # Get hops information if available
        if jq -e '.hops' "$temp_output" > /dev/null 2>&1; then
            hops_info=" - Network path: $(jq -r '.hops | map(.address) | join(" -> ")' "$temp_output" 2>/dev/null)"
        fi
    else
        # Fallback parsing without jq
        connection_status=$(grep -o '"connectionStatus": *"[^"]*"' "$temp_output" | head -1 | sed 's/"connectionStatus": *"\(.*\)"/\1/')
        avg_latency=$(grep -o '"avgLatencyInMs": *[0-9.]*' "$temp_output" | head -1 | sed 's/"avgLatencyInMs": *\(.*\)/\1/')
        min_latency=$(grep -o '"minLatencyInMs": *[0-9.]*' "$temp_output" | head -1 | sed 's/"minLatencyInMs": *\(.*\)/\1/')
        max_latency=$(grep -o '"maxLatencyInMs": *[0-9.]*' "$temp_output" | head -1 | sed 's/"maxLatencyInMs": *\(.*\)/\1/')
        probes_sent=$(grep -o '"probesSent": *[0-9]*' "$temp_output" | head -1 | sed 's/"probesSent": *\(.*\)/\1/')
        probes_succeeded=$(grep -o '"probesSucceeded": *[0-9]*' "$temp_output" | head -1 | sed 's/"probesSucceeded": *\(.*\)/\1/')
        
        # Basic hops information - this won't be as nice as the jq version
        if grep -q '"hops": *\[' "$temp_output"; then
            hops_addresses=$(grep -o '"address": *"[^"]*"' "$temp_output" | sed 's/"address": *"\(.*\)"/\1/' | tr '\n' ' ' | sed 's/ / -> /g')
            hops_info=" - Network path: $hops_addresses"
        fi
    fi
    
   # Default values if parsing failed
    [ -z "$connection_status" ] && connection_status="Unknown"
    [ -z "$avg_latency" ] || [ "$avg_latency" = "null" ] && avg_latency="N/A"
    [ -z "$min_latency" ] || [ "$min_latency" = "null" ] && min_latency="N/A"
    [ -z "$max_latency" ] || [ "$max_latency" = "null" ] && max_latency="N/A"
    [ -z "$probes_sent" ] || [ "$probes_sent" = "null" ] && probes_sent="0"
    [ -z "$probes_succeeded" ] || [ "$probes_succeeded" = "null" ] && probes_succeeded="0"
    
    local latency_info=""
    if [ "$avg_latency" != "N/A" ]; then
        if [ -n "$probes_failed" ] && [ "$probes_failed" != "null" ]; then
        probes_succeeded=$((probes_sent - probes_failed))
        fi
        latency_info=" (Avg: ${avg_latency}ms, Min: ${min_latency}ms, Max: ${max_latency}ms, $probes_succeeded/$probes_sent probes succeeded)"
    fi
    
    if [ "$connection_status" = "Reachable" ]; then
        log_test_result "Connectivity - $test_name" "PASSED" "Connection from $source_type to $dest_type is reachable$latency_info" "NetworkWatcher" "$source_type" "$dest_type"
        return 0
    else
        log_test_result "Connectivity - $test_name" "FAILED" "Connection from $source_type to $dest_type is NOT reachable$hops_info" "NetworkWatcher" "$source_type" "$dest_type"
        return 1
    fi
}

# Function to test VM to VM connectivity
test_vm_to_vm_connectivity() {
    log "Testing VM to VM connectivity..."
    
    if [ ! -s "${OUTPUT_DIR}/vms.txt" ]; then
        log_warning "No VMs found, skipping VM to VM connectivity tests."
        return
    fi
    
    # Get count of VMs
    vm_count=$(wc -l < "${OUTPUT_DIR}/vms.txt" | tr -d ' ')
    if [ "$vm_count" -lt 2 ]; then
        log_warning "Only $vm_count VM found, need at least 2 for VM-to-VM connectivity tests."
        return
    fi
    
    # Create array of VMs
    readarray -t vm_array < "${OUTPUT_DIR}/vms.txt"
    
    # Test connectivity between VMs in different VNets
    for ((i=0; i<${#vm_array[@]}; i++)); do
        # Get source VM info
        IFS='|' read -r src_vm_sub src_vm_rg src_vm_name src_vm_id src_vm_private_ips src_vm_public_ips src_vm_vnet src_vm_subnet src_vm_os_type <<< "${vm_array[$i]}"
        
        # Skip if VM ID is missing
        [ -z "$src_vm_id" ] && continue
        
        # Only test first 3 VMs to avoid too many tests
        test_count=0
        
        for ((j=0; j<${#vm_array[@]}; j++)); do
            # Skip self-test
            [ "$i" -eq "$j" ] && continue
            
            # Get destination VM info
            IFS='|' read -r dst_vm_sub dst_vm_rg dst_vm_name dst_vm_id dst_vm_private_ips dst_vm_public_ips dst_vm_vnet dst_vm_subnet dst_vm_os_type <<< "${vm_array[$j]}"
            
            # Skip if VM ID is missing
            [ -z "$dst_vm_id" ] && continue
            
            # Only test VMs in different VNets for more valuable tests
            if [ "$src_vm_vnet" != "$dst_vm_vnet" ]; then
                # Test connectivity
                test_connectivity "$src_vm_id" "$dst_vm_private_ips" "3389" "Tcp" "VM:$src_vm_name" "VM:$dst_vm_name" "${src_vm_name}_to_${dst_vm_name}"
                
                # Increment test count
                ((test_count++))
                
                # Limit number of tests per VM
                [ "$test_count" -ge 2 ] && break
            fi
        done
    done
}

# Function to test VM to SQL connectivity
test_vm_to_sql_connectivity() {
    log "Testing VM to SQL Server connectivity..."
    
    if [ ! -s "${OUTPUT_DIR}/vms.txt" ] || [ ! -s "${OUTPUT_DIR}/sql_servers.txt" ]; then
        log_warning "Either VMs or SQL servers not found, skipping VM to SQL connectivity tests."
        return
    fi
    
    # For each VM, test connectivity to each SQL server
    while IFS='|' read -r vm_sub vm_rg vm_name vm_id vm_private_ips vm_public_ips vm_vnet vm_subnet vm_os_type; do
        # Skip if VM ID is missing
        [ -z "$vm_id" ] && continue
        
        # For each SQL server
        while IFS='|' read -r sql_sub sql_rg sql_name sql_id sql_fqdn sql_version sql_private_ep; do
            # Skip if SQL FQDN is missing or unknown
            [ -z "$sql_fqdn" ] || [ "$sql_fqdn" = "unknown" ] && continue
            
            # Test connectivity
            test_connectivity "$vm_id" "$sql_fqdn" "1433" "Tcp" "VM:$vm_name" "SQL:$sql_name" "${vm_name}_to_${sql_name}"
        done < "${OUTPUT_DIR}/sql_servers.txt"
    done < "${OUTPUT_DIR}/vms.txt"
}

# Function to test VM to Storage connectivity
test_vm_to_storage_connectivity() {
    log "Testing VM to Storage Account connectivity..."
    
    if [ ! -s "${OUTPUT_DIR}/vms.txt" ] || [ ! -s "${OUTPUT_DIR}/storage_accounts.txt" ]; then
        log_warning "Either VMs or Storage accounts not found, skipping VM to Storage connectivity tests."
        return
    fi
    
    # For each VM, test connectivity to each Storage account
    while IFS='|' read -r vm_sub vm_rg vm_name vm_id vm_private_ips vm_public_ips vm_vnet vm_subnet vm_os_type; do
        # Skip if VM ID is missing
        [ -z "$vm_id" ] && continue
        
        # For each Storage account
        while IFS='|' read -r sa_sub sa_rg sa_name sa_id sa_location sa_private_ep sa_is_hns sa_hostname; do
            # Skip if Storage account name is missing
            [ -z "$sa_name" ] && continue
            
            # Use blob endpoint hostname
            if [ -z "$sa_hostname" ] || [ "$sa_hostname" = "unknown" ]; then
                sa_hostname="${sa_name}.blob.core.windows.net"
            fi
            
            # Test connectivity
            test_connectivity "$vm_id" "$sa_hostname" "443" "Tcp" "VM:$vm_name" "Storage:$sa_name" "${vm_name}_to_${sa_name}"
        done < "${OUTPUT_DIR}/storage_accounts.txt"
    done < "${OUTPUT_DIR}/vms.txt"
}

# Function to test VM to Service Bus connectivity
test_vm_to_servicebus_connectivity() {
    log "Testing VM to Service Bus connectivity..."
    
    if [ ! -s "${OUTPUT_DIR}/vms.txt" ] || [ ! -s "${OUTPUT_DIR}/servicebus.txt" ]; then
        log_warning "Either VMs or Service Bus namespaces not found, skipping VM to Service Bus connectivity tests."
        return
    fi
    
    # For each VM, test connectivity to each Service Bus namespace
    while IFS='|' read -r vm_sub vm_rg vm_name vm_id vm_private_ips vm_public_ips vm_vnet vm_subnet vm_os_type; do
        # Skip if VM ID is missing
        [ -z "$vm_id" ] && continue
        
        # For each Service Bus namespace
        while IFS='|' read -r sb_sub sb_rg sb_name sb_id sb_fqdn sb_private_ep; do
            # Skip if Service Bus FQDN is missing or unknown
            [ -z "$sb_fqdn" ] || [ "$sb_fqdn" = "unknown" ] && continue
            
            # Test HTTPS connectivity (port 443)
            test_connectivity "$vm_id" "$sb_fqdn" "443" "Tcp" "VM:$vm_name" "ServiceBus:$sb_name" "${vm_name}_to_${sb_name}_https"
            
            # Test AMQP connectivity (port 5671)
            test_connectivity "$vm_id" "$sb_fqdn" "5671" "Tcp" "VM:$vm_name" "ServiceBus:$sb_name" "${vm_name}_to_${sb_name}_amqp"
        done < "${OUTPUT_DIR}/servicebus.txt"
    done < "${OUTPUT_DIR}/vms.txt"
}

# Function to test VM to Event Hub connectivity
test_vm_to_eventhub_connectivity() {
    log "Testing VM to Event Hub connectivity..."
    
    if [ ! -s "${OUTPUT_DIR}/vms.txt" ] || [ ! -s "${OUTPUT_DIR}/eventhub.txt" ]; then
        log_warning "Either VMs or Event Hub namespaces not found, skipping VM to Event Hub connectivity tests."
        return
    fi
    
    # For each VM, test connectivity to each Event Hub namespace
    while IFS='|' read -r vm_sub vm_rg vm_name vm_id vm_private_ips vm_public_ips vm_vnet vm_subnet vm_os_type; do
        # Skip if VM ID is missing
        [ -z "$vm_id" ] && continue
        
        # For each Event Hub namespace
        while IFS='|' read -r eh_sub eh_rg eh_name eh_id eh_fqdn eh_private_ep; do
            # Skip if Event Hub FQDN is missing or unknown
            [ -z "$eh_fqdn" ] || [ "$eh_fqdn" = "unknown" ] && continue
            
            # Test HTTPS connectivity (port 443)
            test_connectivity "$vm_id" "$eh_fqdn" "443" "Tcp" "VM:$vm_name" "EventHub:$eh_name" "${vm_name}_to_${eh_name}_https"
            
            # Test AMQP connectivity (port 5671)
            test_connectivity "$vm_id" "$eh_fqdn" "5671" "Tcp" "VM:$vm_name" "EventHub:$eh_name" "${vm_name}_to_${eh_name}_amqp"
        done < "${OUTPUT_DIR}/eventhub.txt"
    done < "${OUTPUT_DIR}/vms.txt"
}

# Function to test VM to Cosmos DB connectivity
test_vm_to_cosmosdb_connectivity() {
    log "Testing VM to Cosmos DB connectivity..."
    
    if [ ! -s "${OUTPUT_DIR}/vms.txt" ] || [ ! -s "${OUTPUT_DIR}/cosmosdb.txt" ]; then
        log_warning "Either VMs or Cosmos DB accounts not found, skipping VM to Cosmos DB connectivity tests."
        return
    fi
    
    # For each VM, test connectivity to each Cosmos DB account
    while IFS='|' read -r vm_sub vm_rg vm_name vm_id vm_private_ips vm_public_ips vm_vnet vm_subnet vm_os_type; do
        # Skip if VM ID is missing
        [ -z "$vm_id" ] && continue
        
        # For each Cosmos DB account
        while IFS='|' read -r cosmos_sub cosmos_rg cosmos_name cosmos_id cosmos_fqdn cosmos_private_ep; do
            # Skip if Cosmos DB FQDN is missing or unknown
            [ -z "$cosmos_fqdn" ] || [ "$cosmos_fqdn" = "unknown" ] && continue
            
            # Test connectivity
            test_connectivity "$vm_id" "$cosmos_fqdn" "443" "Tcp" "VM:$vm_name" "CosmosDB:$cosmos_name" "${vm_name}_to_${cosmos_name}"
        done < "${OUTPUT_DIR}/cosmosdb.txt"
    done < "${OUTPUT_DIR}/vms.txt"
}

# Function to test VM to on-premises connectivity
test_vm_to_onprem_connectivity() {
    log "Testing VM to on-premises connectivity..."
    
    if [ ! -s "${OUTPUT_DIR}/vms.txt" ] || [ ! -s "${OUTPUT_DIR}/onprem_networks.txt" ]; then
        log_warning "Either VMs or on-premises networks not found, skipping VM to on-premises connectivity tests."
        return
    fi
    
    # Use a sample of VMs (limit to 3)
    head -3 "${OUTPUT_DIR}/vms.txt" > "${OUTPUT_DIR}/vm_sample.txt"
    
    # For each VM, test connectivity to each on-premises network
    while IFS='|' read -r vm_sub vm_rg vm_name vm_id vm_private_ips vm_public_ips vm_vnet vm_subnet vm_os_type; do
        # Skip if VM ID is missing
        [ -z "$vm_id" ] && continue
        
        # For each on-premises network
        while IFS='|' read -r onprem_sub onprem_rg onprem_prefix onprem_source; do
            # Skip if prefix is missing
            [ -z "$onprem_prefix" ] && continue
            
            # Extract usable IP from prefix for testing
            ip_network=$(echo "$onprem_prefix" | cut -d'/' -f1)
            ip_parts=(${ip_network//./ })
            test_ip="${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}.1"
            
            # Test connectivity
            test_connectivity "$vm_id" "$test_ip" "80" "Tcp" "VM:$vm_name" "OnPrem:$onprem_prefix" "${vm_name}_to_onprem_${ip_network}"
        done < "${OUTPUT_DIR}/onprem_networks.txt"
    done < "${OUTPUT_DIR}/vm_sample.txt"
    
    # Also test on-premises resources from onprem_resources.txt if available
    if [ -f "${OUTPUT_DIR}/onprem_resources.txt" ]; then
        while IFS='|' read -r vm_sub vm_rg vm_name vm_id vm_private_ips vm_public_ips vm_vnet vm_subnet vm_os_type; do
            # Skip if VM ID is missing
            [ -z "$vm_id" ] && continue
            
            # Test each configured on-premises resource
            grep -v "^#" "${OUTPUT_DIR}/onprem_resources.txt" | while IFS='|' read -r onprem_name onprem_type onprem_address onprem_port; do
                # Skip if name, address, or port is missing
                [ -z "$onprem_name" ] || [ -z "$onprem_address" ] || [ -z "$onprem_port" ] && continue
                
                # Test connectivity
                test_connectivity "$vm_id" "$onprem_address" "$onprem_port" "Tcp" "VM:$vm_name" "OnPrem:$onprem_name" "${vm_name}_to_onprem_${onprem_name}"
            done
        done < "${OUTPUT_DIR}/vm_sample.txt"
    fi
}


# Function to test custom endpoint connectivity
test_custom_endpoint_connectivity() {
    log "Testing connectivity to custom endpoints..."
    
    # Check if we have any custom endpoints to test
    if [ ${#CUSTOM_ENDPOINTS[@]} -eq 0 ] && [ ! -s "${OUTPUT_DIR}/custom_endpoints.txt" ]; then
        log_warning "No custom endpoints specified, skipping custom endpoint connectivity tests."
        return
    fi
    
    # Use VMs as source resources
    if [ -s "${OUTPUT_DIR}/vms.txt" ]; then
        # Create a sample of VMs to test
        if [[ "$source" == "all" ]]; then
            # If testing all VMs, limit to first 3
            head -3 "${OUTPUT_DIR}/vms.txt" > "${OUTPUT_DIR}/vm_custom_sample.txt"
        else
            # If a specific VM was requested, only use that one
            grep "|${source}|" "${OUTPUT_DIR}/vms.txt" > "${OUTPUT_DIR}/vm_custom_sample.txt"
            
            # If the grep failed, log a warning and return
            if [ ! -s "${OUTPUT_DIR}/vm_custom_sample.txt" ]; then
                log_warning "Specified VM '$source' not found. Skipping custom endpoint connectivity tests."
                return
            fi
        fi
        
        # Initialize executed tests file if it doesn't exist
        EXECUTED_TESTS_FILE="${OUTPUT_DIR}/executed_tests.txt"
        touch "$EXECUTED_TESTS_FILE"
        
        while IFS='|' read -r vm_sub vm_rg vm_name vm_id vm_private_ips vm_public_ips vm_vnet vm_subnet vm_os_type; do
            # Skip if VM ID is missing
            [ -z "$vm_id" ] && continue
            
            # Check if a specific destination was requested
            if [[ "$destination" != "all" && "$destination" == *":"* ]]; then
                # Parse the specific destination
                host=$(echo "$destination" | cut -d ':' -f1)
                port=$(echo "$destination" | cut -d ':' -f2)
                desc=$(echo "$destination" | cut -d ':' -f3 || echo "$host")
                
                # Create unique test ID for deduplication
                test_id="VM:${vm_name}_to_Custom:${host}:${port}"
                
                # Check if this test has already been executed
                if ! grep -q "^$test_id$" "$EXECUTED_TESTS_FILE"; then
                    # Mark as executed
                    echo "$test_id" >> "$EXECUTED_TESTS_FILE"
                    
                    # Test only the specific endpoint
                    log "Testing specific endpoint: $host:$port from VM: $vm_name"
                    test_connectivity "$vm_id" "$host" "$port" "Tcp" "VM:$vm_name" "Custom:$endpoint_host" "${vm_name}_to_${desc}"
                else
                    log "Skipping duplicate test: $test_id"
                fi
            else
                # For "all" destination - test all endpoints in CUSTOM_ENDPOINTS array
                for custom_endpoint in "${CUSTOM_ENDPOINTS[@]}"; do
                    # Parse endpoint components
                    IFS=':' read -r endpoint_host endpoint_port endpoint_desc endpoint_rg endpoint_sub <<< "$custom_endpoint"
                    
                    # Skip if host or port is missing
                    [ -z "$endpoint_host" ] || [ -z "$endpoint_port" ] && continue
                    
                    # Set default description if not provided
                    [ -z "$endpoint_desc" ] && endpoint_desc="$endpoint_host"
                    
                    # Create unique test ID for deduplication
                    test_id="VM:${vm_name}_to_Custom:${endpoint_host}:${endpoint_port}"
                    
                    # Check if this test has already been executed
                    if ! grep -q "^$test_id$" "$EXECUTED_TESTS_FILE"; then
                        # Mark as executed
                        echo "$test_id" >> "$EXECUTED_TESTS_FILE"
                        
                        # Test connectivity
                        test_connectivity "$vm_id" "$endpoint_host" "$endpoint_port" "Tcp" "VM:$vm_name" "Custom:$endpoint_host" "${vm_name}_to_${endpoint_desc}"
                    else
                        log "Skipping duplicate test: $test_id"
                    fi
                done
                
                # Also check custom_endpoints.txt file if it exists
                if [ -s "${OUTPUT_DIR}/custom_endpoints.txt" ]; then
                    while IFS=':' read -r endpoint_host endpoint_port endpoint_desc rest; do
                        # Skip if host or port is missing
                        [ -z "$endpoint_host" ] || [ -z "$endpoint_port" ] && continue
                        
                        # Set default description if not provided
                        [ -z "$endpoint_desc" ] && endpoint_desc="$endpoint_host"
                        
                        # Create unique test ID for deduplication
                        test_id="VM:${vm_name}_to_Custom:${endpoint_host}:${endpoint_port}"
                        
                        # Check if this test has already been executed
                        if ! grep -q "^$test_id$" "$EXECUTED_TESTS_FILE"; then
                            # Mark as executed
                            echo "$test_id" >> "$EXECUTED_TESTS_FILE"
                            
                            # Test connectivity
                            test_connectivity "$vm_id" "$endpoint_host" "$endpoint_port" "Tcp" "VM:$vm_name" "Custom:$endpoint_host" "${vm_name}_to_${endpoint_desc}"
                        else
                            log "Skipping duplicate test: $test_id"
                        fi
                    done < "${OUTPUT_DIR}/custom_endpoints.txt"
                fi
            fi
        done < "${OUTPUT_DIR}/vm_custom_sample.txt"
    else
        log_warning "No VMs found to use as source for custom endpoint tests."
    fi
}
test_aks_to_sql_connectivity() {
    log "Testing AKS to SQL Server connectivity..."
    
    if [ ! -s "${OUTPUT_DIR}/aks_clusters.txt" ] || [ ! -s "${OUTPUT_DIR}/sql_servers.txt" ]; then
        log_warning "Either AKS clusters or SQL servers not found, skipping AKS to SQL connectivity tests."
        return
    fi
    
    # For each AKS cluster, test connectivity to each SQL server
    while IFS='|' read -r aks_sub aks_rg aks_name aks_node_rg aks_fqdn aks_api_server aks_network_plugin; do
        # Get credentials for the cluster
        log "Getting credentials for AKS cluster $aks_name"
        run_az_command "az account set --subscription \"$aks_sub\"" "${OUTPUT_DIR}/aks_sql_account_set_${aks_sub}.log" "${OUTPUT_DIR}/aks_sql_account_set_${aks_sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for AKS to SQL tests ($aks_sub)"
        
        run_az_command "az aks get-credentials --resource-group \"$aks_rg\" --name \"$aks_name\" --overwrite-existing" "${OUTPUT_DIR}/aks_sql_credentials_${aks_sub}_${aks_name}.log" "${OUTPUT_DIR}/aks_sql_credentials_${aks_sub}_${aks_name}.err" "$DISCOVERY_TIMEOUT" "Getting AKS credentials for $aks_name"
        
        # Deploy test pod if it doesn't exist
        POD_NAME="connectivity-test-$(echo $aks_name | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c 1-20)"
        
        # Check if pod exists
        POD_EXISTS=$(kubectl get pod $POD_NAME -o name 2>/dev/null)
        
        if [ -z "$POD_EXISTS" ]; then
            kubectl delete pod $POD_NAME --force --grace-period=0 --ignore-not-found=true --wait=false > /dev/null 2>&1
            sleep 5  # Give a moment for deletion to process
            
            log "Creating test pod in AKS cluster $aks_name using pre-built image: $TEST_POD_IMAGE"
            kubectl run $POD_NAME --image=$TEST_POD_IMAGE > "${OUTPUT_DIR}/pod_create_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_create_${aks_name}.err"
            
            # Wait for pod to be ready
            kubectl wait --for=condition=Ready pod/$POD_NAME --timeout=120s > "${OUTPUT_DIR}/pod_wait_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_wait_${aks_name}.err"
        fi
        
        # For each SQL server
        while IFS='|' read -r sql_sub sql_rg sql_name sql_id sql_fqdn sql_version sql_private_ep; do
            # Skip if SQL FQDN is missing or unknown
            [ -z "$sql_fqdn" ] || [ "$sql_fqdn" = "unknown" ] && continue
            
            log "[RUNNING] Connectivity - AKS:$aks_name to SQL:$sql_name"
            
            # Test connectivity with DNS lookup first (continue even if it fails)
            kubectl exec $POD_NAME -- bash -c "echo 'CONNECTIVITY TEST: AKS:$aks_name to SQL:$sql_name' && \
                echo 'DNS LOOKUP:' && (nslookup $sql_fqdn || echo 'DNS resolution failed, trying direct connection tests')" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sql_name}_dns.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sql_name}_dns.err"
            
            # Try curl for timing data if available, otherwise use nc
            kubectl exec $POD_NAME -- bash -c "if command -v curl &> /dev/null; then \
                echo 'CURL TIMING:' && \
                curl -w 'DNS Resolution: %{time_namelookup}s\nTCP Connection: %{time_connect}s\nTLS Handshake: %{time_appconnect}s\nTotal time: %{time_total}s\n' \
                -o /dev/null -s https://$sql_fqdn:1433; \
            else \
                echo 'SQL PORT TEST (1433):' && \
                (time nc -zv -w 10 $sql_fqdn 1433) || echo 'SQL Connection failed'; \
            fi" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sql_name}_port.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sql_name}_port.err"
            
            # Combine logs
            cat "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sql_name}_dns.log" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sql_name}_port.log" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sql_name}.log"
            
            # Check for success with multiple patterns
            CONNECTION_SUCCESS=false
            
            # First check for curl's detailed timing
            if grep -q "TCP Connection:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sql_name}.log"; then
                CONNECTION_SUCCESS=true
                CONNECTION_TIME=$(grep "TCP Connection:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sql_name}.log" | awk '{print $3}' | sed 's/s$//')
                TOTAL_TIME=$(grep "Total time:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sql_name}.log" | awk '{print $3}' | sed 's/s$//')
                
                log_success "Connectivity - AKS:$aks_name to SQL:$sql_name is successful (Connection: ${CONNECTION_TIME}s, Total: ${TOTAL_TIME}s)"
                echo "AKS:$aks_name to SQL:$sql_name - SUCCESS - Connection: ${CONNECTION_TIME}s, Total: ${TOTAL_TIME}s" >> "$SUMMARY_FILE"
            
            # Then check for netcat success patterns
            elif grep -q "Connection to.*1433.*succeeded\|open\|connected" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sql_name}.log"; then
                CONNECTION_SUCCESS=true
                
                # Try to extract timing from time command
                if grep -q "real" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sql_name}.log"; then
                    CONNECTION_TIME=$(grep "real" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sql_name}.log" | head -1 | awk '{print $2}')
                    log_success "Connectivity - AKS:$aks_name to SQL:$sql_name is successful (Connection Time: ${CONNECTION_TIME})"
                    echo "AKS:$aks_name to SQL:$sql_name - SUCCESS - Connection Time: ${CONNECTION_TIME}" >> "$SUMMARY_FILE"
                else
                    log_success "Connectivity - AKS:$aks_name to SQL:$sql_name is successful"
                    echo "AKS:$aks_name to SQL:$sql_name - SUCCESS" >> "$SUMMARY_FILE"
                fi
            else
                log_error "Connectivity - AKS:$aks_name to SQL:$sql_name failed"
                echo "AKS:$aks_name to SQL:$sql_name - FAILED" >> "$SUMMARY_FILE"
            fi
            
        done < "${OUTPUT_DIR}/sql_servers.txt"
        
        # Clean up the test pod
        if [[ "$SKIP_CLEANUP" != "true" ]]; then
            log "Deleting test pod $POD_NAME from AKS cluster $aks_name"
            kubectl delete pod $POD_NAME --wait=true --timeout=30s > "${OUTPUT_DIR}/pod_delete_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_delete_${aks_name}.err"
            sleep 5
            kubectl get pod $POD_NAME --no-headers --ignore-not-found > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                log_warning "Pod $POD_NAME still exists after deletion attempt, forcing deletion"
                kubectl delete pod $POD_NAME --force --grace-period=0 > /dev/null 2>&1
                sleep 3
            fi
        fi
    done < "${OUTPUT_DIR}/aks_clusters.txt"
}

precheck_aks_connectivity() {
    log "Running pre-check for AKS connectivity capabilities..."
    local precheck_passed=true
    local precheck_output_dir="${OUTPUT_DIR}/prechecks"
    
    # Create precheck output directory
    mkdir -p "$precheck_output_dir"
    
    # Step 1: Check Azure CLI authentication
    log "Checking Azure CLI authentication..."
    if ! az account show > "${precheck_output_dir}/az_account.log" 2> "${precheck_output_dir}/az_account.err"; then
        log_error "Azure CLI authentication failed. Please run 'az login' and try again."
        precheck_passed=false
    else
        log_success "Azure CLI authentication verified"
        # Get subscription ID for reference
        SUBSCRIPTION_ID=$(az account show --query id -o tsv)
        log "Using subscription: $SUBSCRIPTION_ID"
    fi
    
    # Step 2: Check if AKS clusters file exists and has content
    log "Checking AKS clusters data..."
    if [ ! -s "${OUTPUT_DIR}/aks_clusters.txt" ]; then
        log_error "AKS clusters file is missing or empty: ${OUTPUT_DIR}/aks_clusters.txt"
        precheck_passed=false
    else
        log_success "Found $(wc -l < ${OUTPUT_DIR}/aks_clusters.txt) AKS clusters to test"
        
        # Step 2.1: Verify access to each AKS cluster
        while IFS='|' read -r aks_sub aks_rg aks_name aks_node_rg aks_fqdn aks_api_server aks_network_plugin; do
            log "Verifying access to AKS cluster: $aks_name in subscription $aks_sub"
            
            # Set subscription context
            if ! run_az_command "az account set --subscription \"$aks_sub\"" \
                "${precheck_output_dir}/aks_sub_set_${aks_sub}.log" \
                "${precheck_output_dir}/aks_sub_set_${aks_sub}.err" \
                "$DISCOVERY_TIMEOUT" "Setting subscription context"; then
                log_error "Failed to set subscription context for $aks_sub"
                precheck_passed=false
                continue
            fi
            
            # Check if we can get the AKS cluster details
            if ! run_az_command "az aks show --resource-group \"$aks_rg\" --name \"$aks_name\"" \
                "${precheck_output_dir}/aks_show_${aks_name}.log" \
                "${precheck_output_dir}/aks_show_${aks_name}.err" \
                "$DISCOVERY_TIMEOUT" "Checking AKS cluster access"; then
                log_error "Cannot access AKS cluster: $aks_name. Check permissions."
                precheck_passed=false
                continue
            fi
            
            # Try to get credentials
            if ! run_az_command "az aks get-credentials --resource-group \"$aks_rg\" --name \"$aks_name\" --overwrite-existing" \
                "${precheck_output_dir}/aks_creds_${aks_name}.log" \
                "${precheck_output_dir}/aks_creds_${aks_name}.err" \
                "$DISCOVERY_TIMEOUT" "Getting AKS credentials"; then
                log_error "Failed to get credentials for AKS cluster: $aks_name"
                precheck_passed=false
                continue
            fi
            
            # Verify kubectl can get cluster info
            log "Checking kubectl connectivity to cluster $aks_name"
            if ! kubectl cluster-info > "${precheck_output_dir}/kubectl_info_${aks_name}.log" 2> "${precheck_output_dir}/kubectl_info_${aks_name}.err"; then
                log_error "kubectl cannot connect to cluster $aks_name. Checking context..."
                # Try with explicit context
                if ! kubectl cluster-info --context="$aks_name" > "${precheck_output_dir}/kubectl_info_context_${aks_name}.log" 2> "${precheck_output_dir}/kubectl_info_context_${aks_name}.err"; then
                    log_error "kubectl cannot access cluster $aks_name even with explicit context. Check credentials."
                    precheck_passed=false
                    continue
                fi
            fi
            
            # Get kubectl context and node info
            kubectl config current-context > "${precheck_output_dir}/kubectl_context_${aks_name}.log" 2> "${precheck_output_dir}/kubectl_context_${aks_name}.err"
            kubectl get nodes --output=wide > "${precheck_output_dir}/kubectl_nodes_${aks_name}.log" 2> "${precheck_output_dir}/kubectl_nodes_${aks_name}.err"
            log_success "kubectl can access cluster $aks_name"
            
            # Verify the test pod image is accessible
            log "Checking test pod image accessibility for $aks_name"
            POD_NAME="precheck-$(echo $aks_name | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c 1-20)"
            
            # Check if the image exists and can be pulled
            log "Attempting to create test pod using image: $TEST_POD_IMAGE"
            if ! kubectl run $POD_NAME --image=$TEST_POD_IMAGE --restart=Never > "${precheck_output_dir}/pod_image_check_${aks_name}.log" 2> "${precheck_output_dir}/pod_image_check_${aks_name}.err"; then
                log_error "Failed to create test pod with image: $TEST_POD_IMAGE in cluster $aks_name"
                kubectl describe pod $POD_NAME > "${precheck_output_dir}/pod_describe_${aks_name}.log" 2>&1 || true
                precheck_passed=false
                # Clean up pod anyway
                kubectl delete pod $POD_NAME --force --grace-period=0 --wait=false > /dev/null 2>&1 || true
                continue
            fi
            
            # Wait for pod to be ready or detect pull issues (max 60 seconds)
            log "Waiting for test pod to become ready..."
            RETRY_COUNT=0
            MAX_RETRIES=12  # 12 * 5 = 60 seconds
            POD_READY=false
            
            while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
                # Check pull status
                PULL_STATUS=$(kubectl get pod $POD_NAME -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
                POD_STATUS=$(kubectl get pod $POD_NAME -o jsonpath='{.status.phase}' 2>/dev/null)
                
                if [[ "$PULL_STATUS" == "ImagePullBackOff" || "$PULL_STATUS" == "ErrImagePull" ]]; then
                    log_error "Image pull failed for $TEST_POD_IMAGE in cluster $aks_name. Status: $PULL_STATUS"
                    kubectl describe pod $POD_NAME > "${precheck_output_dir}/pod_pull_error_${aks_name}.log"
                    precheck_passed=false
                    break
                elif [[ "$POD_STATUS" == "Running" ]]; then
                    log_success "Test pod is running in cluster $aks_name"
                    POD_READY=true
                    break
                fi
                
                RETRY_COUNT=$((RETRY_COUNT+1))
                sleep 5
            done
            
            if [ "$POD_READY" = false ] && [ "$PULL_STATUS" != "ImagePullBackOff" ] && [ "$PULL_STATUS" != "ErrImagePull" ]; then
                log_error "Test pod didn't become ready within timeout. Current status: $POD_STATUS"
                kubectl describe pod $POD_NAME > "${precheck_output_dir}/pod_timeout_${aks_name}.log"
                precheck_passed=false
            fi
            
            # If pod is ready, test command execution
            if [ "$POD_READY" = true ]; then
                log "Testing command execution in pod..."
                # Try executing a simple command
                if ! kubectl exec $POD_NAME -- echo "Precheck command execution test" > "${precheck_output_dir}/pod_exec_${aks_name}.log" 2> "${precheck_output_dir}/pod_exec_${aks_name}.err"; then
                    log_error "Command execution failed in test pod on cluster $aks_name"
                    precheck_passed=false
                else
                    log_success "Command execution successful in test pod on cluster $aks_name"
                    
                    # Test the actual commands we'll need for connectivity tests
                    log "Testing network tools in pod..."
                    if ! kubectl exec $POD_NAME -- bash -c "which nslookup && which nc && which time" > "${precheck_output_dir}/pod_tools_${aks_name}.log" 2> "${precheck_output_dir}/pod_tools_${aks_name}.err"; then
                        log_error "Required network tools missing in test pod on cluster $aks_name"
                        kubectl exec $POD_NAME -- bash -c "ls -la /usr/bin/ | grep -E 'nslookup|nc|time'" >> "${precheck_output_dir}/pod_tools_${aks_name}.log" 2>&1 || true
                        precheck_passed=false
                    else
                        log_success "All required network tools available in test pod on cluster $aks_name"
                    fi
                fi
            fi
            
            # Clean up the precheck pod
            log "Cleaning up test pod..."
            kubectl delete pod $POD_NAME --wait=false --now > /dev/null 2>&1 || true
            log "Removed precheck pod from $aks_name"
        done < "${OUTPUT_DIR}/aks_clusters.txt"
    fi
    
    # Final precheck status
    if [ "$precheck_passed" = true ]; then
        log_success "AKS connectivity precheck PASSED - ready for connectivity tests"
        return 0
    else
        log_error "AKS connectivity precheck FAILED - Review logs in ${precheck_output_dir}"
        return 1
    fi
}
test_aks_to_custom_connectivity() {
    log "Testing AKS to Custom Endpoints connectivity..."
    
    # Check if we have AKS clusters and custom endpoints
    if [ ! -s "${OUTPUT_DIR}/aks_clusters.txt" ]; then
        log_warning "No AKS clusters found, skipping AKS to Custom Endpoints connectivity tests."
        return
    fi
    
    if [ ${#CUSTOM_ENDPOINTS[@]} -eq 0 ] && [ ! -s "${OUTPUT_DIR}/custom_endpoints.txt" ]; then
        log_warning "No custom endpoints specified, skipping AKS to Custom Endpoints connectivity tests."
        return
    fi
    
    # Initialize executed tests file if it doesn't exist
    EXECUTED_TESTS_FILE="${OUTPUT_DIR}/executed_tests.txt"
    touch "$EXECUTED_TESTS_FILE"
    
    # Filter AKS clusters if a specific one was requested
    if [[ "$source" != "all" ]]; then
        # If a specific AKS cluster was requested, only use that one
        grep "|${source}|" "${OUTPUT_DIR}/aks_clusters.txt" > "${OUTPUT_DIR}/aks_clusters_filtered.txt"
        
        # If the grep failed, log a warning and return
        if [ ! -s "${OUTPUT_DIR}/aks_clusters_filtered.txt" ]; then
            log_warning "Specified AKS cluster '$source' not found. Skipping custom endpoint connectivity tests."
            return
        fi
        
        # Use the filtered file for testing
        AKS_CLUSTERS_FILE="${OUTPUT_DIR}/aks_clusters_filtered.txt"
    else
        # Use all AKS clusters
        AKS_CLUSTERS_FILE="${OUTPUT_DIR}/aks_clusters.txt"
    fi
    
    # For each AKS cluster, test connectivity
    while IFS='|' read -r aks_sub aks_rg aks_name aks_node_rg aks_fqdn aks_api_server aks_network_plugin; do
        # Get credentials for the cluster
        log "Getting credentials for AKS cluster $aks_name"
        run_az_command "az account set --subscription \"$aks_sub\"" "${OUTPUT_DIR}/aks_custom_account_set_${aks_sub}.log" "${OUTPUT_DIR}/aks_custom_account_set_${aks_sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for AKS to Custom Endpoints tests ($aks_sub)"
        
        run_az_command "az aks get-credentials --resource-group \"$aks_rg\" --name \"$aks_name\" --overwrite-existing" "${OUTPUT_DIR}/aks_custom_credentials_${aks_sub}_${aks_name}.log" "${OUTPUT_DIR}/aks_custom_credentials_${aks_sub}_${aks_name}.err" "$DISCOVERY_TIMEOUT" "Getting AKS credentials for $aks_name"
        
        # Deploy test pod if it doesn't exist
        POD_NAME="connectivity-test-$(echo $aks_name | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c 1-20)"
        
        # Check if pod exists
        POD_EXISTS=$(kubectl get pod $POD_NAME -o name 2>/dev/null)
        
        if [ -z "$POD_EXISTS" ]; then
            kubectl delete pod $POD_NAME --force --grace-period=0 --ignore-not-found=true --wait=false > /dev/null 2>&1
            sleep 5  # Give a moment for deletion to process
            
            log "Creating test pod in AKS cluster $aks_name using pre-built image: $TEST_POD_IMAGE"
            kubectl run $POD_NAME --image=$TEST_POD_IMAGE > "${OUTPUT_DIR}/pod_create_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_create_${aks_name}.err"
            
            # Wait for pod to be ready
            kubectl wait --for=condition=Ready pod/$POD_NAME --timeout=120s > "${OUTPUT_DIR}/pod_wait_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_wait_${aks_name}.err"
        fi
        
        # Check if a specific destination was requested
        if [[ "$destination" != "all" && "$destination" == *":"* ]]; then
            # Parse the specific destination
            custom_hostname=$(echo "$destination" | cut -d ':' -f1)
            custom_port=$(echo "$destination" | cut -d ':' -f2)
            custom_desc=$(echo "$destination" | cut -d ':' -f3 || echo "$custom_hostname")
            
            # Create a sanitized name for files
            custom_name=$(echo "$custom_hostname" | tr -c '[:alnum:]' '_' | cut -c 1-30)
            
            # Create unique test ID for deduplication
            test_id="AKS:${aks_name}_to_Custom:${custom_hostname}:${custom_port}"
            
            # Check if this test has already been executed
            if ! grep -q "^$test_id$" "$EXECUTED_TESTS_FILE"; then
                # Mark as executed
                echo "$test_id" >> "$EXECUTED_TESTS_FILE"
                
                log "[RUNNING] Connectivity - AKS:$aks_name to Custom:$custom_desc ($custom_hostname:$custom_port)"
                
                # Test connectivity with DNS lookup first (continue even if it fails)
                kubectl exec $POD_NAME -- bash -c "echo 'CONNECTIVITY TEST: AKS:$aks_name to Custom:$custom_desc' && \
                    echo 'DNS LOOKUP:' && (nslookup $custom_hostname || echo 'DNS resolution failed, trying direct connection tests')" \
                    > "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_dns.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_dns.err"
                
                # Try curl for timing data if available, otherwise use nc
                kubectl exec $POD_NAME -- bash -c "if command -v curl &> /dev/null && [ $custom_port -eq 80 -o $custom_port -eq 443 ]; then \
                    protocol='http'; \
                    [ $custom_port -eq 443 ] && protocol='https'; \
                    echo 'CURL TIMING:' && \
                    curl -w 'DNS Resolution: %{time_namelookup}s\nTCP Connection: %{time_connect}s\nTLS Handshake: %{time_appconnect}s\nTotal time: %{time_total}s\n' \
                    -o /dev/null -s \${protocol}://$custom_hostname:$custom_port; \
                else \
                    echo 'NETCAT CONNECTION TEST ($custom_port):' && \
                    (time nc -zv -w 10 $custom_hostname $custom_port) || echo 'Connection failed'; \
                fi" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_port.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_port.err"
                
                # Combine logs
                cat "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_dns.log" "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_port.log" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}.log"
                
                # Process the result
                process_aks_custom_result "$aks_name" "$custom_hostname" "$custom_port" "$custom_desc" "$custom_name"
            else
                log "Skipping duplicate test: $test_id"
            fi
        else
            # For "all" destination - test all endpoints in custom_endpoints.txt
            if [ -s "${OUTPUT_DIR}/custom_endpoints.txt" ]; then
                while IFS=':' read -r custom_hostname custom_port custom_desc rest; do
                    # Skip if hostname or port is missing
                    [ -z "$custom_hostname" ] || [ -z "$custom_port" ] && continue
                    
                    # Use hostname as description if not provided
                    [ -z "$custom_desc" ] && custom_desc="$custom_hostname"
                    
                    # Create a sanitized name for files
                    custom_name=$(echo "$custom_hostname" | tr -c '[:alnum:]' '_' | cut -c 1-30)
                    
                    # Create unique test ID for deduplication
                    test_id="AKS:${aks_name}_to_Custom:${custom_hostname}:${custom_port}"
                    
                    # Check if this test has already been executed
                    if ! grep -q "^$test_id$" "$EXECUTED_TESTS_FILE"; then
                        # Mark as executed
                        echo "$test_id" >> "$EXECUTED_TESTS_FILE"
                        
                        log "[RUNNING] Connectivity - AKS:$aks_name to Custom:$custom_desc ($custom_hostname:$custom_port)"
                        
                        # Test connectivity with DNS lookup first (continue even if it fails)
                        kubectl exec $POD_NAME -- bash -c "echo 'CONNECTIVITY TEST: AKS:$aks_name to Custom:$custom_desc' && \
                            echo 'DNS LOOKUP:' && (nslookup $custom_hostname || echo 'DNS resolution failed, trying direct connection tests')" \
                            > "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_dns.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_dns.err"
                        
                        # Try curl for timing data if available, otherwise use nc
                        kubectl exec $POD_NAME -- bash -c "if command -v curl &> /dev/null && [ $custom_port -eq 80 -o $custom_port -eq 443 ]; then \
                            protocol='http'; \
                            [ $custom_port -eq 443 ] && protocol='https'; \
                            echo 'CURL TIMING:' && \
                            curl -w 'DNS Resolution: %{time_namelookup}s\nTCP Connection: %{time_connect}s\nTLS Handshake: %{time_appconnect}s\nTotal time: %{time_total}s\n' \
                            -o /dev/null -s \${protocol}://$custom_hostname:$custom_port; \
                        else \
                            echo 'NETCAT CONNECTION TEST ($custom_port):' && \
                            (time nc -zv -w 10 $custom_hostname $custom_port) || echo 'Connection failed'; \
                        fi" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_port.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_port.err"
                        
                        # Combine logs
                        cat "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_dns.log" "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_port.log" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}.log"
                        
                        # Process the result
                        process_aks_custom_result "$aks_name" "$custom_hostname" "$custom_port" "$custom_desc" "$custom_name"
                    else
                        log "Skipping duplicate test: $test_id"
                    fi
                done < "${OUTPUT_DIR}/custom_endpoints.txt"
            fi
            
            # Also test CUSTOM_ENDPOINTS array
            for custom_endpoint in "${CUSTOM_ENDPOINTS[@]}"; do
                # Parse endpoint components
                IFS=':' read -r custom_hostname custom_port custom_desc custom_rg custom_sub <<< "$custom_endpoint"
                
                # Skip if hostname or port is missing
                [ -z "$custom_hostname" ] || [ -z "$custom_port" ] && continue
                
                # Use hostname as description if not provided
                [ -z "$custom_desc" ] && custom_desc="$custom_hostname"
                
                # Create a sanitized name for files
                custom_name=$(echo "$custom_hostname" | tr -c '[:alnum:]' '_' | cut -c 1-30)
                
                # Create unique test ID for deduplication
                test_id="AKS:${aks_name}_to_Custom:${custom_hostname}:${custom_port}"
                
                # Check if this test has already been executed
                if ! grep -q "^$test_id$" "$EXECUTED_TESTS_FILE"; then
                    # Mark as executed
                    echo "$test_id" >> "$EXECUTED_TESTS_FILE"
                    
                    log "[RUNNING] Connectivity - AKS:$aks_name to Custom:$custom_desc ($custom_hostname:$custom_port)"
                    
                    # Test connectivity with DNS lookup first (continue even if it fails)
                    kubectl exec $POD_NAME -- bash -c "echo 'CONNECTIVITY TEST: AKS:$aks_name to Custom:$custom_desc' && \
                        echo 'DNS LOOKUP:' && (nslookup $custom_hostname || echo 'DNS resolution failed, trying direct connection tests')" \
                        > "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_dns.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_dns.err"
                    
                    # Try curl for timing data if available, otherwise use nc
                    kubectl exec $POD_NAME -- bash -c "if command -v curl &> /dev/null && [ $custom_port -eq 80 -o $custom_port -eq 443 ]; then \
                        protocol='http'; \
                        [ $custom_port -eq 443 ] && protocol='https'; \
                        echo 'CURL TIMING:' && \
                        curl -w 'DNS Resolution: %{time_namelookup}s\nTCP Connection: %{time_connect}s\nTLS Handshake: %{time_appconnect}s\nTotal time: %{time_total}s\n' \
                        -o /dev/null -s \${protocol}://$custom_hostname:$custom_port; \
                    else \
                        echo 'NETCAT CONNECTION TEST ($custom_port):' && \
                        (time nc -zv -w 10 $custom_hostname $custom_port) || echo 'Connection failed'; \
                    fi" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_port.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_port.err"
                    
                    # Combine logs
                    cat "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_dns.log" "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_port.log" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}.log"
                    
                    # Process the result
                    process_aks_custom_result "$aks_name" "$custom_hostname" "$custom_port" "$custom_desc" "$custom_name"
                else
                    log "Skipping duplicate test: $test_id"
                fi
            done
        fi
        
        # Clean up the test pod
        if [[ "$SKIP_CLEANUP" != "true" ]]; then
            log "Deleting test pod $POD_NAME from AKS cluster $aks_name"
            kubectl delete pod $POD_NAME --wait=true --timeout=30s > "${OUTPUT_DIR}/pod_delete_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_delete_${aks_name}.err"
            sleep 5
            kubectl get pod $POD_NAME --no-headers --ignore-not-found > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                log_warning "Pod $POD_NAME still exists after deletion attempt, forcing deletion"
                kubectl delete pod $POD_NAME --force --grace-period=0 > /dev/null 2>&1
                sleep 3
            fi
        fi
    done < "$AKS_CLUSTERS_FILE"
}

# Helper function to process AKS to custom endpoint test results
process_aks_custom_result() {
    local aks_name="$1"
    local custom_hostname="$2"
    local custom_port="$3"
    local custom_desc="$4"
    local custom_name="$5"
    
    # Check for success with multiple patterns
    CONNECTION_SUCCESS=false
    
    # First check for curl's detailed timing
    if grep -q "TCP Connection:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}.log"; then
        # Extract connection time and verify it's not zero (which would indicate a false positive)
        CONNECTION_TIME=$(grep "TCP Connection:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}.log" | awk '{print $3}' | sed 's/s$//')
        TOTAL_TIME=$(grep "Total time:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}.log" | awk '{print $3}' | sed 's/s$//')
        
        # Only consider it a success if connection time is non-zero
        # Also check for HTTP errors in the log
        if (( $(echo "$CONNECTION_TIME > 0.0" | bc -l) )) && ! grep -q "Connection refused\|Could not resolve host\|Failed to connect\|Connection timed out" "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}.log"; then
            CONNECTION_SUCCESS=true
            log_success "Connectivity - AKS:$aks_name to Custom:$custom_hostname is successful (Connection: ${CONNECTION_TIME}s, Total: ${TOTAL_TIME}s)"
            echo "AKS:$aks_name to Custom:$custom_hostname - SUCCESS - Connection: ${CONNECTION_TIME}s, Total: ${TOTAL_TIME}s" >> "$SUMMARY_FILE"
        else
            log_error "Connectivity - AKS:$aks_name to Custom:$custom_hostname failed (Suspicious zero connection time or error detected)"
            echo "AKS:$aks_name to Custom:$custom_hostname - FAILED - Suspicious connection or error detected" >> "$SUMMARY_FILE"
        fi
    # Then check for netcat success patterns
    elif grep -q "Connection to.*$custom_port.*succeeded\|open\|connected" "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}.log"; then
        CONNECTION_SUCCESS=true
        
        # Try to extract timing from time command
        if grep -q "real" "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}.log"; then
            CONNECTION_TIME=$(grep "real" "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}.log" | head -1 | awk '{print $2}')
            log_success "Connectivity - AKS:$aks_name to Custom:$custom_hostname is successful (Connection Time: ${CONNECTION_TIME})"
            echo "AKS:$aks_name to Custom:$custom_hostname - SUCCESS - Connection Time: ${CONNECTION_TIME}" >> "$SUMMARY_FILE"
        else
            log_success "Connectivity - AKS:$aks_name to Custom:$custom_hostname is successful"
            echo "AKS:$aks_name to Custom:$custom_hostname - SUCCESS" >> "$SUMMARY_FILE"
        fi
    else
        log_error "Connectivity - AKS:$aks_name to Custom:$custom_hostname failed"
        echo "AKS:$aks_name to Custom:$custom_hostname - FAILED" >> "$SUMMARY_FILE"
    fi
}
# test_aks_to_custom_connectivity() {
#     log "Testing AKS to Custom Endpoints connectivity..."
    
#     if [ ! -s "${OUTPUT_DIR}/aks_clusters.txt" ] || [ ! -s "${OUTPUT_DIR}/custom_endpoints.txt" ]; then
#         log_warning "Either AKS clusters or Custom Endpoints not found, skipping AKS to Custom Endpoints connectivity tests."
#         return
#     fi
    
#     # For each AKS cluster, test connectivity to each Custom Endpoint
#     while IFS='|' read -r aks_sub aks_rg aks_name aks_node_rg aks_fqdn aks_api_server aks_network_plugin; do
#         # Get credentials for the cluster
#         log "Getting credentials for AKS cluster $aks_name"
#         run_az_command "az account set --subscription \"$aks_sub\"" "${OUTPUT_DIR}/aks_custom_account_set_${aks_sub}.log" "${OUTPUT_DIR}/aks_custom_account_set_${aks_sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for AKS to Custom Endpoints tests ($aks_sub)"
        
#         run_az_command "az aks get-credentials --resource-group \"$aks_rg\" --name \"$aks_name\" --overwrite-existing" "${OUTPUT_DIR}/aks_custom_credentials_${aks_sub}_${aks_name}.log" "${OUTPUT_DIR}/aks_custom_credentials_${aks_sub}_${aks_name}.err" "$DISCOVERY_TIMEOUT" "Getting AKS credentials for $aks_name"
        
#         # Deploy test pod if it doesn't exist
#         POD_NAME="connectivity-test-$(echo $aks_name | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c 1-20)"
        
#         # Check if pod exists
#         POD_EXISTS=$(kubectl get pod $POD_NAME -o name 2>/dev/null)
        
#         if [ -z "$POD_EXISTS" ]; then
#             kubectl delete pod $POD_NAME --force --grace-period=0 --ignore-not-found=true --wait=false > /dev/null 2>&1
#             sleep 5  # Give a moment for deletion to process
            
#             log "Creating test pod in AKS cluster $aks_name using pre-built image: $TEST_POD_IMAGE"
#             kubectl run $POD_NAME --image=$TEST_POD_IMAGE > "${OUTPUT_DIR}/pod_create_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_create_${aks_name}.err"
            
#             # Wait for pod to be ready
#             kubectl wait --for=condition=Ready pod/$POD_NAME --timeout=120s > "${OUTPUT_DIR}/pod_wait_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_wait_${aks_name}.err"
#         fi
        
#         # For each Custom Endpoint
#         while IFS=':' read -r custom_hostname custom_port custom_desc rest; do
#             # Skip if hostname or port is missing
#             [ -z "$custom_hostname" ] || [ -z "$custom_port" ] && continue
            
#             # Use hostname as description if not provided
#             [ -z "$custom_desc" ] && custom_desc="$custom_hostname"
            
#             # Create a sanitized name for files
#             custom_name=$(echo "$custom_hostname" | tr -c '[:alnum:]' '_' | cut -c 1-30)
            
#             log "[RUNNING] Connectivity - AKS:$aks_name to Custom:$custom_desc ($custom_hostname:$custom_port)"
            
#             # Test connectivity with DNS lookup first (continue even if it fails)
#             kubectl exec $POD_NAME -- bash -c "echo 'CONNECTIVITY TEST: AKS:$aks_name to Custom:$custom_desc' && \
#                 echo 'DNS LOOKUP:' && (nslookup $custom_hostname || echo 'DNS resolution failed, trying direct connection tests')" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_dns.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_dns.err"
            
#             # Try curl for timing data if available, otherwise use nc
#             kubectl exec $POD_NAME -- bash -c "if command -v curl &> /dev/null && [ $custom_port -eq 80 -o $custom_port -eq 443 ]; then \
#                 protocol='http'; \
#                 [ $custom_port -eq 443 ] && protocol='https'; \
#                 echo 'CURL TIMING:' && \
#                 curl -w 'DNS Resolution: %{time_namelookup}s\nTCP Connection: %{time_connect}s\nTLS Handshake: %{time_appconnect}s\nTotal time: %{time_total}s\n' \
#                 -o /dev/null -s \${protocol}://$custom_hostname:$custom_port; \
#             else \
#                 echo 'NETCAT CONNECTION TEST ($custom_port):' && \
#                 (time nc -zv -w 10 $custom_hostname $custom_port) || echo 'Connection failed'; \
#             fi" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_port.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_port.err"
            
#             # Combine logs
#             cat "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_dns.log" "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}_port.log" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}.log"
            
#             # Check for success with multiple patterns
#             CONNECTION_SUCCESS=false
            
#             # First check for curl's detailed timing
#             if grep -q "TCP Connection:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}.log"; then
#                 CONNECTION_SUCCESS=true
#                 CONNECTION_TIME=$(grep "TCP Connection:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}.log" | awk '{print $3}' | sed 's/s$//')
#                 TOTAL_TIME=$(grep "Total time:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}.log" | awk '{print $3}' | sed 's/s$//')
                
#                 log_success "Connectivity - AKS:$aks_name to Custom:$custom_desc is successful (Connection: ${CONNECTION_TIME}s, Total: ${TOTAL_TIME}s)"
#                 echo "AKS:$aks_name to Custom:$custom_desc - SUCCESS - Connection: ${CONNECTION_TIME}s, Total: ${TOTAL_TIME}s" >> "$SUMMARY_FILE"
            
#             # Then check for netcat success patterns
#             elif grep -q "Connection to.*$custom_port.*succeeded\|open\|connected" "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}.log"; then
#                 CONNECTION_SUCCESS=true
                
#                 # Try to extract timing from time command
#                 if grep -q "real" "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}.log"; then
#                     CONNECTION_TIME=$(grep "real" "${OUTPUT_DIR}/connectivity_${aks_name}_to_custom_${custom_name}.log" | head -1 | awk '{print $2}')
#                     log_success "Connectivity - AKS:$aks_name to Custom:$custom_desc is successful (Connection Time: ${CONNECTION_TIME})"
#                     echo "AKS:$aks_name to Custom:$custom_desc - SUCCESS - Connection Time: ${CONNECTION_TIME}" >> "$SUMMARY_FILE"
#                 else
#                     log_success "Connectivity - AKS:$aks_name to Custom:$custom_desc is successful"
#                     echo "AKS:$aks_name to Custom:$custom_desc - SUCCESS" >> "$SUMMARY_FILE"
#                 fi
#             else
#                 log_error "Connectivity - AKS:$aks_name to Custom:$custom_desc failed"
#                 echo "AKS:$aks_name to Custom:$custom_desc - FAILED" >> "$SUMMARY_FILE"
#             fi
            
#         done < "${OUTPUT_DIR}/custom_endpoints.txt"
        
#         # Clean up the test pod
#         if [[ "$SKIP_CLEANUP" != "true" ]]; then
#             log "Deleting test pod $POD_NAME from AKS cluster $aks_name"
#             kubectl delete pod $POD_NAME --wait=true --timeout=30s > "${OUTPUT_DIR}/pod_delete_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_delete_${aks_name}.err"
#             sleep 5
#             kubectl get pod $POD_NAME --no-headers --ignore-not-found > /dev/null 2>&1
#             if [ $? -eq 0 ]; then
#                 log_warning "Pod $POD_NAME still exists after deletion attempt, forcing deletion"
#                 kubectl delete pod $POD_NAME --force --grace-period=0 > /dev/null 2>&1
#                 sleep 3
#             fi
#         fi
#     done < "${OUTPUT_DIR}/aks_clusters.txt"
# }
test_aks_to_storage_connectivity() {
    log "Testing AKS to Storage Account connectivity..."
    
    if [ ! -s "${OUTPUT_DIR}/aks_clusters.txt" ] || [ ! -s "${OUTPUT_DIR}/storage_accounts.txt" ]; then
        log_warning "Either AKS clusters or Storage Accounts not found, skipping AKS to Storage connectivity tests."
        return
    fi
    
    # For each AKS cluster, test connectivity to each Storage Account
    while IFS='|' read -r aks_sub aks_rg aks_name aks_node_rg aks_fqdn aks_api_server aks_network_plugin; do
        # Get credentials for the cluster
        log "Getting credentials for AKS cluster $aks_name"
        run_az_command "az account set --subscription \"$aks_sub\"" "${OUTPUT_DIR}/aks_storage_account_set_${aks_sub}.log" "${OUTPUT_DIR}/aks_storage_account_set_${aks_sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for AKS to Storage tests ($aks_sub)"
        
        run_az_command "az aks get-credentials --resource-group \"$aks_rg\" --name \"$aks_name\" --overwrite-existing" "${OUTPUT_DIR}/aks_storage_credentials_${aks_sub}_${aks_name}.log" "${OUTPUT_DIR}/aks_storage_credentials_${aks_sub}_${aks_name}.err" "$DISCOVERY_TIMEOUT" "Getting AKS credentials for $aks_name"
        
        # Deploy test pod if it doesn't exist
        POD_NAME="connectivity-test-$(echo $aks_name | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c 1-20)"
        
        # Check if pod exists
        POD_EXISTS=$(kubectl get pod $POD_NAME -o name 2>/dev/null)
        
        if [ -z "$POD_EXISTS" ]; then
            kubectl delete pod $POD_NAME --force --grace-period=0 --ignore-not-found=true --wait=false > /dev/null 2>&1
            sleep 5  # Give a moment for deletion to process
            
            log "Creating test pod in AKS cluster $aks_name using pre-built image: $TEST_POD_IMAGE"
            kubectl run $POD_NAME --image=$TEST_POD_IMAGE > "${OUTPUT_DIR}/pod_create_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_create_${aks_name}.err"
            
            # Wait for pod to be ready
            kubectl wait --for=condition=Ready pod/$POD_NAME --timeout=120s > "${OUTPUT_DIR}/pod_wait_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_wait_${aks_name}.err"
        fi
        
        # For each Storage Account
        while IFS='|' read -r sa_sub sa_rg sa_name sa_id sa_location sa_private_ep sa_is_hns sa_hostname; do
            # Skip if Storage account name is missing
            [ -z "$sa_name" ] && continue
            
            # Use blob endpoint hostname
            if [ -z "$sa_hostname" ] || [ "$sa_hostname" = "unknown" ]; then
                sa_hostname="${sa_name}.blob.core.windows.net"
            fi
            
            log "[RUNNING] Connectivity - AKS:$aks_name to Storage:$sa_name"
            
            # Test connectivity with DNS lookup first (continue even if it fails)
            kubectl exec $POD_NAME -- bash -c "echo 'CONNECTIVITY TEST: AKS:$aks_name to Storage:$sa_name' && \
                echo 'DNS LOOKUP:' && (nslookup $sa_hostname || echo 'DNS resolution failed, trying direct connection tests')" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sa_name}_dns.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sa_name}_dns.err"
            
            # Try curl for timing data if available, otherwise use nc
            kubectl exec $POD_NAME -- bash -c "if command -v curl &> /dev/null; then \
                echo 'CURL TIMING:' && \
                curl -w 'DNS Resolution: %{time_namelookup}s\nTCP Connection: %{time_connect}s\nTLS Handshake: %{time_appconnect}s\nTotal time: %{time_total}s\n' \
                -o /dev/null -s https://$sa_hostname; \
            else \
                echo 'NETCAT CONNECTION TEST (443):' && \
                (time nc -zv -w 10 $sa_hostname 443) || echo 'HTTP Connection failed'; \
            fi" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sa_name}_http.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sa_name}_http.err"
            
            # Combine logs
            cat "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sa_name}_dns.log" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sa_name}_http.log" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sa_name}.log"
            
            # Check for success with multiple patterns
            CONNECTION_SUCCESS=false
            
            # First check for curl's detailed timing
            if grep -q "TCP Connection:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sa_name}.log"; then
                CONNECTION_SUCCESS=true
                CONNECTION_TIME=$(grep "TCP Connection:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sa_name}.log" | awk '{print $3}' | sed 's/s$//')
                TOTAL_TIME=$(grep "Total time:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sa_name}.log" | awk '{print $3}' | sed 's/s$//')
                
                log_success "Connectivity - AKS:$aks_name to Storage:$sa_name is successful (Connection: ${CONNECTION_TIME}s, Total: ${TOTAL_TIME}s)"
                echo "AKS:$aks_name to Storage:$sa_name - SUCCESS - Connection: ${CONNECTION_TIME}s, Total: ${TOTAL_TIME}s" >> "$SUMMARY_FILE"
            
            # Then check for netcat success patterns
            elif grep -q "Connection to.*443.*succeeded\|open\|connected" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sa_name}.log"; then
                CONNECTION_SUCCESS=true
                
                # Try to extract timing from time command
                if grep -q "real" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sa_name}.log"; then
                    CONNECTION_TIME=$(grep "real" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sa_name}.log" | head -1 | awk '{print $2}')
                    log_success "Connectivity - AKS:$aks_name to Storage:$sa_name is successful (Connection Time: ${CONNECTION_TIME})"
                    echo "AKS:$aks_name to Storage:$sa_name - SUCCESS - Connection Time: ${CONNECTION_TIME}" >> "$SUMMARY_FILE"
                else
                    log_success "Connectivity - AKS:$aks_name to Storage:$sa_name is successful"
                    echo "AKS:$aks_name to Storage:$sa_name - SUCCESS" >> "$SUMMARY_FILE"
                fi
            else
                log_error "Connectivity - AKS:$aks_name to Storage:$sa_name failed"
                echo "AKS:$aks_name to Storage:$sa_name - FAILED" >> "$SUMMARY_FILE"
            fi
            
        done < "${OUTPUT_DIR}/storage_accounts.txt"
        
        # Clean up the test pod
        if [[ "$SKIP_CLEANUP" != "true" ]]; then
            log "Deleting test pod $POD_NAME from AKS cluster $aks_name"
            kubectl delete pod $POD_NAME --wait=true --timeout=30s > "${OUTPUT_DIR}/pod_delete_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_delete_${aks_name}.err"
            sleep 5
            kubectl get pod $POD_NAME --no-headers --ignore-not-found > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                log_warning "Pod $POD_NAME still exists after deletion attempt, forcing deletion"
                kubectl delete pod $POD_NAME --force --grace-period=0 > /dev/null 2>&1
                sleep 3
            fi
        fi
    done < "${OUTPUT_DIR}/aks_clusters.txt"
}
test_aks_to_servicebus_connectivity() {
    log "Testing AKS to Service Bus connectivity..."
    
    if [ ! -s "${OUTPUT_DIR}/aks_clusters.txt" ] || [ ! -s "${OUTPUT_DIR}/servicebus.txt" ]; then
        log_warning "Either AKS clusters or Service Bus namespaces not found, skipping AKS to Service Bus connectivity tests."
        return
    fi
    
    # For each AKS cluster, test connectivity to each Service Bus namespace
    while IFS='|' read -r aks_sub aks_rg aks_name aks_node_rg aks_fqdn aks_api_server aks_network_plugin; do
        # Get credentials for the cluster
        log "Getting credentials for AKS cluster $aks_name"
        run_az_command "az account set --subscription \"$aks_sub\"" "${OUTPUT_DIR}/aks_sb_account_set_${aks_sub}.log" "${OUTPUT_DIR}/aks_sb_account_set_${aks_sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for AKS to Service Bus tests ($aks_sub)"
        
        run_az_command "az aks get-credentials --resource-group \"$aks_rg\" --name \"$aks_name\" --overwrite-existing" "${OUTPUT_DIR}/aks_sb_credentials_${aks_sub}_${aks_name}.log" "${OUTPUT_DIR}/aks_sb_credentials_${aks_sub}_${aks_name}.err" "$DISCOVERY_TIMEOUT" "Getting AKS credentials for $aks_name"
        
        # Deploy test pod if it doesn't exist
        POD_NAME="connectivity-test-$(echo $aks_name | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c 1-20)"
        
        # Check if pod exists
        POD_EXISTS=$(kubectl get pod $POD_NAME -o name 2>/dev/null)
        
        if [ -z "$POD_EXISTS" ]; then
            kubectl delete pod $POD_NAME --force --grace-period=0 --ignore-not-found=true --wait=false > /dev/null 2>&1
            sleep 5  # Give a moment for deletion to process
            
            log "Creating test pod in AKS cluster $aks_name using pre-built image: $TEST_POD_IMAGE"
            kubectl run $POD_NAME --image=$TEST_POD_IMAGE > "${OUTPUT_DIR}/pod_create_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_create_${aks_name}.err"
            
            # Wait for pod to be ready
            kubectl wait --for=condition=Ready pod/$POD_NAME --timeout=120s > "${OUTPUT_DIR}/pod_wait_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_wait_${aks_name}.err"
        fi
        
        # For each Service Bus namespace
        while IFS='|' read -r sb_sub sb_rg sb_name sb_id sb_endpoint sb_status sb_sku; do
            # Skip if Service Bus endpoint is missing or unknown
            [ -z "$sb_endpoint" ] || [ "$sb_endpoint" = "unknown" ] && continue
            
            log "[RUNNING] Connectivity - AKS:$aks_name to Service Bus:$sb_name"
            
            # Test connectivity with DNS lookup first (continue even if it fails)
            kubectl exec $POD_NAME -- bash -c "echo 'CONNECTIVITY TEST: AKS:$aks_name to Service Bus:$sb_name' && \
                echo 'DNS LOOKUP:' && (nslookup $sb_endpoint || echo 'DNS resolution failed, trying direct connection tests')" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sb_name}_dns.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sb_name}_dns.err"
            
            # Try curl for timing data if available, otherwise use nc
            kubectl exec $POD_NAME -- bash -c "if command -v curl &> /dev/null; then \
                echo 'CURL TIMING:' && \
                curl -w 'DNS Resolution: %{time_namelookup}s\nTCP Connection: %{time_connect}s\nTLS Handshake: %{time_appconnect}s\nTotal time: %{time_total}s\n' \
                -o /dev/null -s https://$sb_endpoint; \
            else \
                echo 'NETCAT CONNECTION TEST (443):' && \
                (time nc -zv -w 10 $sb_endpoint 443) || echo 'HTTP Connection failed'; \
            fi" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sb_name}_http.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sb_name}_http.err"
            
            # Test AMQP port
            kubectl exec $POD_NAME -- bash -c "echo 'AMQP PORT TEST (5671):' && \
                (time nc -zv -w 10 $sb_endpoint 5671) || echo 'AMQP Connection failed'" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sb_name}_amqp.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sb_name}_amqp.err"
            
            # Combine logs
            cat "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sb_name}_dns.log" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sb_name}_http.log" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sb_name}_amqp.log" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sb_name}.log"
            
            # Check for success with multiple patterns
            CONNECTION_SUCCESS=false
            
            # First check for curl's detailed timing
            if grep -q "TCP Connection:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sb_name}.log"; then
                CONNECTION_SUCCESS=true
                CONNECTION_TIME=$(grep "TCP Connection:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sb_name}.log" | awk '{print $3}' | sed 's/s$//')
                TOTAL_TIME=$(grep "Total time:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sb_name}.log" | awk '{print $3}' | sed 's/s$//')
                
                log_success "Connectivity - AKS:$aks_name to Service Bus:$sb_name is successful (Connection: ${CONNECTION_TIME}s, Total: ${TOTAL_TIME}s)"
                echo "AKS:$aks_name to Service Bus:$sb_name - SUCCESS - Connection: ${CONNECTION_TIME}s, Total: ${TOTAL_TIME}s" >> "$SUMMARY_FILE"
            
            # Then check for netcat success patterns
            elif grep -q "Connection to.*443.*succeeded\|open\|connected" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sb_name}.log"; then
                CONNECTION_SUCCESS=true
                
                # Try to extract timing from time command
                if grep -q "real" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sb_name}.log"; then
                    CONNECTION_TIME=$(grep "real" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${sb_name}.log" | head -1 | awk '{print $2}')
                    log_success "Connectivity - AKS:$aks_name to Service Bus:$sb_name is successful (Connection Time: ${CONNECTION_TIME})"
                    echo "AKS:$aks_name to Service Bus:$sb_name - SUCCESS - Connection Time: ${CONNECTION_TIME}" >> "$SUMMARY_FILE"
                else
                    log_success "Connectivity - AKS:$aks_name to Service Bus:$sb_name is successful"
                    echo "AKS:$aks_name to Service Bus:$sb_name - SUCCESS" >> "$SUMMARY_FILE"
                fi
            else
                log_error "Connectivity - AKS:$aks_name to Service Bus:$sb_name failed"
                echo "AKS:$aks_name to Service Bus:$sb_name - FAILED" >> "$SUMMARY_FILE"
            fi
        done < "${OUTPUT_DIR}/servicebus.txt"
        
        # Clean up the test pod
        if [[ "$SKIP_CLEANUP" != "true" ]]; then
            log "Deleting test pod $POD_NAME from AKS cluster $aks_name"
            kubectl delete pod $POD_NAME --wait=true --timeout=30s > "${OUTPUT_DIR}/pod_delete_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_delete_${aks_name}.err"
            sleep 5
            kubectl get pod $POD_NAME --no-headers --ignore-not-found > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                log_warning "Pod $POD_NAME still exists after deletion attempt, forcing deletion"
                kubectl delete pod $POD_NAME --force --grace-period=0 > /dev/null 2>&1
                sleep 3
            fi
        fi
    done < "${OUTPUT_DIR}/aks_clusters.txt"
}

test_aks_to_eventhub_connectivity() {
    log "Testing AKS to Event Hub connectivity..."
    
    if [ ! -s "${OUTPUT_DIR}/aks_clusters.txt" ] || [ ! -s "${OUTPUT_DIR}/eventhub.txt" ]; then
        log_warning "Either AKS clusters or Event Hub namespaces not found, skipping AKS to Event Hub connectivity tests."
        return
    fi
    
    # For each AKS cluster, test connectivity to each Event Hub namespace
    while IFS='|' read -r aks_sub aks_rg aks_name aks_node_rg aks_fqdn aks_api_server aks_network_plugin; do
        # Get credentials for the cluster
        log "Getting credentials for AKS cluster $aks_name"
        run_az_command "az account set --subscription \"$aks_sub\"" "${OUTPUT_DIR}/aks_eh_account_set_${aks_sub}.log" "${OUTPUT_DIR}/aks_eh_account_set_${aks_sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for AKS to Event Hub tests ($aks_sub)"
        
        run_az_command "az aks get-credentials --resource-group \"$aks_rg\" --name \"$aks_name\" --overwrite-existing" "${OUTPUT_DIR}/aks_eh_credentials_${aks_sub}_${aks_name}.log" "${OUTPUT_DIR}/aks_eh_credentials_${aks_sub}_${aks_name}.err" "$DISCOVERY_TIMEOUT" "Getting AKS credentials for $aks_name"
        
        # Deploy test pod if it doesn't exist
        POD_NAME="connectivity-test-$(echo $aks_name | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c 1-20)"
        
        # Check if pod exists
        POD_EXISTS=$(kubectl get pod $POD_NAME -o name 2>/dev/null)
        
        if [ -z "$POD_EXISTS" ]; then
            kubectl delete pod $POD_NAME --force --grace-period=0 --ignore-not-found=true --wait=false > /dev/null 2>&1
            sleep 5  # Give a moment for deletion to process
            
            log "Creating test pod in AKS cluster $aks_name using pre-built image: $TEST_POD_IMAGE"
            kubectl run $POD_NAME --image=$TEST_POD_IMAGE > "${OUTPUT_DIR}/pod_create_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_create_${aks_name}.err"
            
            # Wait for pod to be ready
            kubectl wait --for=condition=Ready pod/$POD_NAME --timeout=120s > "${OUTPUT_DIR}/pod_wait_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_wait_${aks_name}.err"
        fi
        
        # For each Event Hub namespace
        while IFS='|' read -r eh_sub eh_rg eh_name eh_id eh_endpoint eh_status eh_sku; do
            # Skip if Event Hub endpoint is missing or unknown
            [ -z "$eh_endpoint" ] || [ "$eh_endpoint" = "unknown" ] && continue
            
            log "[RUNNING] Connectivity - AKS:$aks_name to Event Hub:$eh_name"
            
            # Test connectivity with DNS lookup first (continue even if it fails)
            kubectl exec $POD_NAME -- bash -c "echo 'CONNECTIVITY TEST: AKS:$aks_name to Event Hub:$eh_name' && \
                echo 'DNS LOOKUP:' && (nslookup $eh_endpoint || echo 'DNS resolution failed, trying direct connection tests')" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${eh_name}_dns.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_${eh_name}_dns.err"
            
            # Try curl for timing data if available, otherwise use nc
            kubectl exec $POD_NAME -- bash -c "if command -v curl &> /dev/null; then \
                echo 'CURL TIMING:' && \
                curl -w 'DNS Resolution: %{time_namelookup}s\nTCP Connection: %{time_connect}s\nTLS Handshake: %{time_appconnect}s\nTotal time: %{time_total}s\n' \
                -o /dev/null -s https://$eh_endpoint; \
            else \
                echo 'NETCAT CONNECTION TEST (443):' && \
                (time nc -zv -w 10 $eh_endpoint 443) || echo 'HTTP Connection failed'; \
            fi" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${eh_name}_http.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_${eh_name}_http.err"
            
            # Test AMQP port
            kubectl exec $POD_NAME -- bash -c "echo 'AMQP PORT TEST (5671):' && \
                (time nc -zv -w 10 $eh_endpoint 5671) || echo 'AMQP Connection failed'" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${eh_name}_amqp.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_${eh_name}_amqp.err"
            
            # Combine logs
            cat "${OUTPUT_DIR}/connectivity_${aks_name}_to_${eh_name}_dns.log" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${eh_name}_http.log" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${eh_name}_amqp.log" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${eh_name}.log"
            
            # Check for success with multiple patterns
            CONNECTION_SUCCESS=false
            
            # First check for curl's detailed timing
            if grep -q "TCP Connection:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${eh_name}.log"; then
                CONNECTION_SUCCESS=true
                CONNECTION_TIME=$(grep "TCP Connection:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${eh_name}.log" | awk '{print $3}' | sed 's/s$//')
                TOTAL_TIME=$(grep "Total time:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${eh_name}.log" | awk '{print $3}' | sed 's/s$//')
                
                log_success "Connectivity - AKS:$aks_name to Event Hub:$eh_name is successful (Connection: ${CONNECTION_TIME}s, Total: ${TOTAL_TIME}s)"
                echo "AKS:$aks_name to Event Hub:$eh_name - SUCCESS - Connection: ${CONNECTION_TIME}s, Total: ${TOTAL_TIME}s" >> "$SUMMARY_FILE"
            
            # Then check for netcat success patterns
            elif grep -q "Connection to.*443.*succeeded\|open\|connected" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${eh_name}.log"; then
                CONNECTION_SUCCESS=true
                
                # Try to extract timing from time command
                if grep -q "real" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${eh_name}.log"; then
                    CONNECTION_TIME=$(grep "real" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${eh_name}.log" | head -1 | awk '{print $2}')
                    log_success "Connectivity - AKS:$aks_name to Event Hub:$eh_name is successful (Connection Time: ${CONNECTION_TIME})"
                    echo "AKS:$aks_name to Event Hub:$eh_name - SUCCESS - Connection Time: ${CONNECTION_TIME}" >> "$SUMMARY_FILE"
                else
                    log_success "Connectivity - AKS:$aks_name to Event Hub:$eh_name is successful"
                    echo "AKS:$aks_name to Event Hub:$eh_name - SUCCESS" >> "$SUMMARY_FILE"
                fi
            else
                log_error "Connectivity - AKS:$aks_name to Event Hub:$eh_name failed"
                echo "AKS:$aks_name to Event Hub:$eh_name - FAILED" >> "$SUMMARY_FILE"
            fi
            
        done < "${OUTPUT_DIR}/eventhub.txt"
        
        # Clean up the test pod
        if [[ "$SKIP_CLEANUP" != "true" ]]; then
            log "Deleting test pod $POD_NAME from AKS cluster $aks_name"
            kubectl delete pod $POD_NAME --wait=true --timeout=30s > "${OUTPUT_DIR}/pod_delete_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_delete_${aks_name}.err"
            sleep 5
            kubectl get pod $POD_NAME --no-headers --ignore-not-found > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                log_warning "Pod $POD_NAME still exists after deletion attempt, forcing deletion"
                kubectl delete pod $POD_NAME --force --grace-period=0 > /dev/null 2>&1
                sleep 3
            fi
        fi
    done < "${OUTPUT_DIR}/aks_clusters.txt"
}

test_aks_to_cosmosdb_connectivity() {
    log "Testing AKS to Cosmos DB connectivity..."
    
    if [ ! -s "${OUTPUT_DIR}/aks_clusters.txt" ] || [ ! -s "${OUTPUT_DIR}/cosmosdb.txt" ]; then
        log_warning "Either AKS clusters or Cosmos DB accounts not found, skipping AKS to Cosmos DB connectivity tests."
        return
    fi
    
    # For each AKS cluster, test connectivity to each Cosmos DB account
    while IFS='|' read -r aks_sub aks_rg aks_name aks_node_rg aks_fqdn aks_api_server aks_network_plugin; do
        # Get credentials for the cluster
        log "Getting credentials for AKS cluster $aks_name"
        run_az_command "az account set --subscription \"$aks_sub\"" "${OUTPUT_DIR}/aks_cosmos_account_set_${aks_sub}.log" "${OUTPUT_DIR}/aks_cosmos_account_set_${aks_sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for AKS to Cosmos DB tests ($aks_sub)"
        
        run_az_command "az aks get-credentials --resource-group \"$aks_rg\" --name \"$aks_name\" --overwrite-existing" "${OUTPUT_DIR}/aks_cosmos_credentials_${aks_sub}_${aks_name}.log" "${OUTPUT_DIR}/aks_cosmos_credentials_${aks_sub}_${aks_name}.err" "$DISCOVERY_TIMEOUT" "Getting AKS credentials for $aks_name"
        
        # Deploy test pod if it doesn't exist
        POD_NAME="connectivity-test-$(echo $aks_name | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c 1-20)"
        
        # Check if pod exists
        POD_EXISTS=$(kubectl get pod $POD_NAME -o name 2>/dev/null)
        
        if [ -z "$POD_EXISTS" ]; then
            kubectl delete pod $POD_NAME --force --grace-period=0 --ignore-not-found=true --wait=false > /dev/null 2>&1
            sleep 5  # Give a moment for deletion to process
            
            log "Creating test pod in AKS cluster $aks_name using pre-built image: $TEST_POD_IMAGE"
            kubectl run $POD_NAME --image=$TEST_POD_IMAGE > "${OUTPUT_DIR}/pod_create_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_create_${aks_name}.err"
            
            # Wait for pod to be ready
            kubectl wait --for=condition=Ready pod/$POD_NAME --timeout=120s > "${OUTPUT_DIR}/pod_wait_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_wait_${aks_name}.err"
        fi
        
        # For each Cosmos DB account
        while IFS='|' read -r cosmos_sub cosmos_rg cosmos_name cosmos_id cosmos_endpoint cosmos_kind cosmos_api; do
            # Skip if Cosmos DB endpoint is missing or unknown
            [ -z "$cosmos_endpoint" ] || [ "$cosmos_endpoint" = "unknown" ] && continue
            
            log "[RUNNING] Connectivity - AKS:$aks_name to Cosmos DB:$cosmos_name"
            
            # Extract hostname from endpoint
            cosmos_hostname=$(echo "$cosmos_endpoint" | sed -e 's|^[^/]*//||' -e 's|/.*$||')
            
            # Test connectivity with DNS lookup first (continue even if it fails)
            kubectl exec $POD_NAME -- bash -c "echo 'CONNECTIVITY TEST: AKS:$aks_name to Cosmos DB:$cosmos_name' && \
                echo 'DNS LOOKUP:' && (nslookup $cosmos_hostname || echo 'DNS resolution failed, trying direct connection tests')" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${cosmos_name}_dns.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_${cosmos_name}_dns.err"
            
            # Try curl for timing data if available, otherwise use nc
            kubectl exec $POD_NAME -- bash -c "if command -v curl &> /dev/null; then \
                echo 'CURL TIMING:' && \
                curl -w 'DNS Resolution: %{time_namelookup}s\nTCP Connection: %{time_connect}s\nTLS Handshake: %{time_appconnect}s\nTotal time: %{time_total}s\n' \
                -o /dev/null -s https://$cosmos_hostname; \
            else \
                echo 'NETCAT CONNECTION TEST (443):' && \
                (time nc -zv -w 10 $cosmos_hostname 443) || echo 'HTTP Connection failed'; \
            fi" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${cosmos_name}_http.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_${cosmos_name}_http.err"
            
            # Combine logs
            cat "${OUTPUT_DIR}/connectivity_${aks_name}_to_${cosmos_name}_dns.log" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${cosmos_name}_http.log" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${cosmos_name}.log"
            
            # Check for success with multiple patterns
            CONNECTION_SUCCESS=false
            
            # First check for curl's detailed timing
            if grep -q "TCP Connection:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${cosmos_name}.log"; then
                CONNECTION_SUCCESS=true
                CONNECTION_TIME=$(grep "TCP Connection:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${cosmos_name}.log" | awk '{print $3}' | sed 's/s$//')
                TOTAL_TIME=$(grep "Total time:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${cosmos_name}.log" | awk '{print $3}' | sed 's/s$//')
                
                log_success "Connectivity - AKS:$aks_name to Cosmos DB:$cosmos_name is successful (Connection: ${CONNECTION_TIME}s, Total: ${TOTAL_TIME}s)"
                echo "AKS:$aks_name to Cosmos DB:$cosmos_name - SUCCESS - Connection: ${CONNECTION_TIME}s, Total: ${TOTAL_TIME}s" >> "$SUMMARY_FILE"
            
            # Then check for netcat success patterns
            elif grep -q "Connection to.*443.*succeeded\|open\|connected" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${cosmos_name}.log"; then
                CONNECTION_SUCCESS=true
                
                # Try to extract timing from time command
                if grep -q "real" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${cosmos_name}.log"; then
                    CONNECTION_TIME=$(grep "real" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${cosmos_name}.log" | head -1 | awk '{print $2}')
                    log_success "Connectivity - AKS:$aks_name to Cosmos DB:$cosmos_name is successful (Connection Time: ${CONNECTION_TIME})"
                    echo "AKS:$aks_name to Cosmos DB:$cosmos_name - SUCCESS - Connection Time: ${CONNECTION_TIME}" >> "$SUMMARY_FILE"
                else
                    log_success "Connectivity - AKS:$aks_name to Cosmos DB:$cosmos_name is successful"
                    echo "AKS:$aks_name to Cosmos DB:$cosmos_name - SUCCESS" >> "$SUMMARY_FILE"
                fi
            else
                log_error "Connectivity - AKS:$aks_name to Cosmos DB:$cosmos_name failed"
                echo "AKS:$aks_name to Cosmos DB:$cosmos_name - FAILED" >> "$SUMMARY_FILE"
            fi
            
        done < "${OUTPUT_DIR}/cosmosdb.txt"
        
        # Clean up the test pod
        if [[ "$SKIP_CLEANUP" != "true" ]]; then
            log "Deleting test pod $POD_NAME from AKS cluster $aks_name"
            kubectl delete pod $POD_NAME --wait=true --timeout=30s > "${OUTPUT_DIR}/pod_delete_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_delete_${aks_name}.err"
            sleep 5
            kubectl get pod $POD_NAME --no-headers --ignore-not-found > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                log_warning "Pod $POD_NAME still exists after deletion attempt, forcing deletion"
                kubectl delete pod $POD_NAME --force --grace-period=0 > /dev/null 2>&1
                sleep 3
            fi
        fi
    done < "${OUTPUT_DIR}/aks_clusters.txt"
}
test_aks_to_oracle_connectivity() {
    log "Testing AKS to Oracle DB connectivity..."
    
    if [ ! -s "${OUTPUT_DIR}/aks_clusters.txt" ] || [ ${#ORACLE_ENDPOINTS[@]} -eq 0 ]; then
        log_warning "Either AKS clusters or Oracle endpoints not found, skipping AKS to Oracle connectivity tests."
        return
    fi
    
    # For each AKS cluster, test connectivity to each Oracle endpoint
    while IFS='|' read -r aks_sub aks_rg aks_name aks_node_rg aks_fqdn aks_api_server aks_network_plugin; do
        # Get credentials for the cluster
        log "Getting credentials for AKS cluster $aks_name"
        run_az_command "az account set --subscription \"$aks_sub\"" "${OUTPUT_DIR}/aks_oracle_account_set_${aks_sub}.log" "${OUTPUT_DIR}/aks_oracle_account_set_${aks_sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for AKS to Oracle tests ($aks_sub)"
        
        run_az_command "az aks get-credentials --resource-group \"$aks_rg\" --name \"$aks_name\" --overwrite-existing" "${OUTPUT_DIR}/aks_oracle_credentials_${aks_sub}_${aks_name}.log" "${OUTPUT_DIR}/aks_oracle_credentials_${aks_sub}_${aks_name}.err" "$DISCOVERY_TIMEOUT" "Getting AKS credentials for $aks_name"
        
        # Deploy test pod if it doesn't exist
        POD_NAME="connectivity-test-$(echo $aks_name | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c 1-20)"
        
        # Check if pod exists
        POD_EXISTS=$(kubectl get pod $POD_NAME -o name 2>/dev/null)
        
        if [ -z "$POD_EXISTS" ]; then
            kubectl delete pod $POD_NAME --force --grace-period=0 --ignore-not-found=true --wait=false > /dev/null 2>&1
            sleep 5  # Give a moment for deletion to process
            
            log "Creating test pod in AKS cluster $aks_name using pre-built image: $TEST_POD_IMAGE"
            kubectl run $POD_NAME --image=$TEST_POD_IMAGE > "${OUTPUT_DIR}/pod_create_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_create_${aks_name}.err"
            
            # Wait for pod to be ready
            kubectl wait --for=condition=Ready pod/$POD_NAME --timeout=120s > "${OUTPUT_DIR}/pod_wait_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_wait_${aks_name}.err"
        fi
        
        # For each Oracle endpoint
        for oracle_endpoint in "${ORACLE_ENDPOINTS[@]}"; do
            # Parse endpoint information
            IFS=':' read -r oracle_host oracle_port oracle_name rest <<< "$oracle_endpoint"
            
            # Use default port 1521 if not specified
            [ -z "$oracle_port" ] && oracle_port=1521
            
            # Use hostname as name if not specified
            [ -z "$oracle_name" ] && oracle_name="$oracle_host"
            
            log "[RUNNING] Connectivity - AKS:$aks_name to Oracle:$oracle_name"
            
            # Test connectivity with DNS lookup first (continue even if it fails)
            kubectl exec $POD_NAME -- bash -c "echo 'CONNECTIVITY TEST: AKS:$aks_name to Oracle:$oracle_name' && \
                echo 'DNS LOOKUP:' && (nslookup $oracle_host || echo 'DNS resolution failed, trying direct connection tests')" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_oracle_${oracle_name}_dns.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_oracle_${oracle_name}_dns.err"
            
            # Try curl for timing data if available, otherwise use nc
            kubectl exec $POD_NAME -- bash -c "if command -v curl &> /dev/null && [ $oracle_port -eq 443 ]; then \
                echo 'CURL TIMING:' && \
                curl -w 'DNS Resolution: %{time_namelookup}s\nTCP Connection: %{time_connect}s\nTLS Handshake: %{time_appconnect}s\nTotal time: %{time_total}s\n' \
                -o /dev/null -s https://$oracle_host; \
            else \
                echo 'NETCAT CONNECTION TEST ($oracle_port):' && \
                (time nc -zv -w 10 $oracle_host $oracle_port) || echo 'Oracle Connection failed'; \
            fi" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_oracle_${oracle_name}_port.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_oracle_${oracle_name}_port.err"
            
            # Combine logs
            cat "${OUTPUT_DIR}/connectivity_${aks_name}_to_oracle_${oracle_name}_dns.log" "${OUTPUT_DIR}/connectivity_${aks_name}_to_oracle_${oracle_name}_port.log" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_oracle_${oracle_name}.log"
            
            # Check for success with multiple patterns
            CONNECTION_SUCCESS=false
            
            # First check for curl's detailed timing (only if port 443)
            if grep -q "TCP Connection:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_oracle_${oracle_name}.log"; then
                CONNECTION_SUCCESS=true
                CONNECTION_TIME=$(grep "TCP Connection:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_oracle_${oracle_name}.log" | awk '{print $3}' | sed 's/s$//')
                TOTAL_TIME=$(grep "Total time:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_oracle_${oracle_name}.log" | awk '{print $3}' | sed 's/s$//')
                
                log_success "Connectivity - AKS:$aks_name to Oracle:$oracle_name is successful (Connection: ${CONNECTION_TIME}s, Total: ${TOTAL_TIME}s)"
                echo "AKS:$aks_name to Oracle:$oracle_name - SUCCESS - Connection: ${CONNECTION_TIME}s, Total: ${TOTAL_TIME}s" >> "$SUMMARY_FILE"
            
            # Then check for netcat success patterns
            elif grep -q "Connection to.*$oracle_port.*succeeded\|open\|connected" "${OUTPUT_DIR}/connectivity_${aks_name}_to_oracle_${oracle_name}.log"; then
                CONNECTION_SUCCESS=true
                
                # Try to extract timing from time command
                if grep -q "real" "${OUTPUT_DIR}/connectivity_${aks_name}_to_oracle_${oracle_name}.log"; then
                    CONNECTION_TIME=$(grep "real" "${OUTPUT_DIR}/connectivity_${aks_name}_to_oracle_${oracle_name}.log" | head -1 | awk '{print $2}')
                    log_success "Connectivity - AKS:$aks_name to Oracle:$oracle_name is successful (Connection Time: ${CONNECTION_TIME})"
                    echo "AKS:$aks_name to Oracle:$oracle_name - SUCCESS - Connection Time: ${CONNECTION_TIME}" >> "$SUMMARY_FILE"
                else
                    log_success "Connectivity - AKS:$aks_name to Oracle:$oracle_name is successful"
                    echo "AKS:$aks_name to Oracle:$oracle_name - SUCCESS" >> "$SUMMARY_FILE"
                fi
            else
                log_error "Connectivity - AKS:$aks_name to Oracle:$oracle_name failed"
                echo "AKS:$aks_name to Oracle:$oracle_name - FAILED" >> "$SUMMARY_FILE"
            fi
            
        done
        
        # Clean up the test pod
        if [[ "$SKIP_CLEANUP" != "true" ]]; then
            log "Deleting test pod $POD_NAME from AKS cluster $aks_name"
            kubectl delete pod $POD_NAME --wait=true --timeout=30s > "${OUTPUT_DIR}/pod_delete_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_delete_${aks_name}.err"
            sleep 5
            kubectl get pod $POD_NAME --no-headers --ignore-not-found > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                log_warning "Pod $POD_NAME still exists after deletion attempt, forcing deletion"
                kubectl delete pod $POD_NAME --force --grace-period=0 > /dev/null 2>&1
                sleep 3
            fi
        fi
    done < "${OUTPUT_DIR}/aks_clusters.txt"
}

test_aks_to_onprem_connectivity() {
    log "Testing AKS to on-premises connectivity..."
    
    if [ ! -s "${OUTPUT_DIR}/aks_clusters.txt" ] || [ ! -s "${OUTPUT_DIR}/onprem_networks.txt" ]; then
        log_warning "Either AKS clusters or on-premises networks not found, skipping AKS to on-premises connectivity tests."
        return
    fi
    
    # For each AKS cluster, test connectivity to on-premises networks
    while IFS='|' read -r aks_sub aks_rg aks_name aks_node_rg aks_fqdn aks_api_server aks_network_plugin; do
        # Get credentials for the cluster
        log "Getting credentials for AKS cluster $aks_name"
        run_az_command "az account set --subscription \"$aks_sub\"" "${OUTPUT_DIR}/aks_onprem_account_set_${aks_sub}.log" "${OUTPUT_DIR}/aks_onprem_account_set_${aks_sub}.err" "$DISCOVERY_TIMEOUT" "Setting subscription context for AKS to on-premises tests ($aks_sub)"
        
        run_az_command "az aks get-credentials --resource-group \"$aks_rg\" --name \"$aks_name\" --overwrite-existing" "${OUTPUT_DIR}/aks_onprem_credentials_${aks_sub}_${aks_name}.log" "${OUTPUT_DIR}/aks_onprem_credentials_${aks_sub}_${aks_name}.err" "$DISCOVERY_TIMEOUT" "Getting AKS credentials for $aks_name"
        
        # Deploy test pod if it doesn't exist
        POD_NAME="connectivity-test-$(echo $aks_name | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c 1-20)"
        
        # Check if pod exists
        POD_EXISTS=$(kubectl get pod $POD_NAME -o name 2>/dev/null)
        
        if [ -z "$POD_EXISTS" ]; then
            kubectl delete pod $POD_NAME --force --grace-period=0 --ignore-not-found=true --wait=false > /dev/null 2>&1
            sleep 5  # Give a moment for deletion to process
            
            log "Creating test pod in AKS cluster $aks_name using pre-built image: $TEST_POD_IMAGE"
            kubectl run $POD_NAME --image=$TEST_POD_IMAGE > "${OUTPUT_DIR}/pod_create_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_create_${aks_name}.err"
            
            # Wait for pod to be ready
            kubectl wait --for=condition=Ready pod/$POD_NAME --timeout=120s > "${OUTPUT_DIR}/pod_wait_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_wait_${aks_name}.err"
        fi
        
        # For each on-premises network
        while IFS='|' read -r onprem_type onprem_name onprem_desc onprem_ip onprem_port onprem_id; do
            # Skip if on-premises IP is missing
            [ -z "$onprem_ip" ] && continue
            
            log "[RUNNING] Connectivity - AKS:$aks_name to on-premises:$onprem_name ($onprem_desc)"
            
            # Test ping connectivity - continue even if it fails
            kubectl exec $POD_NAME -- bash -c "echo 'CONNECTIVITY TEST: AKS:$aks_name to on-premises:$onprem_name ($onprem_desc)' && \
                echo 'PING TEST:' && (time ping -c 4 $onprem_ip) || echo 'Ping failed'" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${onprem_name}_ping.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_${onprem_name}_ping.err"
            
            # Create a combined log file
            cat "${OUTPUT_DIR}/connectivity_${aks_name}_to_${onprem_name}_ping.log" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${onprem_name}.log"
            
            # Test TCP connectivity if port is specified
            if [ -n "$onprem_port" ] && [ "$onprem_port" != "0" ]; then
                # Try curl for timing data if available, otherwise use nc
                kubectl exec $POD_NAME -- bash -c "echo 'TCP PORT TEST ($onprem_port):' && \
                    if command -v curl &> /dev/null && [ $onprem_port -eq 80 -o $onprem_port -eq 443 ]; then \
                        protocol='http'; \
                        [ $onprem_port -eq 443 ] && protocol='https'; \
                        echo 'CURL TIMING:' && \
                        curl -w 'DNS Resolution: %{time_namelookup}s\nTCP Connection: %{time_connect}s\nTLS Handshake: %{time_appconnect}s\nTotal time: %{time_total}s\n' \
                        -o /dev/null -s \${protocol}://$onprem_ip; \
                    else \
                        echo 'NETCAT CONNECTION TEST:' && \
                        (time nc -zv -w 10 $onprem_ip $onprem_port) || echo 'TCP Connection failed'; \
                    fi" > "${OUTPUT_DIR}/connectivity_${aks_name}_to_${onprem_name}_tcp.log" 2> "${OUTPUT_DIR}/connectivity_${aks_name}_to_${onprem_name}_tcp.err"
                
                # Append to the combined log file
                cat "${OUTPUT_DIR}/connectivity_${aks_name}_to_${onprem_name}_tcp.log" >> "${OUTPUT_DIR}/connectivity_${aks_name}_to_${onprem_name}.log"
            fi
            
            # Check the result
            ping_success=false
            tcp_success=false
            
            # Check for ping success by looking for packet loss
            if grep -q " 0% packet loss" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${onprem_name}_ping.log"; then
                ping_success=true
                # Extract round-trip time for reporting
                PING_TIME=$(grep "avg" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${onprem_name}_ping.log" | awk -F'/' '{print $5}' 2>/dev/null)
            fi
            
            if [ -n "$onprem_port" ] && [ "$onprem_port" != "0" ]; then
                # Check for TCP success with multiple patterns
                if grep -q "TCP Connection:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${onprem_name}_tcp.log"; then
                    tcp_success=true
                    CONNECTION_TIME=$(grep "TCP Connection:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${onprem_name}_tcp.log" | awk '{print $3}' | sed 's/s$//')
                    TOTAL_TIME=$(grep "Total time:" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${onprem_name}_tcp.log" | awk '{print $3}' | sed 's/s$//')
                elif grep -q "Connection to.*$onprem_port.*succeeded\|open\|connected" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${onprem_name}_tcp.log"; then
                    tcp_success=true
                    # Try to extract timing from time command
                    if grep -q "real" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${onprem_name}_tcp.log"; then
                        CONNECTION_TIME=$(grep "real" "${OUTPUT_DIR}/connectivity_${aks_name}_to_${onprem_name}_tcp.log" | head -1 | awk '{print $2}')
                    fi
                fi
            else
                # If no port specified, we only care about ping
                tcp_success=true
            fi
            
            # Format the output with latency information
            if [ "$ping_success" = true ] && [ "$tcp_success" = true ]; then
                if [ -n "$onprem_port" ] && [ "$onprem_port" != "0" ] && [ -n "$CONNECTION_TIME" ]; then
                    if [ -n "$TOTAL_TIME" ]; then
                        log_success "Connectivity - AKS:$aks_name to on-premises:$onprem_name is successful (Ping: ${PING_TIME}ms, Connection: ${CONNECTION_TIME}s, Total: ${TOTAL_TIME}s)"
                        echo "AKS:$aks_name to on-premises:$onprem_name - SUCCESS - Ping: ${PING_TIME}ms, Connection: ${CONNECTION_TIME}s, Total: ${TOTAL_TIME}s" >> "$SUMMARY_FILE"
                    else
                        log_success "Connectivity - AKS:$aks_name to on-premises:$onprem_name is successful (Ping: ${PING_TIME}ms, Connection: ${CONNECTION_TIME})"
                        echo "AKS:$aks_name to on-premises:$onprem_name - SUCCESS - Ping: ${PING_TIME}ms, Connection: ${CONNECTION_TIME}" >> "$SUMMARY_FILE"
                    fi
                else
                    log_success "Connectivity - AKS:$aks_name to on-premises:$onprem_name is successful (Ping: ${PING_TIME}ms)"
                    echo "AKS:$aks_name to on-premises:$onprem_name - SUCCESS - Ping: ${PING_TIME}ms" >> "$SUMMARY_FILE"
                fi
            elif [ "$ping_success" = true ]; then
                log_warning "Connectivity - AKS:$aks_name to on-premises:$onprem_name is partial (ping works: ${PING_TIME}ms, but TCP port $onprem_port fails)"
                echo "AKS:$aks_name to on-premises:$onprem_name - PARTIAL - Ping: ${PING_TIME}ms, TCP fails" >> "$SUMMARY_FILE"
            else
                log_error "Connectivity - AKS:$aks_name to on-premises:$onprem_name failed"
                echo "AKS:$aks_name to on-premises:$onprem_name - FAILED" >> "$SUMMARY_FILE"
            fi
            
        done < "${OUTPUT_DIR}/onprem_networks.txt"
        
        # Clean up the test pod
        if [[ "$SKIP_CLEANUP" != "true" ]]; then
            log "Deleting test pod $POD_NAME from AKS cluster $aks_name"
            kubectl delete pod $POD_NAME --wait=true --timeout=30s > "${OUTPUT_DIR}/pod_delete_${aks_name}.log" 2> "${OUTPUT_DIR}/pod_delete_${aks_name}.err"
            sleep 5
            kubectl get pod $POD_NAME --no-headers --ignore-not-found > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                log_warning "Pod $POD_NAME still exists after deletion attempt, forcing deletion"
                kubectl delete pod $POD_NAME --force --grace-period=0 > /dev/null 2>&1
                sleep 3
            fi
        fi
    done < "${OUTPUT_DIR}/aks_clusters.txt"
}