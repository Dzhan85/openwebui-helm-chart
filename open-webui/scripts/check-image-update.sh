#!/bin/bash

#############################################################################
# Script: check-image-update.sh
# Description: Checks for updates to the open-webui container image and
#              optionally updates the values.yaml file
# Usage: ./check-image-update.sh [OPTIONS]
#############################################################################

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
IMAGE_REPO="ghcr.io/open-webui/open-webui"
IMAGE_TAG="main"
VALUES_FILE="../values.yaml"
DRY_RUN=false
AUTO_UPDATE=false
VERBOSE=false

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#############################################################################
# Functions
#############################################################################

print_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

OPTIONS:
    -h, --help              Show this help message
    -d, --dry-run           Check for updates but don't modify files
    -u, --update            Automatically update values.yaml if changes detected
    -v, --verbose           Enable verbose output
    -f, --file <path>       Path to values.yaml (default: ../values.yaml)
    -r, --repo <repo>       Image repository (default: ghcr.io/open-webui/open-webui)
    -t, --tag <tag>         Image tag (default: main)

EXAMPLES:
    # Check for updates (dry-run)
    $0 --dry-run

    # Check and automatically update values.yaml
    $0 --update

    # Check with custom values file
    $0 --file /path/to/values.yaml --dry-run

EOF
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# Check if required tools are installed
check_dependencies() {
    local missing_deps=()

    # Check for image inspection tools (in order of preference)
    if command -v crane &> /dev/null; then
        IMAGE_TOOL="crane"
        log_verbose "Using 'crane' for image inspection"
    elif command -v skopeo &> /dev/null; then
        IMAGE_TOOL="skopeo"
        log_verbose "Using 'skopeo' for image inspection"
    elif command -v docker &> /dev/null; then
        IMAGE_TOOL="docker"
        log_verbose "Using 'docker' for image inspection"
    else
        missing_deps+=("crane, skopeo, or docker")
    fi

    # Check for jq
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        echo ""
        echo "Install instructions:"
        echo "  - crane:  brew install crane (or download from https://github.com/google/go-containerregistry)"
        echo "  - skopeo: brew install skopeo"
        echo "  - docker: https://docs.docker.com/get-docker/"
        echo "  - jq:     brew install jq"
        exit 1
    fi
}

# Get the digest of the remote image
get_remote_digest() {
    local image="${IMAGE_REPO}:${IMAGE_TAG}"
    log_info "Checking remote image: $image"

    case "$IMAGE_TOOL" in
        crane)
            crane digest "$image" 2>/dev/null
            ;;
        skopeo)
            skopeo inspect "docker://$image" 2>/dev/null | jq -r '.Digest'
            ;;
        docker)
            # Pull the image manifest without downloading layers
            docker manifest inspect "$image" 2>/dev/null | jq -r '.config.digest // .manifests[0].digest'
            ;;
    esac
}

# Get the digest of the currently deployed image
get_current_digest() {
    local namespace="default"
    local deployment_name="open-webui"

    # Try to get from running deployment
    if command -v kubectl &> /dev/null; then
        log_verbose "Checking deployed image digest via kubectl..."
        local image_id=$(kubectl get deployment "$deployment_name" -n "$namespace" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

        if [ -n "$image_id" ]; then
            case "$IMAGE_TOOL" in
                crane)
                    crane digest "$image_id" 2>/dev/null || echo ""
                    ;;
                skopeo)
                    skopeo inspect "docker://$image_id" 2>/dev/null | jq -r '.Digest' || echo ""
                    ;;
                docker)
                    docker manifest inspect "$image_id" 2>/dev/null | jq -r '.config.digest // .manifests[0].digest' || echo ""
                    ;;
            esac
        fi
    fi
}

# Get image metadata
get_image_metadata() {
    local image="${IMAGE_REPO}:${IMAGE_TAG}"

    case "$IMAGE_TOOL" in
        crane)
            crane manifest "$image" 2>/dev/null | jq -r '.config.digest, .created' 2>/dev/null || echo ""
            ;;
        skopeo)
            skopeo inspect "docker://$image" 2>/dev/null | jq -r '.Created, .Labels' || echo ""
            ;;
        docker)
            docker manifest inspect "$image" 2>/dev/null | jq -r '.config.digest' || echo ""
            ;;
    esac
}

