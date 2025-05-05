#!/bin/bash

##############################################################################
# Azure Infra Verification Script v2.0
# 
# This script verifies connectivity between Azure resources using Network Watcher
# and direct pod testing for AKS.
##############################################################################

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library files
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/discovery.sh"
source "${SCRIPT_DIR}/lib/tests.sh"
source "${SCRIPT_DIR}/lib/reporting.sh"
source "${SCRIPT_DIR}/timeout_alternative.sh"
source "${SCRIPT_DIR}/excel_reader.sh"

# Override the run_az_command function to use our timeout alternative
# Function to run Azure CLI command with debug output
run_az_command() {
    local cmd="$1"
    local output_file="$2"
    local error_file="${3:-${output_file}.err}"
    local timeout_val="${4:-$DISCOVERY_TIMEOUT}"
    local description="${5:-Azure CLI command}"
    
    # Log the command being executed
    log_debug "Executing: $cmd"
    
    # Create a temporary file for the command output
    local temp_output="${OUTPUT_DIR}/az_output_$(date +%Y%m%d%H%M%S%N).tmp"
    
    # Run the command with timeout and capture output
    if ! timeout "$timeout_val" bash -c "$cmd" > "$temp_output" 2> "$error_file"; then
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            log_warning "$description timed out after $timeout_val seconds"
        else
            log_warning "$description failed with exit code $exit_code"
        fi
        
        # Show error output if any
        if [ -s "$error_file" ]; then
            log_debug "Error output: $(cat "$error_file")"
        fi
        
        # Ensure the output file exists even if command failed
        touch "$output_file"
        
        return $exit_code
    fi
    
    # If successful, show the raw output in debug mode
    if [ -s "$temp_output" ]; then
        # Copy to the final output file
        cp "$temp_output" "$output_file"
        
        # Display raw output in debug mode
        if [ "$DEBUG_MODE" = true ]; then
            log_debug "Raw output from $description:"
            log_debug "----------------------------------------"
            cat "$temp_output" | tee -a "$DEBUG_LOG"
            log_debug "----------------------------------------"
        fi
    else
        log_warning "$description returned empty output"
        touch "$output_file"  # Ensure file exists even if empty
    fi
    
    # Clean up temporary file
    rm -f "$temp_output"
    
    return 0
}

