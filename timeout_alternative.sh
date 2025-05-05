#!/bin/bash

# Alternative to the 'timeout' command
# Usage: run_with_timeout <timeout_seconds> <command>
run_with_timeout() {
    local timeout=$1
    shift
    local command="$@"
    local pid
    
    # Start command in background
    eval "$command" &
    pid=$!
    
    # Wait for specified time
    local waited=0
    local sleep_interval=1
    while [ $waited -lt $timeout ]; do
        # Check if process is still running
        if ! kill -0 $pid 2>/dev/null; then
            # Process completed
            wait $pid
            return $?
        fi
        
        sleep $sleep_interval
        waited=$((waited + sleep_interval))
    done
    
    # If we get here, the command timed out
    echo "Command timed out after $timeout seconds"
    
    # Try to terminate the process gracefully
    kill $pid 2>/dev/null
    sleep 1
    
    # Check if process is still running and force kill if needed
    if kill -0 $pid 2>/dev/null; then
        kill -9 $pid 2>/dev/null
    fi
    
    return 124  # Return same exit code as timeout command
}