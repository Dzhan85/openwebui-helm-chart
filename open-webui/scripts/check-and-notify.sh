#!/bin/bash

#############################################################################
# Script: check-and-notify.sh
# Description: Wrapper script that checks for image updates and sends
#              notifications when updates are available
# Usage: ./check-and-notify.sh [notification_method]
#        notification_method: macos, slack, email (default: macos)
#############################################################################

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="${SCRIPT_DIR}/check-image-update.sh"

# Configuration
NOTIFICATION_METHOD="${1:-macos}"
SLACK_WEBHOOK="${SLACK_WEBHOOK_URL:-}"
EMAIL_TO="${EMAIL_TO:-admin@billups.com}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Send macOS notification
send_macos_notification() {
    local title="$1"
    local message="$2"

    if command -v osascript &> /dev/null; then
        osascript -e "display notification \"${message}\" with title \"${title}\""
    else
        log_error "osascript not available (macOS only)"
    fi
}

# Send Slack notification
send_slack_notification() {
    local message="$1"

    if [ -z "$SLACK_WEBHOOK" ]; then
        log_error "SLACK_WEBHOOK_URL environment variable not set"
        return 1
    fi

    curl -X POST "$SLACK_WEBHOOK" \
         -H 'Content-Type: application/json' \
         -d "{
             \"text\": \"🐳 Open WebUI Update Available\",
             \"blocks\": [
                 {
                     \"type\": \"section\",
                     \"text\": {
                         \"type\": \"mrkdwn\",
                         \"text\": \"${message}\"
                     }
                 }
             ]
         }" 2>/dev/null

    if [ $? -eq 0 ]; then
        log_info "Slack notification sent successfully"
    else
        log_error "Failed to send Slack notification"
    fi
}

# Send email notification
send_email_notification() {
    local subject="$1"
    local body="$2"

    if command -v mail &> /dev/null; then
        echo "$body" | mail -s "$subject" "$EMAIL_TO"
        log_info "Email sent to $EMAIL_TO"
    else
        log_error "mail command not available"
    fi
}

# Main execution
main() {
    log_info "Checking for Open WebUI image updates..."

    # Run the check script and capture output
    if [ ! -f "$CHECK_SCRIPT" ]; then
        log_error "Check script not found: $CHECK_SCRIPT"
        exit 1
    fi

    OUTPUT=$("$CHECK_SCRIPT" --dry-run 2>&1)
    EXIT_CODE=$?

    # Print the output
    echo "$OUTPUT"

    # Check if update is available
    if echo "$OUTPUT" | grep -q "New image version available"; then
        log_info "Update detected! Sending notification..."

        # Extract digest information
        CURRENT_DIGEST=$(echo "$OUTPUT" | grep "Current:" | awk '{print $2}')
        REMOTE_DIGEST=$(echo "$OUTPUT" | grep "Remote:" | awk '{print $2}')

        # Prepare notification message
        NOTIFICATION_TITLE="Open WebUI Update Available"
        NOTIFICATION_MESSAGE="A new version of open-webui image is available!

Current: ${CURRENT_DIGEST:0:12}...
Remote:  ${REMOTE_DIGEST:0:12}...

To update, run:
kubectl rollout restart deployment/open-webui"

        # Send notification based on method
        case "$NOTIFICATION_METHOD" in
            macos)
                send_macos_notification "$NOTIFICATION_TITLE" "New open-webui image available! Check logs for details."
                ;;
            slack)
                send_slack_notification "$NOTIFICATION_MESSAGE"
                ;;
            email)
                send_email_notification "$NOTIFICATION_TITLE" "$NOTIFICATION_MESSAGE"
                ;;
            all)
                send_macos_notification "$NOTIFICATION_TITLE" "New open-webui image available!"
                send_slack_notification "$NOTIFICATION_MESSAGE"
                send_email_notification "$NOTIFICATION_TITLE" "$NOTIFICATION_MESSAGE"
                ;;
            *)
                log_error "Unknown notification method: $NOTIFICATION_METHOD"
                log_info "Available methods: macos, slack, email, all"
                exit 1
                ;;
        esac

    elif echo "$OUTPUT" | grep -q "Image is up to date"; then
        log_info "✓ Image is up to date - no notification needed"
    else
        log_info "Check completed - no deployment found to compare (this is normal for first run)"
    fi
}

# Run main function
main "$@"