# Load endpoints from Excel file
load_endpoints_from_excel() {
    local excel_file="$1"
    local sheet_name="${2:-Endpoints}"
    local skip_if_missing="${3:-false}"  # New parameter to skip if columns missing
    
    # Check if Excel file exists
    if [ ! -f "$excel_file" ]; then
        log_error "Excel file not found: $excel_file"
        return 1
    fi
    
    # Check Excel tools
    log "Checking Excel processing tools..."
    if ! check_excel_tools; then
        log_error "Failed to setup Excel processing tools. Check Python and pip installation."
        return 1
    fi
    
    # Create temporary directory
    local temp_csv="${OUTPUT_DIR}/endpoints.csv"
    
    # Extract data from Excel
    log "Extracting endpoints from Excel file: $excel_file"
    if ! read_endpoints_from_excel "$excel_file" "$temp_csv" "$sheet_name" "$skip_if_missing"; then
        if [ "$skip_if_missing" = "true" ]; then
            log_warning "No endpoint columns found, skipping endpoint extraction"
            return 0  # Return success as we're skipping
        else
            log_error "Failed to extract endpoints from Excel file"
            return 1
        fi
    fi
    
    # Parse endpoints into arrays
    log "Parsing endpoints from CSV"
    parse_endpoints_csv "$temp_csv" "$OUTPUT_DIR"
    
    # Load endpoint arrays
    ORACLE_ENDPOINTS=()
    SERVICEBUS_ENDPOINTS=()
    CUSTOM_ENDPOINTS=()
    
    # Read Oracle endpoints
    if [ -f "${OUTPUT_DIR}/oracle_endpoints.txt" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [ -z "$line" ] && continue
            ORACLE_ENDPOINTS+=("$line")
        done < "${OUTPUT_DIR}/oracle_endpoints.txt"
        log_success "Loaded ${#ORACLE_ENDPOINTS[@]} Oracle endpoints from Excel"
    fi
    
    # Read Service Bus endpoints
    if [ -f "${OUTPUT_DIR}/servicebus_endpoints.txt" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [ -z "$line" ] && continue
            SERVICEBUS_ENDPOINTS+=("$line")
        done < "${OUTPUT_DIR}/servicebus_endpoints.txt"
        log_success "Loaded ${#SERVICEBUS_ENDPOINTS[@]} Service Bus endpoints from Excel"
    fi
    
    # Read Custom endpoints
    if [ -f "${OUTPUT_DIR}/custom_endpoints.txt" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [ -z "$line" ] && continue
            CUSTOM_ENDPOINTS+=("$line")
        done < "${OUTPUT_DIR}/custom_endpoints.txt"
        log_success "Loaded ${#CUSTOM_ENDPOINTS[@]} Custom endpoints from Excel"
    fi
    
    return 0
}

run_tests_from_excel() {
    local excel_file="$1"
    local sheet_name="${2:-Tests}"
    
    # Check if Excel file exists
    if [ ! -f "$excel_file" ]; then
        log_error "Excel file not found: $excel_file"
        return 1
    fi
    
    # Create temporary directory and files
    local temp_csv="${OUTPUT_DIR}/tests.csv"
    
    # For direct CSV files, just copy them
    if [[ "$excel_file" == *.csv ]]; then
        cp "$excel_file" "$temp_csv"
        log "Using CSV file directly: $excel_file"
    else
        log_error "Only CSV files are supported in this version. Please convert your Excel file to CSV."
        return 1
    fi
    
    # Debug: Display the content of the CSV file
    log "CSV file content:"
    cat "$temp_csv" | while read line; do
        log "DEBUG: $line"
    done
    
    # Process each test case
    log "Processing test cases from CSV"
    
    # Skip header and read CSV
    if [ -f "$temp_csv" ]; then
        # Initialize log and summary files for all tests
        > "$SUMMARY_FILE"
        
        log "Starting CSV-based tests at $(date)"
        
        # Keep track of total tests
        local excel_total_tests=0
        local excel_passed_tests=0
        local excel_failed_tests=0
        local excel_skipped_tests=0
        
        # Debug: Add field separator information
        IFS_ORIGINAL=$IFS
        log "Using comma as field separator for CSV parsing"
        
        # Process the CSV file with extra debugging
        tail -n +2 "$temp_csv" | while IFS=',' read -r test_id source_type source destination_type destination enabled rest; do
            # Clean up values
            test_id=$(echo "$test_id" | tr -d '"' | tr -d ' \t\r\n')
            source_type=$(echo "$source_type" | tr -d '"' | tr -d ' \t\r\n' | tr '[:upper:]' '[:lower:]')
            source=$(echo "$source" | tr -d '"' | tr -d ' \t\r\n')
            destination_type=$(echo "$destination_type" | tr -d '"' | tr -d ' \t\r\n' | tr '[:upper:]' '[:lower:]')
            destination=$(echo "$destination" | tr -d '"' | tr -d ' \t\r\n')
            enabled=$(echo "$enabled" | tr -d '"' | tr -d ' \t\r\n')
            
            log "Test values - ID: $test_id, Source: $source_type:$source, Destination: $destination_type:$destination, Enabled: $enabled"
            
            # Enhanced enabled check with fallbacks
            local is_enabled=false
            
            # Check standard values
            if [[ "$enabled" == "yes" || "$enabled" == "Yes" || "$enabled" == "YES" || 
                  "$enabled" == "y" || "$enabled" == "Y" || 
                  "$enabled" == "true" || "$enabled" == "TRUE" || "$enabled" == "True" || 
                  "$enabled" == "1" || "$enabled" == "enabled" || "$enabled" == "ENABLED" ]]; then
                is_enabled=true
            # Special case for empty enabled field (consider it enabled)
            elif [[ -z "$enabled" ]]; then
                is_enabled=true
            fi
            
            # Skip disabled tests
            if [ "$is_enabled" != "true" ]; then
                log "Skipping disabled test: $test_id - $source to $destination (enabled='$enabled')"
                continue
            fi
            
            log "Running test: $test_id - $source to $destination"
            
            EXECUTED_TESTS_FILE="${OUTPUT_DIR}/executed_tests.txt"
            touch "$EXECUTED_TESTS_FILE"

            # Before executing a test, check if it's already been done
            test_key="${source_type}:${source} to ${destination_type}:${destination}"
            if grep -q "^$test_key$" "$EXECUTED_TESTS_FILE"; then
                log "Skipping duplicate test: $test_key (already executed)"
                continue
            fi

            # When executing a test, add it to the tracking file
            echo "$test_key" >> "$EXECUTED_TESTS_FILE"
            # Determine source type if auto, all or blank
            if [[ "$source_type" == "auto" || "$source_type" == "all" || -z "$source_type" ]]; then
                # If source is "all" or blank, we need to test all AKS clusters and VMs
                if [[ "$source" == "all" || -z "$source" ]]; then
                    # First check if we have AKS clusters
                    if [ -s "${OUTPUT_DIR}/aks_clusters.txt" ]; then
                        source_type="aks"
                        log "Source is \"all\" - using AKS cluster type"
                    elif [ -s "${OUTPUT_DIR}/vms.txt" ]; then
                        source_type="vm"
                        log "Source is \"all\" - using VM type"
                    else
                        source_type="vm"  # Default to VM
                        log "No resources found, defaulting to VM type"
                    fi
                elif [[ "$source" == *":"* ]]; then
                    # If it has a colon, its likely a hostname:port
                    source_type="custom"
                elif [[ "$source" == *"aks"* || "$source" == *"AKS"* ]]; then
                    source_type="aks"
                elif [[ "$source" == *"vm"* || "$source" == *"VM"* ]]; then
                    source_type="vm"
                else
                    source_type="vm"  # Default to VM
                fi
                log "Source type set to: $source_type"
            fi
            
            # Determine destination type if auto, all or blank
            if [[ "$destination_type" == "auto" || "$destination_type" == "all" || -z "$destination_type" ]]; then
                # If destination is "all" or blank, we need to test all resource types
                if [[ "$destination" == "all" || -z "$destination" ]]; then
                    # Default to a specific type based on available resources
                    if [ -s "${OUTPUT_DIR}/custom_endpoints.txt" ]; then
                        destination_type="custom"
                        log "Destination is \"all\" - using custom endpoint type"
                    elif [ -s "${OUTPUT_DIR}/sql_servers.txt" ]; then
                        destination_type="sql"
                        log "Destination is \"all\" - using SQL type"
                    elif [ -s "${OUTPUT_DIR}/storage_accounts.txt" ]; then
                        destination_type="storage"
                        log "Destination is \"all\" - using Storage type"
                    elif [ -s "${OUTPUT_DIR}/servicebus.txt" ]; then
                        destination_type="servicebus"
                        log "Destination is \"all\" - using Service Bus type"
                    else
                        destination_type="custom"  # Default to custom
                        log "No resources found, defaulting to custom endpoint type"
                    fi
                elif [[ "$destination" == *":"* ]]; then
                    # Handle hostname:port format
                    if [[ "$destination" == *"oracle"* || "$destination" == *"ora"* ]]; then
                        destination_type="oracle"
                    elif [[ "$destination" == *"servicebus"* || "$destination" == *"sb"* ]]; then
                        destination_type="servicebus"
                    else
                        destination_type="custom"
                    fi
                else
                    # Try to infer from name
                    if [[ "$destination" == *"sql"* ]]; then
                        destination_type="sql"
                    elif [[ "$destination" == *"storage"* || "$destination" == *"blob"* || "$destination" == *"sa"* ]]; then
                        destination_type="storage"
                    elif [[ "$destination" == *"cosmos"* ]]; then
                        destination_type="cosmosdb"
                    elif [[ "$destination" == *"servicebus"* || "$destination" == *"sb"* ]]; then
                        destination_type="servicebus"
                    elif [[ "$destination" == *"eventhub"* || "$destination" == *"eh"* ]]; then
                        destination_type="eventhub"
                    elif [[ "$destination" == *"onprem"* || "$destination" == *"on-prem"* ]]; then
                        destination_type="onprem"
                    elif [[ "$destination" == *"oracle"* ]]; then
                        destination_type="oracle"
                    else
                        destination_type="custom"
                    fi
                fi
                log "Destination type set to: $destination_type"
            fi
            
            # Generic resource validation
            RESOURCE_FOUND=false
            log "Checking if source resource exists: $source_type:$source"
            
            # Adjust resource file name based on type
            case "$source_type" in
                aks)
                    RESOURCE_FILE="${OUTPUT_DIR}/aks_clusters.txt"
                    ;;
                vm)
                    RESOURCE_FILE="${OUTPUT_DIR}/vms.txt"
                    ;;
                *)
                    RESOURCE_FILE=""
                    ;;
            esac
            
            # Check if resource exists
            if [ -n "$RESOURCE_FILE" ] && [ -f "$RESOURCE_FILE" ]; then
                if grep -q "$source" "$RESOURCE_FILE"; then
                    RESOURCE_FOUND=true
                    log "Source resource found: $source_type:$source"
                else
                    log "Warning: Source resource not found: $source_type:$source"
                    # Show available resources for debugging
                    log "Available resources of type $source_type:"
                    cat "$RESOURCE_FILE" | head -5
                fi
            else
                log "No resource file available for type: $source_type"
            fi
            
            # Always set up custom endpoints for testing
            if [ "$destination_type" = "custom" ] && [[ "$destination" == *":"* ]]; then
                # Parse destination for custom endpoint
                host=$(echo "$destination" | cut -d ':' -f1)
                port=$(echo "$destination" | cut -d ':' -f2)
                
                # Add to CUSTOM_ENDPOINTS array for testing
                if ! echo "${CUSTOM_ENDPOINTS[@]}" | grep -q "$host:$port"; then
                    log "Adding custom endpoint to test list: $host:$port"
                    CUSTOM_ENDPOINTS+=("$host:$port:$host")
                fi
                
                # Make sure custom_endpoints.txt exists and contains this endpoint
                mkdir -p "${OUTPUT_DIR}"
                touch "${OUTPUT_DIR}/custom_endpoints.txt"
                if ! grep -q "$host:$port" "${OUTPUT_DIR}/custom_endpoints.txt"; then
                    echo "$host:$port:$host" >> "${OUTPUT_DIR}/custom_endpoints.txt"
                fi
            fi
            
            # Setup parameters for the test
            TEST_FROM="$source_type"
            TEST_TO="$destination_type"
            
            # Check for Network Watcher availability for VM tests
            has_network_watcher=false
            if [[ "$source_type" == "vm" ]]; then
                if check_network_watcher_availability; then
                    has_network_watcher=true
                else
                    log_warning "Network Watcher is not available. VM-to-resource connectivity tests will be skipped."
                fi
            fi
            
            # Execute the appropriate test based on source and destination
            log "EXECUTING TEST: $source_type:$source to $destination_type:$destination"
            TEST_EXECUTED=false
            
            # FIXED SECTION: Specific handling for type-qualified "all" source and "all" destination
            if [[ "$source" == "all" && "$destination" == "all" && "$source_type" != "" && 
                  "$destination_type" != "" && "$source_type" != "all" && "$destination_type" != "all" ]]; then
                # This is a type-qualified wildcard test - only test the specific types 
                log "Testing all $source_type resources against all $destination_type resources ONLY"
                
                # For AKS to specific resource type (storage, servicebus, etc.)
                if [[ "$source_type" == "aks" ]]; then
                    if [ -s "${OUTPUT_DIR}/aks_clusters.txt" ]; then
                        cat "${OUTPUT_DIR}/aks_clusters.txt" | while IFS="|" read -r aks_sub aks_rg aks_name rest; do
                            [ -z "$aks_name" ] && continue
                            log "Testing AKS cluster: $aks_name against all $destination_type resources"
                            
                            # Save original values
                            local original_source="$source"
                            local original_source_type="$source_type"
                            
                            # Set source to specific AKS cluster
                            source="$aks_name"
                            
                            # Test against the specific destination type only
                            case "$destination_type" in
                                sql)
                                    test_aks_to_sql_connectivity
                                    ;;
                                storage)
                                    test_aks_to_storage_connectivity
                                    ;;
                                servicebus)
                                    test_aks_to_servicebus_connectivity
                                    ;;
                                eventhub)
                                    test_aks_to_eventhub_connectivity
                                    ;;
                                cosmosdb)
                                    test_aks_to_cosmosdb_connectivity
                                    ;;
                                onprem)
                                    test_aks_to_onprem_connectivity
                                    ;;
                                custom)
                                    test_aks_to_custom_connectivity
                                    ;;
                                oracle)
                                    test_aks_to_oracle_connectivity
                                    ;;
                                *)
                                    log_warning "Unsupported destination type from AKS: $destination_type"
                                    ;;
                            esac
                            
                            # Restore original values
                            source="$original_source"
                            source_type="$original_source_type"
                        done
                    fi
                    TEST_EXECUTED=true
                
                # For VM to specific resource type
                elif [[ "$source_type" == "vm" && "$has_network_watcher" == "true" ]]; then
                    if [ -s "${OUTPUT_DIR}/vms.txt" ]; then
                        cat "${OUTPUT_DIR}/vms.txt" | while IFS="|" read -r vm_sub vm_rg vm_name vm_id rest; do
                            [ -z "$vm_name" ] && continue
                            log "Testing VM: $vm_name against all $destination_type resources"
                            
                            # Save original values
                            local original_source="$source"
                            local original_source_type="$source_type"
                            
                            # Set source to specific VM
                            source="$vm_name"
                            
                            # Test against the specific destination type only
                            case "$destination_type" in
                                vm)
                                    test_vm_to_vm_connectivity
                                    ;;
                                sql)
                                    test_vm_to_sql_connectivity
                                    ;;
                                storage)
                                    test_vm_to_storage_connectivity
                                    ;;
                                servicebus)
                                    test_vm_to_servicebus_connectivity
                                    ;;
                                eventhub)
                                    test_vm_to_eventhub_connectivity
                                    ;;
                                cosmosdb)
                                    test_vm_to_cosmosdb_connectivity
                                    ;;
                                onprem)
                                    test_vm_to_onprem_connectivity
                                    ;;
                                custom|oracle)
                                    test_custom_endpoint_connectivity
                                    ;;
                                *)
                                    log_warning "Unsupported destination type from VM: $destination_type"
                                    ;;
                            esac
                            
                            # Restore original values
                            source="$original_source"
                            source_type="$original_source_type"
                        done
                    fi
                    TEST_EXECUTED=true
                fi
            
            # Special handling for completely generic "all" source and "all" destination
            elif [[ "$source" == "all" && "$destination" == "all" && 
                   ("$source_type" == "all" || "$source_type" == "auto" || -z "$source_type") && 
                   ("$destination_type" == "all" || "$destination_type" == "auto" || -z "$destination_type") ]]; then
                log "Testing ALL sources against ALL destinations"
                
                # Process all AKS clusters
                if [ -s "${OUTPUT_DIR}/aks_clusters.txt" ]; then
                    log "Testing all AKS clusters against all destinations"
                    cat "${OUTPUT_DIR}/aks_clusters.txt" | while IFS="|" read -r aks_sub aks_rg aks_name rest; do
                        [ -z "$aks_name" ] && continue
                        log "Testing AKS cluster: $aks_name against all destinations"
                        
                        # Test this AKS cluster against all destination types
                        local original_source="$source"
                        local original_source_type="$source_type"
                        source="$aks_name"
                        source_type="aks"
                        
                        if [ -s "${OUTPUT_DIR}/sql_servers.txt" ]; then
                            log "Testing $aks_name against SQL servers"
                            test_aks_to_sql_connectivity
                        fi
                        
                        if [ -s "${OUTPUT_DIR}/storage_accounts.txt" ]; then
                            log "Testing $aks_name against Storage accounts"
                            test_aks_to_storage_connectivity
                        fi
                        
                        if [ -s "${OUTPUT_DIR}/servicebus.txt" ]; then
                            log "Testing $aks_name against Service Bus namespaces"
                            test_aks_to_servicebus_connectivity
                        fi
                        
                        if [ -s "${OUTPUT_DIR}/eventhub.txt" ]; then
                            log "Testing $aks_name against Event Hub namespaces"
                            test_aks_to_eventhub_connectivity
                        fi
                        
                        if [ -s "${OUTPUT_DIR}/cosmosdb.txt" ]; then
                            log "Testing $aks_name against Cosmos DB accounts"
                            test_aks_to_cosmosdb_connectivity
                        fi
                        
                        if [ -s "${OUTPUT_DIR}/onprem_networks.txt" ]; then
                            log "Testing $aks_name against on-premises networks"
                            test_aks_to_onprem_connectivity
                        fi
                        
                        if [ ${#CUSTOM_ENDPOINTS[@]} -gt 0 ] || [ -s "${OUTPUT_DIR}/custom_endpoints.txt" ]; then
                            log "Testing $aks_name against custom endpoints"
                            test_aks_to_custom_connectivity
                        fi
                        
                        if [ ${#ORACLE_ENDPOINTS[@]} -gt 0 ]; then
                            log "Testing $aks_name against Oracle endpoints"
                            test_aks_to_oracle_connectivity
                        fi
                        
                        # Restore original values
                        source="$original_source"
                        source_type="$original_source_type"
                    done
                fi
                
                # Process all VMs (no sampling)
                if [ -s "${OUTPUT_DIR}/vms.txt" ] && [ "$has_network_watcher" = true ]; then
                    log "Testing all VMs against all destinations"
                    cat "${OUTPUT_DIR}/vms.txt" | while IFS="|" read -r vm_sub vm_rg vm_name vm_id rest; do
                        [ -z "$vm_name" ] && continue
                        log "Testing VM: $vm_name against all destinations"
                        
                        # Test this VM against all destination types
                        local original_source="$source"
                        local original_source_type="$source_type"
                        source="$vm_name"
                        source_type="vm"
                        
                        if [ -s "${OUTPUT_DIR}/vms.txt" ]; then
                            log "Testing $vm_name against other VMs"
                            test_vm_to_vm_connectivity
                        fi
                        
                        if [ -s "${OUTPUT_DIR}/sql_servers.txt" ]; then
                            log "Testing $vm_name against SQL servers"
                            test_vm_to_sql_connectivity
                        fi
                        
                        if [ -s "${OUTPUT_DIR}/storage_accounts.txt" ]; then
                            log "Testing $vm_name against Storage accounts"
                            test_vm_to_storage_connectivity
                        fi
                        
                        if [ -s "${OUTPUT_DIR}/servicebus.txt" ]; then
                            log "Testing $vm_name against Service Bus namespaces"
                            test_vm_to_servicebus_connectivity
                        fi
                        
                        if [ -s "${OUTPUT_DIR}/eventhub.txt" ]; then
                            log "Testing $vm_name against Event Hub namespaces"
                            test_vm_to_eventhub_connectivity
                        fi
                        
                        if [ -s "${OUTPUT_DIR}/cosmosdb.txt" ]; then
                            log "Testing $vm_name against Cosmos DB accounts"
                            test_vm_to_cosmosdb_connectivity
                        fi
                        
                        if [ -s "${OUTPUT_DIR}/onprem_networks.txt" ]; then
                            log "Testing $vm_name against on-premises networks"
                            test_vm_to_onprem_connectivity
                        fi
                        
                        if [ ${#CUSTOM_ENDPOINTS[@]} -gt 0 ] || [ -s "${OUTPUT_DIR}/custom_endpoints.txt" ]; then
                            log "Testing $vm_name against custom endpoints"
                            test_custom_endpoint_connectivity
                        fi
                        
                        # Restore original values
                        source="$original_source"
                        source_type="$original_source_type"
                    done
                fi
                
                TEST_EXECUTED=true
                
            # Special handling for generic "all" AKS clusters with specified destination
            elif [[ "$source_type" == "aks" && "$source" == "all" && "$TEST_EXECUTED" != "true" ]]; then
                log "Testing all AKS clusters against $destination_type:$destination"
                
                if [ -s "${OUTPUT_DIR}/aks_clusters.txt" ]; then
                    cat "${OUTPUT_DIR}/aks_clusters.txt" | while IFS="|" read -r aks_sub aks_rg aks_name rest; do
                        [ -z "$aks_name" ] && continue
                        log "Testing AKS cluster: $aks_name against $destination_type:$destination"
                        
                        # Set source to the specific AKS cluster
                        local original_source="$source"
                        local original_source_type="$source_type"
                        source="$aks_name"
                        
                        # Test against the specified destination type
                        case "$destination_type" in
                            sql)
                                test_aks_to_sql_connectivity
                                ;;
                            storage)
                                test_aks_to_storage_connectivity
                                ;;
                            servicebus)
                                test_aks_to_servicebus_connectivity
                                ;;
                            eventhub)
                                test_aks_to_eventhub_connectivity
                                ;;
                            cosmosdb)
                                test_aks_to_cosmosdb_connectivity
                                ;;
                            onprem)
                                test_aks_to_onprem_connectivity
                                ;;
                            custom)
                                test_aks_to_custom_connectivity
                                ;;
                            oracle)
                                test_aks_to_oracle_connectivity
                                ;;
                        esac
                        
                        # Restore original values
                        source="$original_source"
                        source_type="$original_source_type"
                    done
                    
                    TEST_EXECUTED=true
                fi
                
            # Special handling for all VMs with specified destination
            elif [[ "$source_type" == "vm" && "$source" == "all" && "$TEST_EXECUTED" != "true" && "$has_network_watcher" = true ]]; then
                log "Testing all VMs against $destination_type:$destination"
                
                if [ -s "${OUTPUT_DIR}/vms.txt" ]; then
                    cat "${OUTPUT_DIR}/vms.txt" | while IFS="|" read -r vm_sub vm_rg vm_name vm_id rest; do
                        [ -z "$vm_name" ] && continue
                        log "Testing VM: $vm_name against $destination_type:$destination"
                        
                        # Set source to the specific VM
                        local original_source="$source"
                        local original_source_type="$source_type"
                        source="$vm_name"
                        
                        # Test against the specified destination type
                        case "$destination_type" in
                            vm)
                                test_vm_to_vm_connectivity
                                ;;
                            sql)
                                test_vm_to_sql_connectivity
                                ;;
                            storage)
                                test_vm_to_storage_connectivity
                                ;;
                            servicebus)
                                test_vm_to_servicebus_connectivity
                                ;;
                            eventhub)
                                test_vm_to_eventhub_connectivity
                                ;;
                            cosmosdb)
                                test_vm_to_cosmosdb_connectivity
                                ;;
                            onprem)
                                test_vm_to_onprem_connectivity
                                ;;
                            custom|oracle)
                                test_custom_endpoint_connectivity
                                ;;
                        esac
                        
                        # Restore original values
                        source="$original_source"
                        source_type="$original_source_type"
                    done
                    
                    TEST_EXECUTED=true
                fi
                
            # If none of the special cases match, run standard tests
            elif [[ "$TEST_EXECUTED" != "true" ]]; then
                case "$source_type" in
                    vm)
                        if [ "$has_network_watcher" = true ]; then
                            case "$destination_type" in
                                vm)
                                    log "Running VM to VM connectivity test"
                                    test_vm_to_vm_connectivity
                                    TEST_EXECUTED=true
                                    ;;
                                sql)
                                    log "Running VM to SQL connectivity test"
                                    test_vm_to_sql_connectivity
                                    TEST_EXECUTED=true
                                    ;;
                                storage)
                                    log "Running VM to Storage connectivity test"
                                    test_vm_to_storage_connectivity
                                    TEST_EXECUTED=true
                                    ;;
                                servicebus)
                                    log "Running VM to Service Bus connectivity test"
                                    test_vm_to_servicebus_connectivity
                                    TEST_EXECUTED=true
                                    ;;
                                eventhub)
                                    log "Running VM to Event Hub connectivity test"
                                    test_vm_to_eventhub_connectivity
                                    TEST_EXECUTED=true
                                    ;;
                                cosmosdb)
                                    log "Running VM to Cosmos DB connectivity test"
                                    test_vm_to_cosmosdb_connectivity
                                    TEST_EXECUTED=true
                                    ;;
                                onprem)
                                    log "Running VM to on-premises connectivity test"
                                    test_vm_to_onprem_connectivity
                                    TEST_EXECUTED=true
                                    ;;
                                custom|oracle)
                                    log "Running VM to custom endpoint connectivity test"
                                    test_custom_endpoint_connectivity
                                    TEST_EXECUTED=true
                                    ;;
                                *)
                                    log_warning "Unsupported destination type from VM: $destination_type"
                                    ;;
                            esac
                        fi
                        ;;
                    aks)
                        case "$destination_type" in
                            sql)
                                log "Running AKS to SQL connectivity test"
                                test_aks_to_sql_connectivity
                                TEST_EXECUTED=true
                                ;;
                            storage)
                                log "Running AKS to Storage connectivity test"
                                test_aks_to_storage_connectivity
                                TEST_EXECUTED=true
                                ;;
                            servicebus)
                                log "Running AKS to Service Bus connectivity test"
                                test_aks_to_servicebus_connectivity
                                TEST_EXECUTED=true
                                ;;
                            eventhub)
                                log "Running AKS to Event Hub connectivity test"
                                test_aks_to_eventhub_connectivity
                                TEST_EXECUTED=true
                                ;;
                            cosmosdb)
                                log "Running AKS to Cosmos DB connectivity test"
                                test_aks_to_cosmosdb_connectivity
                                TEST_EXECUTED=true
                                ;;
                            onprem)
                                log "Running AKS to on-premises connectivity test"
                                test_aks_to_onprem_connectivity
                                TEST_EXECUTED=true
                                ;;
                            custom)
                                log "Running AKS to custom endpoint connectivity test"
                                test_aks_to_custom_connectivity
                                TEST_EXECUTED=true
                                ;;
                            oracle)
                                log "Running AKS to Oracle connectivity test"
                                test_aks_to_oracle_connectivity
                                TEST_EXECUTED=true
                                ;;
                            *)
                                log_warning "Unsupported destination type from AKS: $destination_type"
                                ;;
                        esac
                        ;;
                    *)
                        log_warning "Unsupported source type: $source_type"
                        ;;
                esac
            fi
            
           if [ "$TEST_EXECUTED" = false ]; then
            log_warning "Test could not be executed: $test_id - $source_type:$source to $destination_type:$destination"
            echo "$source_type:$source to $destination_type:$destination - SKIPPED - Test could not be executed" >> "$SUMMARY_FILE"
            excel_skipped_tests=$((excel_skipped_tests + 1))
        else
            log "TEST COMPLETED: $source_type:$source to $destination_type:$destination"
            
            # Count results for summary
            excel_total_tests=$((excel_total_tests + 1))
            
            # Special handling for wildcard tests ("all")
            if [[ "$source" == "all" || "$destination" == "all" ]]; then
                # For wildcard tests, check if any specific resource tests were successful
                # This will handle AKS:myAKSCluster to Storage:teststorage3847 SUCCESS cases
                if grep -q "SUCCESS" "$SUMMARY_FILE"; then
                    log_success "Wildcard test $test_id completed successfully with at least one successful resource test"
                    excel_passed_tests=$((excel_passed_tests + 1))
                    # We don't need to add another entry for the wildcard itself
                else
                    log_warning "No successful specific resource tests found for wildcard test: $test_id"
                   # echo "$source_type:$source to $destination_type:$destination - FAILED - No successful resource tests" >> "$SUMMARY_FILE"
                    excel_failed_tests=$((excel_failed_tests + 1))
                fi
            else
                # Regular non-wildcard tests
                if grep -q "$source to $destination - SUCCESS" "$SUMMARY_FILE" || grep -q "$source_type:$source to $destination_type:$destination - SUCCESS" "$SUMMARY_FILE"; then
                    excel_passed_tests=$((excel_passed_tests + 1))
                elif grep -q "$source to $destination - FAILED" "$SUMMARY_FILE" || grep -q "$source_type:$source to $destination_type:$destination - FAILED" "$SUMMARY_FILE"; then
                    excel_failed_tests=$((excel_failed_tests + 1))
                elif grep -q "$source to $destination - SKIPPED\|$source to $destination - NOT AVAILABLE\|$source to $destination - PARTIAL" "$SUMMARY_FILE"; then
                    excel_skipped_tests=$((excel_skipped_tests + 1))
                else
                    # If no result was added to the summary file, add one
                    log_warning "No result found in summary file for test: $test_id"
                   # echo "$source_type:$source to $destination_type:$destination - SKIPPED - No result reported" >> "$SUMMARY_FILE"
                    excel_skipped_tests=$((excel_skipped_tests + 1))
                fi
            fi
        fi
        done
        
        # Restore original IFS
        IFS=$IFS_ORIGINAL
        
        # Update global counters for the report
        TOTAL_TESTS=$excel_total_tests
        PASSED_TESTS=$excel_passed_tests
        FAILED_TESTS=$excel_failed_tests
        SKIPPED_TESTS=$excel_skipped_tests
        
        log "Tests summary: Total=$TOTAL_TESTS, Passed=$PASSED_TESTS, Failed=$FAILED_TESTS, Skipped=$SKIPPED_TESTS"
        
        # Generate a single consolidated report for all tests
        log "Generating consolidated report for all CSV-based tests"
        generate_report "CSV-based Connectivity Tests: $(basename "$excel_file")"
        
        log_success "Completed CSV-based tests"
    else
        log_error "No test cases CSV file found: $temp_csv"
        return 1
    fi
    
    return 0
}

