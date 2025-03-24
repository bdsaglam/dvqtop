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

# Add color definitions after the global variables
# Color definitions
readonly COLOR_RESET=$(tput sgr0)
readonly COLOR_HEADER=$(tput setaf 6)    # Cyan for headers
readonly COLOR_SUCCESS=$(tput setaf 2)    # Green for success
readonly COLOR_ERROR=$(tput setaf 1)      # Red for errors
readonly COLOR_WARNING=$(tput setaf 3)    # Yellow for warnings
readonly COLOR_INFO=$(tput setaf 4)       # Blue for info
readonly COLOR_RUNNING=$(tput setaf 5)    # Magenta for running
readonly COLOR_BOLD=$(tput bold)
readonly COLOR_DIM=$(tput dim)

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
    local success_count="$1"
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
        -d "Success: $success_count, Failed: $failed_count" \
        ntfy.sh/"$NTFY_TOPIC" > /dev/null 2>&1
    
    touch "$LOCK_FILE"
    echo "Notification sent: $TITLE"
}

# Function to create a progress bar
create_progress_bar() {
    local percent=$1
    local width=20
    local num_filled=$(( (percent * width) / 100 ))
    local num_empty=$((width - num_filled))
    
    printf "["
    printf "%${num_filled}s" | tr ' ' '='
    printf "%${num_empty}s" | tr ' ' ' '
    printf "] %3d%%" "$percent"
}

# Main monitoring loop
while true; do
    # Clear screen and move cursor to home position
    tput clear
    tput cup 0 0
    
    # Print header with colors
    echo "${COLOR_BOLD}${COLOR_HEADER}DVC Queue Status Monitor${COLOR_RESET}"
    echo "${COLOR_DIM}Last Update: $(date '+%Y-%m-%d %H:%M:%S')${COLOR_RESET}"
    echo "${COLOR_HEADER}================================================================================${COLOR_RESET}"

    # Fetch the queue status
    QUEUE_STATUS=$(dvc queue status 2>/dev/null) || error "Failed to retrieve DVC queue status."

    # Check if the queue is empty
    if echo "$QUEUE_STATUS" | grep -q "No tasks in the queue"; then
        echo "${COLOR_INFO}No experiments in the DVC queue.${COLOR_RESET}"
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

    # Calculate total
    TOTAL_COUNT=$((SUCCESS_COUNT + FAILED_COUNT + QUEUED_COUNT + RUNNING_COUNT))

    # Update the summary display with colors (without percentages)
    printf "Total: ${COLOR_BOLD}%d${COLOR_RESET} | ${COLOR_SUCCESS}✓ Success: %d${COLOR_RESET} | ${COLOR_ERROR}✗ Failed: %d${COLOR_RESET} | ${COLOR_INFO}⋯ Queued: %d${COLOR_RESET} | ${COLOR_RUNNING}⟳ Running: %d${COLOR_RESET}\n" \
        "$TOTAL_COUNT" "$SUCCESS_COUNT" "$FAILED_COUNT" "$QUEUED_COUNT" "$RUNNING_COUNT"
    
    echo "${COLOR_HEADER}================================================================================${COLOR_RESET}"
    
    # Add table header with improved spacing
    printf "${COLOR_BOLD}%-10s | %-10s | %-60s${COLOR_RESET}\n" "Experiment" "Status" "Log"
    echo "${COLOR_HEADER}-------------------------------------------------------------------------------${COLOR_RESET}"

    # Report completed experiments with colors and improved spacing
    if [ -n "$SUCCESS_EXPERIMENTS" ]; then
        for exp in $SUCCESS_EXPERIMENTS; do
            printf "${COLOR_SUCCESS}%-10s${COLOR_RESET} | ${COLOR_SUCCESS}%-12s${COLOR_RESET} | ${COLOR_SUCCESS}Completed${COLOR_RESET}\n" "$exp" "✓ Success"
        done
    fi

    if [ -n "$FAILED_EXPERIMENTS" ]; then
        for exp in $FAILED_EXPERIMENTS; do
            printf "${COLOR_ERROR}%-10s${COLOR_RESET} | ${COLOR_ERROR}%-12s${COLOR_RESET} | ${COLOR_ERROR}Failed${COLOR_RESET}\n" "$exp" "✗ Failed"
        done
    fi

    if [ -n "$QUEUED_EXPERIMENTS" ]; then
        for exp in $QUEUED_EXPERIMENTS; do
            printf "${COLOR_INFO}%-10s${COLOR_RESET} | ${COLOR_INFO}%-12s${COLOR_RESET} | ${COLOR_INFO}Waiting to start${COLOR_RESET}\n" "$exp" "⋯ Queued"
        done
    fi

    # Update running experiments display
    for exp in $RUNNING_EXPERIMENTS; do
        LOGS=$(dvc queue logs "$exp" 2>/dev/null) || {
            echo "${COLOR_ERROR}Failed to retrieve logs for experiment: $exp${COLOR_RESET}"
            continue
        }

        if [ -z "$LOGS" ]; then
            echo "${COLOR_WARNING}No logs found for experiment: $exp${COLOR_RESET}"
            continue
        fi

        LAST_LOG=$(echo "$LOGS" | grep -E 's/it' | tail -n 1)
        if [ -z "$LAST_LOG" ]; then
            LAST_LOG=$(echo "$LOGS" | tail -n 1)
        fi

        # Truncate log to 80 characters and add ellipsis if needed
        if [ ${#LAST_LOG} -gt 50 ]; then
            LAST_LOG="${LAST_LOG:0:50}..."
        fi

        printf "${COLOR_RUNNING}%-10s${COLOR_RESET} | ${COLOR_RUNNING}%-12s${COLOR_RESET} | %s\n" "$exp" "⟳ Running" "$LAST_LOG"
    done

    echo "${COLOR_HEADER}================================================================================${COLOR_RESET}"
    # Handle notifications if enabled
    if [ -n "$NTFY_TOPIC" ]; then
        if [[ "$QUEUED_COUNT" -eq 0 && "$RUNNING_COUNT" -eq 0 && $((SUCCESS_COUNT + FAILED_COUNT)) -gt 0 ]]; then
            if [ ! -f "$LOCK_FILE" ]; then
                send_completion_notification "$SUCCESS_COUNT" "$FAILED_COUNT"
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
