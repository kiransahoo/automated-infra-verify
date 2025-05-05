#!/bin/bash

# Text colors and formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Configuration variables - modify or pass as parameters
SUBSCRIPTION_ID=""
RESOURCE_GROUP=""
LOCATION=""
DISCOVERY_TIMEOUT=60  # Default timeout for discovery operations
TIMEOUT_SECONDS=30    # Default timeout for Network Watcher operations
MAX_PARALLEL_TESTS=5
DEBUG_MODE=true      # Set to true to enable debug output
SKIP_CLEANUP="false"  # Skip cleanup of temporary resources

# Test flags - enable/disable specific tests
TEST_VMS="true"
TEST_STORAGE="true"
TEST_SQL="true"
TEST_AKS="true"
TEST_SERVICEBUS="true"
TEST_EVENTHUB="true"
TEST_COSMOSDB="true"
TEST_ONPREM="true"

# Test status tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# Special resources to test - add your own resources here
ORACLE_ENDPOINTS=()  # Format: "hostname:port:resourcegroup:subscriptionid"
SERVICEBUS_ENDPOINTS=() # Format: "namespace.servicebus.windows.net:5671:resourcegroup:subscriptionid"
CUSTOM_ENDPOINTS=() # Format: "hostname:port:description:resourcegroup:subscriptionid"

# Flag to indicate if jq is available
JQ_AVAILABLE=false

# Logging and output files
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="azure_connectivity_test_${TIMESTAMP}"
LOG_FILE="${OUTPUT_DIR}/connectivity_test.log"
DEBUG_LOG="${OUTPUT_DIR}/azure_cli_debug.log"
REPORT_FILE="${OUTPUT_DIR}/connectivity_report.html"
SUMMARY_FILE="${OUTPUT_DIR}/connectivity_summary.log"
CONFIG_FILE="${OUTPUT_DIR}/test_config.json"
ERROR_LOG="${OUTPUT_DIR}/error.log"

# Function to update log paths if output directory changes
update_log_paths() {
    LOG_FILE="${OUTPUT_DIR}/connectivity_test.log"
    DEBUG_LOG="${OUTPUT_DIR}/azure_cli_debug.log"
    REPORT_FILE="${OUTPUT_DIR}/connectivity_report.html"
    SUMMARY_FILE="${OUTPUT_DIR}/connectivity_summary.log"
    CONFIG_FILE="${OUTPUT_DIR}/test_config.json"
    ERROR_LOG="${OUTPUT_DIR}/error.log"
}

# Function to log messages
log() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

# Function to log success
log_success() {
    log "${GREEN}${1}${NC}" "SUCCESS"
    ((PASSED_TESTS++))
}

# Function to log error
log_error() {
    log "${RED}${1}${NC}" "ERROR"
    ((FAILED_TESTS++))
}

# Function to log warning
log_warning() {
    log "${YELLOW}${1}${NC}" "WARNING"
}

# Function to log debug messages
log_debug() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    if [ "$DEBUG_MODE" = true ]; then
        echo -e "${timestamp} [DEBUG] ${message}" | tee -a "$DEBUG_LOG"
    else
        echo -e "${timestamp} [DEBUG] ${message}" >> "$DEBUG_LOG"
    fi
}

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

# Function to log test result
log_test_result() {
    local test_name="$1"
    local status="$2"
    local details="$3"
    local category="$4"
    local source="$5"
    local destination="$6"
    
    # Log to console based on status
    case "$status" in
        PASSED)
            log_success "$test_name: $details"
            ;;
        FAILED)
            log_error "$test_name: $details"
            ;;
        SKIPPED)
            log_warning "$test_name: $details"
            ((SKIPPED_TESTS++))
            ;;
        *)
            log "$test_name: $details" "$status"
            ;;
    esac
    
    # Track test counts
    ((TOTAL_TESTS++))
    
    # Add to summary file in a format compatible with the report generator
    if [ "$status" = "PASSED" ]; then
        echo "$source to $destination - SUCCESS - $details" >> "$SUMMARY_FILE"
    else
        echo "$source to $destination - FAILED" >> "$SUMMARY_FILE"
    fi
}

# Function to check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check for Azure CLI
    if ! command -v az >/dev/null 2>&1; then
        log_error "Azure CLI not found. Please install it first."
        log "For installation instructions, visit: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    fi
    
    # Check for jq
    if command -v jq >/dev/null 2>&1; then
        JQ_AVAILABLE=true
        log_success "jq is available and will be used for JSON processing."
    else
        log_warning "jq not found. The script will use fallback methods for JSON processing."
    fi
    
    # Check for awk (used in fallback methods)
    if ! command -v awk >/dev/null 2>&1; then
        log_warning "awk not found. Some fallback processing methods might not work."
    fi
    
    # Check for kubectl if testing AKS
    if [[ "$TEST_AKS" == "true" ]] && ! command -v kubectl &> /dev/null; then
        log_warning "kubectl is not installed. AKS connectivity tests may fail."
    fi
    
    log_success "Prerequisites check completed."
}

# Function to check Azure CLI authentication
check_azure_auth() {
    log "Checking Azure CLI authentication..."
    
    # Check if logged in
    local auth_output="${OUTPUT_DIR}/auth_check.json"
    if ! run_az_command "az account show" "$auth_output" "${OUTPUT_DIR}/auth_check.err" "$DISCOVERY_TIMEOUT" "Azure auth check"; then
        log "Not authenticated to Azure. Attempting to login..."
        run_az_command "az login --use-device-code" "${OUTPUT_DIR}/login.json" "${OUTPUT_DIR}/login.err" 300 "Azure login"
        
        # Check if login was successful
        if ! run_az_command "az account show" "${OUTPUT_DIR}/auth_check_after_login.json" "${OUTPUT_DIR}/auth_check_after_login.err" "$DISCOVERY_TIMEOUT" "Azure auth check after login"; then
            log_error "Failed to authenticate to Azure. Please run 'az login' manually."
            exit 1
        else
            log_success "Successfully authenticated to Azure."
        fi
    else
        account=$(az account show --query 'name' -o tsv 2>/dev/null || echo "Unknown account")
        log_success "Already authenticated to Azure as '$account'"
    fi
    
    # Set subscription if provided
    if [ -n "$SUBSCRIPTION_ID" ]; then
        log "Setting subscription to $SUBSCRIPTION_ID..."
        if run_az_command "az account set --subscription $SUBSCRIPTION_ID" "${OUTPUT_DIR}/subscription_set.json" "${OUTPUT_DIR}/subscription_set.err" "$DISCOVERY_TIMEOUT" "Setting subscription"; then
            log_success "Subscription set successfully."
        else
            log_error "Failed to set subscription. Please check if the ID is correct."
            exit 1
        fi
    fi
    
    # Check if Network Watcher is registered
    local nw_state=$(az provider show --namespace Microsoft.Network --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
    if [[ "$nw_state" != "Registered" ]]; then
        log "Registering Microsoft.Network provider..."
        az provider register --namespace Microsoft.Network
        
        # Wait for registration
        log "Waiting for provider registration to complete..."
        while [[ "$nw_state" != "Registered" ]]; do
            sleep 10
            nw_state=$(az provider show --namespace Microsoft.Network --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
        done
    fi
}