# Function to display usage information
usage() {
    echo -e "${BOLD}Azure Infra Verification Test${NC}"
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -s, --subscription ID     Azure Subscription ID (default: auto-discover all accessible subscriptions)"
    echo "  -g, --resource-group NAME Resource Group name (default: auto-discover all resource groups)"
    echo "  -l, --location LOCATION   Azure Region (default: auto-discover resources in all regions)"
    echo "  -o, --output-dir PATH     Output directory (default: azure_connectivity_test_TIMESTAMP)"
    echo "  --report-path PATH        Specify a custom path for the HTML report"
    echo "  --report-prefix PREFIX    Add a prefix to the report filename"
    echo "  --excel FILE              Read endpoints and test cases from Excel file"
    echo "  --sheet NAME              Sheet name in Excel file (default: Endpoints or Tests)"
    echo "  --run-tests               Run tests from Excel file"
    echo
    echo "Test Selection Options:"
    echo "  --test-from TYPE          Only test from this resource type (aks, vm, all)"
    echo "  --test-to TYPE            Only test to this resource type (sql, storage, servicebus, eventhub, cosmosdb, onprem,oracle,custom all)"
    echo
    echo "Resource Type Options:"
    echo "  --oracle ENDPOINT:PORT    Oracle endpoint to test connectivity to (can be used multiple times)"
    echo "  --servicebus ENDPOINT     Service Bus namespace to test connectivity to (can be used multiple times)"
    echo "  --endpoint ENDPOINT:PORT:DESC   Custom endpoint to test connectivity to (can be used multiple times)"
    echo
    echo "Configuration Options:"
    echo "  --discovery-timeout SECS  Timeout for discovery operations in seconds (default: 60)"
    echo "  --parallel N              Maximum number of parallel tests (default: 5)"
    echo "  --no-vms                  Skip VM connectivity tests"
    echo "  --no-storage              Skip Storage Account connectivity tests"
    echo "  --no-sql                  Skip SQL Server connectivity tests"
    echo "  --no-aks                  Skip AKS connectivity tests"
    echo "  --no-servicebus           Skip Service Bus connectivity tests"
    echo "  --no-eventhub             Skip Event Hub connectivity tests"
    echo "  --no-cosmosdb             Skip Cosmos DB connectivity tests"
    echo "  --no-onprem               Skip on-premises connectivity tests"
    echo "  --debug                   Enable debug mode to show raw Azure CLI output (default: true)"
    echo "  --no-debug                Disable debug mode"
    echo "  --skip-cleanup            Skip cleanup of temporary resources"
    echo "  -h, --help                Show this help message"
    echo
    echo "Examples:"
    echo "  $0                                      # Auto-discover and test all resources"
    echo "  $0 -s <subscription-id>                 # Test specific subscription"
    echo "  $0 --test-from aks --test-to storage    # Only test connectivity from AKS to Storage"
    echo "  $0 --excel connectivity.xlsx --run-tests # Run tests defined in Excel file"
    exit 1
}

