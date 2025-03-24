#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# Check if dvc is installed
if ! command -v dvc &> /dev/null; then
    error "DVC is not installed. Please install DVC to use this script."
fi

# Check if .dvc directory exists
if [ ! -d ".dvc" ]; then
    error "DVC is not initialized in this repository. Please initialize DVC to use this script."
fi

# Default values
POLL_INTERVAL=30
NTFY_TOPIC=""

# Global variables
REPO_ROOT=""

# Function to print error messages to stderr
error() {
    echo "Error: $1" >&2
    exit 1
}

# Function to print usage
usage() {
    echo "Usage: $0 [-t <ntfy_topic>] [-n <poll_interval>]"
    echo "Options:"
    echo "  -n, --interval  Polling interval in seconds (default: 30)"
    echo "  -t, --topic     NTFY topic for notifications (optional)"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--interval)
            POLL_INTERVAL="$2"
            shift 2
            ;;
        -t|--topic)
            NTFY_TOPIC="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            error "Unknown argument: $1"
            ;;
    esac
done


# Get the repository root if notifications are enabled
if [ -n "$NTFY_TOPIC" ]; then
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || error "Not inside a Git repository"
    LOCK_FILE="${REPO_ROOT}/.dvc/ntfy.lock"
    rm -f "$LOCK_FILE"
fi

# Function to send notification when experiments complete
send_completion_notification() {
    local summary="$1"
    local failed_count="$2"
    
    if [ -z "$NTFY_TOPIC" ]; then
        return
    fi
    
    local REPO_NAME=$(basename "$REPO_ROOT")
    local emoji
    if [ "$failed_count" -gt 0 ]; then
        emoji="⚠️"
    else
        emoji="✅"
    fi
    
    local TITLE="$emoji $REPO_NAME experiments completed"
    curl \
        -H "Title: $TITLE" \
        -d "$summary" \
        ntfy.sh/"$NTFY_TOPIC" > /dev/null 2>&1
    
    touch "$LOCK_FILE"
    echo "Notification sent: $TITLE ($summary)"
}

# Main monitoring loop
while true; do
    # Clear screen and move cursor to home position
    tput clear
    tput cup 0 0
    
    # Print header
    echo "DVC Queue Status Monitor (Updated: $(date '+%Y-%m-%d %H:%M:%S'))"
    echo "------------------------------------------------------------------------------"

    # Fetch the queue status
    QUEUE_STATUS=$(dvc queue status 2>/dev/null) || error "Failed to retrieve DVC queue status."

    # Check if the queue is empty
    if echo "$QUEUE_STATUS" | grep -q "No tasks in the queue"; then
        echo "No experiments in the DVC queue."
        if [ -f "$LOCK_FILE" ]; then
            rm -f "$LOCK_FILE"
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Parse the queue status to extract names and statuses of experiments
    SUCCESS_EXPERIMENTS=$(echo "$QUEUE_STATUS" | grep -E 'Success$' | awk '{print $2}')
    FAILED_EXPERIMENTS=$(echo "$QUEUE_STATUS" | grep -E 'Failed$' | awk '{print $2}')
    QUEUED_EXPERIMENTS=$(echo "$QUEUE_STATUS" | grep -E 'Queued$' | awk '{print $2}')
    RUNNING_EXPERIMENTS=$(echo "$QUEUE_STATUS" | grep -E 'Running$' | awk '{print $2}')

    # Count experiments in each state
    SUCCESS_COUNT=$(echo "$SUCCESS_EXPERIMENTS" | wc -w)
    FAILED_COUNT=$(echo "$FAILED_EXPERIMENTS" | wc -w)
    QUEUED_COUNT=$(echo "$QUEUED_EXPERIMENTS" | wc -w)
    RUNNING_COUNT=$(echo "$RUNNING_EXPERIMENTS" | wc -w)

    # Report completed experiments
    if [ -n "$SUCCESS_EXPERIMENTS" ]; then
        for exp in $SUCCESS_EXPERIMENTS; do
            printf "%-15s | %s\n" "$exp" "Success"
        done
    fi

    if [ -n "$FAILED_EXPERIMENTS" ]; then
        for exp in $FAILED_EXPERIMENTS; do
            printf "%-15s | %s\n" "$exp" "Failed"
        done
    fi

    if [ -n "$QUEUED_EXPERIMENTS" ]; then
        for exp in $QUEUED_EXPERIMENTS; do
            printf "%-15s | %s\n" "$exp" "Queued"
        done
    fi

    echo "------------------------------------------------------------------------------"
    # Iterate over each running experiment and fetch the last log line
    for exp in $RUNNING_EXPERIMENTS; do
        # Fetch logs for the experiment
        LOGS=$(dvc queue logs "$exp" 2>/dev/null) || {
            echo "Failed to retrieve logs for experiment: $exp"
            continue
        }

        # Check if logs are available
        if [ -z "$LOGS" ]; then
            echo "No logs found for experiment: $exp"
            continue
        fi

        # Extract the last log line with progress bar, if it exists
        # If it doesn't exist, extract the last line
        LAST_LOG=$(echo "$LOGS" | grep -E 's/it' | tail -n 1)
        if [ -z "$LAST_LOG" ]; then
            LAST_LOG=$(echo "$LOGS" | tail -n 1)
        fi

        # Display the experiment name and its last log line
        printf "%-15s | %s\n" "$exp" "Running: $LAST_LOG"
    done

    echo "------------------------------------------------------------------------------"
    SUMMARY="Success: $SUCCESS_COUNT, Failed: $FAILED_COUNT, Queued: $QUEUED_COUNT, Running: $RUNNING_COUNT"
    echo "$SUMMARY"

    # Handle notifications if enabled
    if [ -n "$NTFY_TOPIC" ]; then
        if [[ "$QUEUED_COUNT" -eq 0 && "$RUNNING_COUNT" -eq 0 && $((SUCCESS_COUNT + FAILED_COUNT)) -gt 0 ]]; then
            if [ ! -f "$LOCK_FILE" ]; then
                send_completion_notification "$SUMMARY" "$FAILED_COUNT"
            fi
        else
            # Reset lock if queue changes
            if [ -f "$LOCK_FILE" ]; then
                rm -f "$LOCK_FILE"
                echo "Queue updated or empty; lock reset for new notifications."
            fi
        fi
    fi

    sleep "$POLL_INTERVAL"
done