# Update the values.yaml file
update_values_file() {
    local values_path="$1"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if [ ! -f "$values_path" ]; then
        log_error "Values file not found: $values_path"
        exit 1
    fi

    log_info "Updating $values_path..."

    # Create backup
    cp "$values_path" "${values_path}.backup.$(date +%Y%m%d_%H%M%S)"
    log_verbose "Created backup: ${values_path}.backup.$(date +%Y%m%d_%H%M%S)"

    # Add a comment about the update
    # Note: This is a simple approach. For production, consider using yq or similar tools
    echo "# Last checked for updates: $timestamp" >> "$values_path"

    log_success "Updated values.yaml (backup created)"
    log_warning "Note: With pullPolicy 'Always' and tag 'main', Kubernetes will automatically pull latest image on pod restart"
}

# Main function
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                print_usage
                exit 0
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -u|--update)
                AUTO_UPDATE=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -f|--file)
                VALUES_FILE="$2"
                shift 2
                ;;
            -r|--repo)
                IMAGE_REPO="$2"
                shift 2
                ;;
            -t|--tag)
                IMAGE_TAG="$2"
                shift 2
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done

    # Convert relative path to absolute
    if [[ ! "$VALUES_FILE" = /* ]]; then
        VALUES_FILE="${SCRIPT_DIR}/${VALUES_FILE}"
    fi

    log_info "=== Open WebUI Image Update Checker ==="
    echo ""

    # Check dependencies
    check_dependencies

    # Get remote digest
    log_info "Fetching remote image digest..."
    REMOTE_DIGEST=$(get_remote_digest)

    if [ -z "$REMOTE_DIGEST" ]; then
        log_error "Failed to fetch remote image digest"
        exit 1
    fi

    log_success "Remote digest: $REMOTE_DIGEST"

    # Get current digest
    log_info "Checking current deployment..."
    CURRENT_DIGEST=$(get_current_digest)

    if [ -n "$CURRENT_DIGEST" ]; then
        log_info "Current digest: $CURRENT_DIGEST"

        if [ "$REMOTE_DIGEST" = "$CURRENT_DIGEST" ]; then
            log_success "✓ Image is up to date!"
            exit 0
        else
            log_warning "⚠ New image version available!"
            echo ""
            log_info "Current: $CURRENT_DIGEST"
            log_info "Remote:  $REMOTE_DIGEST"
        fi
    else
        log_warning "Could not determine current deployment digest"
        log_info "Remote digest: $REMOTE_DIGEST"
    fi

    echo ""

    # Check values.yaml configuration
    if [ -f "$VALUES_FILE" ]; then
        log_info "Checking values.yaml configuration..."

        # Check pullPolicy
        PULL_POLICY=$(grep -A 3 "^image:" "$VALUES_FILE" | grep "pullPolicy:" | awk '{print $2}' | tr -d '"')
        log_info "Current pullPolicy: $PULL_POLICY"

        if [ "$PULL_POLICY" = "Always" ]; then
            log_success "✓ pullPolicy is set to 'Always' - Kubernetes will automatically pull latest image on pod restart"
            echo ""
            log_info "To apply the update, restart the deployment:"
            echo "  kubectl rollout restart deployment/open-webui"
        else
            log_warning "pullPolicy is not set to 'Always' - you may need to update the image tag"
        fi

        # Update if requested
        if [ "$AUTO_UPDATE" = true ] && [ "$DRY_RUN" = false ]; then
            update_values_file "$VALUES_FILE"
        fi
    else
        log_error "Values file not found: $VALUES_FILE"
        exit 1
    fi

    if [ "$DRY_RUN" = true ]; then
        echo ""
        log_info "=== DRY RUN MODE - No changes made ==="
    fi

    echo ""
    log_info "=== Summary ==="
    echo "Image:         ${IMAGE_REPO}:${IMAGE_TAG}"
    echo "Remote Digest: $REMOTE_DIGEST"
    [ -n "$CURRENT_DIGEST" ] && echo "Local Digest:  $CURRENT_DIGEST"
    echo ""

    # Provide recommendations
    if [ "$REMOTE_DIGEST" != "$CURRENT_DIGEST" ] && [ -n "$CURRENT_DIGEST" ]; then
        echo -e "${YELLOW}Recommended Actions:${NC}"
        echo "1. Review the changes in the new image"
        echo "2. Restart the deployment to pull the new image:"
        echo "   kubectl rollout restart deployment/open-webui"
        echo "3. Monitor the rollout:"
        echo "   kubectl rollout status deployment/open-webui"
    fi
}

# Run main function
main "$@"