# Main function
main() {
    # Default values for test selection
    TEST_FROM="all"
    TEST_TO="all"
    REPORT_PATH=""
    REPORT_PREFIX=""
    EXCEL_FILE=""
    EXCEL_SHEET=""
    RUN_TESTS=false

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--subscription)
                SUBSCRIPTION_ID="$2"
                shift 2
                ;;
            -g|--resource-group)
                RESOURCE_GROUP="$2"
                shift 2
                ;;
            -l|--location)
                LOCATION="$2"
                shift 2
                ;;
            -o|--output-dir)
                OUTPUT_DIR="$2"
                # Update log file paths
                update_log_paths
                shift 2
                ;;
            --test-from)
                TEST_FROM="$2"
                shift 2
                ;;
            --test-to)
                TEST_TO="$2"
                shift 2
                ;;
            --report-path)
                REPORT_PATH="$2"
                shift 2
                ;;
            --report-prefix)
                REPORT_PREFIX="$2"
                shift 2
                ;;
            --excel)
                EXCEL_FILE="$2"
                shift 2
                ;;
            --sheet)
                EXCEL_SHEET="$2"
                shift 2
                ;;
            --run-tests)
                RUN_TESTS=true
                shift
                ;;
            --oracle)
                ORACLE_ENDPOINTS+=("$2")
                shift 2
                ;;
            --servicebus)
                SERVICEBUS_ENDPOINTS+=("$2")
                shift 2
                ;;
            --endpoint)
                CUSTOM_ENDPOINTS+=("$2")
                shift 2
                ;;
            --discovery-timeout)
                DISCOVERY_TIMEOUT="$2"
                shift 2
                ;;
            --parallel)
                MAX_PARALLEL_TESTS="$2"
                shift 2
                ;;
            --no-vms)
                TEST_VMS="false"
                shift
                ;;
            --no-storage)
                TEST_STORAGE="false"
                shift
                ;;
            --no-sql)
                TEST_SQL="false"
                shift
                ;;
            --no-aks)
                TEST_AKS="false"
                shift
                ;;
            --no-servicebus)
                TEST_SERVICEBUS="false"
                shift
                ;;
            --no-eventhub)
                TEST_EVENTHUB="false"
                shift
                ;;
            --no-cosmosdb)
                TEST_COSMOSDB="false"
                shift
                ;;
            --no-onprem)
                TEST_ONPREM="false"
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                shift
                ;;
            --no-debug)
                DEBUG_MODE=false
                shift
                ;;
            --skip-cleanup)
                SKIP_CLEANUP="true"
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    # Update report paths if custom location provided
    if [ -n "$REPORT_PATH" ]; then
        mkdir -p "$REPORT_PATH"
        REPORT_FILE="${REPORT_PATH}/${REPORT_PREFIX}connectivity_report.html"
    fi
    
    # Create output directory
    mkdir -p "$OUTPUT_DIR"
    chmod 755 "$OUTPUT_DIR" 2>/dev/null || true
    
    # Initialize log and summary files
    > "$LOG_FILE"
    > "$DEBUG_LOG"
    > "$SUMMARY_FILE"
    > "$ERROR_LOG"
    
    # Display banner
    echo -e "${BOLD}${BLUE}======================================================${NC}"
    echo -e "${BOLD}${BLUE}   Azure Infra Verification Test Tool v2.0   ${NC}"
    echo -e "${BOLD}${BLUE}======================================================${NC}"
    echo
    echo -e "${BOLD}Output directory:${NC} $OUTPUT_DIR"
    echo -e "${BOLD}Log file:${NC} $LOG_FILE"
    echo -e "${BOLD}Debug log:${NC} $DEBUG_LOG"
    echo -e "${BOLD}Report file:${NC} $REPORT_FILE"
    
    if [ -n "$EXCEL_FILE" ]; then
        echo -e "${BOLD}Excel file:${NC} $EXCEL_FILE"
    fi
    
    if [ "$RUN_TESTS" = true ]; then
        echo -e "${BOLD}Running tests:${NC} Yes"
    else
        echo -e "${BOLD}Test from:${NC} $TEST_FROM"
        echo -e "${BOLD}Test to:${NC} $TEST_TO"
    fi
    
    echo -e "${BOLD}Debug mode:${NC} $([ "$DEBUG_MODE" = true ] && echo "Enabled" || echo "Disabled")"
    echo
    
    # Log start time
    log "Starting Azure Infra verification at $(date)"
    
    # Check prerequisites
    check_prerequisites
    
    # Check Azure CLI authentication
    check_azure_auth
    
    # Process Excel file if provided
    if [ -n "$EXCEL_FILE" ]; then
        # Load endpoints from Excel if provided
        if [ -f "$EXCEL_FILE" ]; then
            if [ -z "$EXCEL_SHEET" ]; then
                EXCEL_SHEET="Endpoints"
            fi
            
            load_endpoints_from_excel "$EXCEL_FILE" "$EXCEL_SHEET"
        else
            log_error "Excel file not found: $EXCEL_FILE"
            exit 1
        fi
    fi
    
    # Run tests from Excel if requested
    if [ "$RUN_TESTS" = true ]; then
        if [ -n "$EXCEL_FILE" ]; then
            EXCEL_SHEET="Tests"
             # Discovery phase - Add this section to run discovery before tests
            log "${BOLD}Starting resource discovery...${NC}"
            discover_subscriptions
            discover_resource_groups
            
            # Discover resources based on what we need to test
            discover_vms
            discover_aks
            discover_sql
            discover_storage
            discover_servicebus
            discover_eventhub
            discover_cosmosdb
            discover_hybrid_connectivity
            detect_onprem_networks
            
            # Check Network Watcher availability
            has_network_watcher=false
            if check_network_watcher_availability; then
                has_network_watcher=true
            else
                log_warning "Network Watcher is not available. VM-to-resource connectivity tests will be skipped."
            fi
            run_tests_from_excel "$EXCEL_FILE" "$EXCEL_SHEET"
            
            # When we complete the Excel-based tests, we don't need to continue
            # since a final report has already been generated
            log_success "Excel-based testing completed"
            
            # Display final stats
            echo
            echo -e "${BOLD}${GREEN}======================================================${NC}"
            echo -e "${BOLD}${GREEN}    Verification completed                        ${NC}"
            echo -e "${BOLD}${GREEN}======================================================${NC}"
            echo
            echo -e "${BOLD}Tests performed:${NC} $TOTAL_TESTS"
            echo -e "${BOLD}Tests passed:${NC} ${GREEN}$PASSED_TESTS${NC}"
            echo -e "${BOLD}Tests failed:${NC} ${RED}$FAILED_TESTS${NC}"
            echo -e "${BOLD}Tests skipped:${NC} ${YELLOW}$SKIPPED_TESTS${NC}"
            echo
            echo -e "${BOLD}Report:${NC} $REPORT_FILE"
            echo -e "${BOLD}Log:${NC} $LOG_FILE"
            echo -e "${BOLD}Summary:${NC} $SUMMARY_FILE"
            echo
            
            # Return success if no tests failed
            if [ "$FAILED_TESTS" -eq 0 ]; then
                return 0
            else
                return 1
            fi
        else
            log_error "Excel file not provided for running tests"
            exit 1
        fi
    fi
    
    # Discovery phase
    log "${BOLD}Starting resource discovery...${NC}"
    discover_subscriptions
    discover_resource_groups
    
    # Discover resources based on what we need to test
    if [[ "$TEST_FROM" == "all" || "$TEST_FROM" == "vm" || "$TEST_TO" == "vm" ]]; then
        discover_vms
    fi
    
    if [[ "$TEST_FROM" == "all" || "$TEST_FROM" == "aks" || "$TEST_TO" == "aks" ]]; then
        discover_aks
    fi
    
    if [[ "$TEST_FROM" == "all" || "$TEST_TO" == "all" || "$TEST_TO" == "sql" ]]; then
        discover_sql
    fi
    
    if [[ "$TEST_FROM" == "all" || "$TEST_TO" == "all" || "$TEST_TO" == "storage" ]]; then
        discover_storage
    fi
    
    if [[ "$TEST_FROM" == "all" || "$TEST_TO" == "all" || "$TEST_TO" == "servicebus" ]]; then
        discover_servicebus
    fi
    
    if [[ "$TEST_FROM" == "all" || "$TEST_TO" == "all" || "$TEST_TO" == "eventhub" ]]; then
        discover_eventhub
    fi
    
    if [[ "$TEST_FROM" == "all" || "$TEST_TO" == "all" || "$TEST_TO" == "cosmosdb" ]]; then
        discover_cosmosdb
    fi
    
    if [[ "$TEST_FROM" == "all" || "$TEST_TO" == "all" || "$TEST_TO" == "onprem" ]]; then
        discover_hybrid_connectivity
        detect_onprem_networks
    fi
    
    # Check if Network Watcher is available for non-AKS tests
    has_network_watcher=false
    if [[ "$TEST_FROM" == "all" || "$TEST_FROM" == "vm" ]]; then
        if check_network_watcher_availability; then
            has_network_watcher=true
        else
            log_warning "Network Watcher is not available. VM-to-resource connectivity tests will be skipped."
        fi
    fi
    
    # Testing phase
    log "${BOLD}Starting connectivity tests...${NC}"
    
    # Run VM-based connectivity tests if Network Watcher is available and VM tests are requested
    if [ "$has_network_watcher" = true ] && [[ "$TEST_FROM" == "all" || "$TEST_FROM" == "vm" ]]; then
        if [ "$TEST_VMS" = "true" ] && [[ "$TEST_TO" == "all" || "$TEST_TO" == "vm" ]]; then
            test_vm_to_vm_connectivity
        fi
        
        if [ "$TEST_VMS" = "true" ] && [ "$TEST_SQL" = "true" ] && [[ "$TEST_TO" == "all" || "$TEST_TO" == "sql" ]]; then
            test_vm_to_sql_connectivity
        fi
        
        if [ "$TEST_VMS" = "true" ] && [ "$TEST_STORAGE" = "true" ] && [[ "$TEST_TO" == "all" || "$TEST_TO" == "storage" ]]; then
            test_vm_to_storage_connectivity
        fi
        
        if [ "$TEST_VMS" = "true" ] && [ "$TEST_SERVICEBUS" = "true" ] && [[ "$TEST_TO" == "all" || "$TEST_TO" == "servicebus" ]]; then
            test_vm_to_servicebus_connectivity
        fi
        
        if [ "$TEST_VMS" = "true" ] && [ "$TEST_EVENTHUB" = "true" ] && [[ "$TEST_TO" == "all" || "$TEST_TO" == "eventhub" ]]; then
            test_vm_to_eventhub_connectivity
        fi
        
        if [ "$TEST_VMS" = "true" ] && [ "$TEST_COSMOSDB" = "true" ] && [[ "$TEST_TO" == "all" || "$TEST_TO" == "cosmosdb" ]]; then
            test_vm_to_cosmosdb_connectivity
        fi
        
        if [ "$TEST_VMS" = "true" ] && [ "$TEST_ONPREM" = "true" ] && [[ "$TEST_TO" == "all" || "$TEST_TO" == "onprem" ]]; then
            test_vm_to_onprem_connectivity
        fi
        
        if [ "$TEST_VMS" = "true" ] && [[ "$TEST_TO" == "all" || "$TEST_TO" == "custom" ]]; then
            test_custom_endpoint_connectivity
        fi
    fi
    
    # Run AKS-based connectivity tests if AKS tests are requested
    if [ "$TEST_AKS" = "true" ] && [[ "$TEST_FROM" == "all" || "$TEST_FROM" == "aks" ]]; then
        if [ "$TEST_SQL" = "true" ] && [[ "$TEST_TO" == "all" || "$TEST_TO" == "sql" ]]; then
            test_aks_to_sql_connectivity
        fi
        
        if [ "$TEST_STORAGE" = "true" ] && [[ "$TEST_TO" == "all" || "$TEST_TO" == "storage" ]]; then
            test_aks_to_storage_connectivity
        fi
        
        if [ "$TEST_SERVICEBUS" = "true" ] && [[ "$TEST_TO" == "all" || "$TEST_TO" == "servicebus" ]]; then
            test_aks_to_servicebus_connectivity
        fi
        
        if [ "$TEST_EVENTHUB" = "true" ] && [[ "$TEST_TO" == "all" || "$TEST_TO" == "eventhub" ]]; then
            test_aks_to_eventhub_connectivity
        fi
        
        if [ "$TEST_COSMOSDB" = "true" ] && [[ "$TEST_TO" == "all" || "$TEST_TO" == "cosmosdb" ]]; then
            test_aks_to_cosmosdb_connectivity
        fi
        
        if [ "$TEST_ONPREM" = "true" ] && [[ "$TEST_TO" == "all" || "$TEST_TO" == "onprem" ]]; then
            test_aks_to_onprem_connectivity
        fi
        
        if [[ "$TEST_TO" == "all" || "$TEST_TO" == "oracle" ]]; then
            test_aks_to_oracle_connectivity
        fi

        if [[ "$TEST_TO" == "all" || "$TEST_TO" == "custom" ]]; then
            test_aks_to_custom_connectivity
        fi
    fi
    
    # Generate report
    generate_report
    
    # Log completion
    log "${BOLD}Azure Infra verification completed at $(date)${NC}"
    echo
    echo -e "${BOLD}${GREEN}======================================================${NC}"
    echo -e "${BOLD}${GREEN}    Verification completed                        ${NC}"
    echo -e "${BOLD}${GREEN}======================================================${NC}"
    echo
    echo -e "${BOLD}Tests performed:${NC} $TOTAL_TESTS"
    echo -e "${BOLD}Tests passed:${NC} ${GREEN}$PASSED_TESTS${NC}"
    echo -e "${BOLD}Tests failed:${NC} ${RED}$FAILED_TESTS${NC}"
    echo -e "${BOLD}Tests skipped:${NC} ${YELLOW}$SKIPPED_TESTS${NC}"
    echo
    echo -e "${BOLD}Report:${NC} $REPORT_FILE"
    echo -e "${BOLD}Log:${NC} $LOG_FILE"
    echo -e "${BOLD}Summary:${NC} $SUMMARY_FILE"
    echo
    
    # Return success if no tests failed
    if [ "$FAILED_TESTS" -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# Run main function
main "$@"