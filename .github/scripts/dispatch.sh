#!/bin/bash

# Send repository dispatch events for documentation jobs

# Configuration
DOCUMENTATION_CONFIG="documentation.json"
OUTPUT_FILE="output.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check dependencies
check_dependencies() {
    local missing_deps=()
    
    command -v jq >/dev/null 2>&1 || missing_deps+=("jq")
    command -v gh >/dev/null 2>&1 || missing_deps+=("gh")
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        error "Missing required dependencies: ${missing_deps[*]}"
        error "Please install them and try again"
        exit 1
    fi
}

# Validate environment
validate_environment() {
    if [ ! -f "$DOCUMENTATION_CONFIG" ]; then
        error "Documentation config file not found: $DOCUMENTATION_CONFIG"
        exit 1
    fi
    
    if [ ! -f "$OUTPUT_FILE" ]; then
        error "Output file not found: $OUTPUT_FILE"
        error "Run queue_changes.sh first to generate the output file"
        exit 1
    fi
    
    # Validate JSON syntax
    if ! jq empty "$DOCUMENTATION_CONFIG" 2>/dev/null; then
        error "Invalid JSON in $DOCUMENTATION_CONFIG"
        exit 1
    fi
    
    if ! jq empty "$OUTPUT_FILE" 2>/dev/null; then
        error "Invalid JSON in $OUTPUT_FILE"
        exit 1
    fi
    
    # Check if gh CLI is authenticated
    if ! gh auth status >/dev/null 2>&1; then
        error "GitHub CLI is not authenticated"
        error "Run 'gh auth login' to authenticate"
        exit 1
    fi
}

# Get current repository info
get_target_repo_info() {
    # Check if we're in a git repository
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        error "Not in a git repository"
        error "Please run this script from within a git repository"
        exit 1
    fi
    
    # Get the remote origin URL
    local repo_url=$(git remote get-url origin 2>/dev/null)
    
    if [ -z "$repo_url" ]; then
        error "No origin remote found"
        error "Please ensure your repository has an origin remote configured"
        exit 1
    fi
    
    # Extract owner/repo from URL and strip .git
    local repo_path=$(echo "$repo_url" | sed -E 's|.*github\.com[/:]([^/]+/[^/]+).*|\1|' | sed 's/\.git$//')
    
    if [ -z "$repo_path" ] || [[ ! "$repo_path" =~ ^[^/]+/[^/]+$ ]]; then
        error "Invalid repository URL: $repo_url"
        error "Expected GitHub repository format: https://github.com/owner/repo or git@github.com:owner/repo.git"
        exit 1
    fi
    
    echo "$repo_path"
}

# Send repository dispatch for a single job
send_job_dispatch() {
    local job_data="$1"
    local target_repo="$2"
    
    # Extract job information
    local job_key=$(echo "$job_data" | jq -r '.job_key')
    local job_type=$(echo "$job_data" | jq -r '.job_type')
    local modified_files_array=$(echo "$job_data" | jq -c '.modified_files')
    
    # Convert modified_files array to comma-delimited string
    local modified_files_string=$(echo "$modified_files_array" | jq -r '.[] | @csv' | tr -d '"' | paste -sd ',' -)
    
    # Create event type
    local event_type="update-documentation-${job_type}"
    
    log "Sending repository dispatch for job: $job_key"
    log "  Event type: $event_type"
    log "  Target repo: $target_repo"
    log "  Modified files: $modified_files_string"

    log "Create Payload..."

    # Create payload for the GitHub workflow
    local payload=$(jq -n \
        --arg job_key "$job_key" \
        --arg modified_files "$modified_files_string" \
        '{
            job_key: $job_key,
            modified_files: $modified_files
        }')

    # Send repository dispatch
    local gh_output
    local gh_exit_code
    
    # Create a temporary file for the request body
    local temp_payload=$(mktemp)
    local request_body=$(jq -n \
        --arg event_type "$event_type" \
        --argjson client_payload "$payload" \
        '{
            event_type: $event_type,
            client_payload: $client_payload
        }')
    
    echo "$request_body" > "$temp_payload"
    
    log "Executing: gh api repos/$target_repo/dispatches --input \"$temp_payload\""
    log "Request body: $request_body"
    
    gh_output=$(gh api "repos/$target_repo/dispatches" \
        --method POST \
        --input "$temp_payload" 2>&1)
    gh_exit_code=$?
    
    # Clean up temp file
    rm -f "$temp_payload"
    
    log "GitHub API response: $gh_output"
    log "Exit code: $gh_exit_code"
    
    if [ $gh_exit_code -eq 0 ]; then
        success "Repository dispatch sent for job: $job_key"
        return 0
    else
        error "Failed to send repository dispatch for job: $job_key"
        error "GitHub API error: $gh_output"
        return 1
    fi
}

# Send repository dispatch with enhanced payload
send_job_dispatch_enhanced() {
    local job_data="$1"
    local target_repo="$2"
    local git_context="$3"
    
    # Extract job information
    local job_key=$(echo "$job_data" | jq -r '.job_key')
    local job_type=$(echo "$job_data" | jq -r '.job_type')
    local modified_files_array=$(echo "$job_data" | jq -c '.modified_files')
    local documentation_files=$(echo "$job_data" | jq -c '.documentation_files')
    local urgent=$(echo "$job_data" | jq -r '.urgent')
    local modified_count=$(echo "$job_data" | jq -r '.modified_count')
    
    # Convert modified_files array to comma-delimited string
    local modified_files_string=$(echo "$modified_files_array" | jq -r '.[] | @csv' | tr -d '"' | paste -sd ',' -)
    
    # Create event type
    local event_type="update-documentation-${job_type}"
    
    log "Sending enhanced repository dispatch for job: $job_key"
    log "  Event type: $event_type"
    log "  Target repo: $target_repo"
    log "  Modified files: $modified_files_string"
    log "  Urgent: $urgent"
    
    # Create enhanced payload
    local payload=$(jq -n \
        --arg job_key "$job_key" \
        --arg modified_files "$modified_files_string" \
        --argjson documentation_files "$documentation_files" \
        --arg job_type "$job_type" \
        --argjson modified_count "$modified_count" \
        --argjson urgent "$urgent" \
        --argjson git_context "$git_context" \
        --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg triggered_by "$(git config user.name 2>/dev/null || echo 'Unknown')" \
        '{
            job_key: $job_key,
            modified_files: $modified_files,
            documentation_files: $documentation_files,
            job_type: $job_type,
            modified_count: $modified_count,
            urgent: $urgent,
            git_context: $git_context,
            metadata: {
                triggered_by: $triggered_by,
                timestamp: $timestamp,
                source: "queue_changes_dispatch"
            }
        }')

    log "Payload for job $job_key: $payload"

    # Send repository dispatch
    local gh_output
    local gh_exit_code
    
    # Create a temporary file for the request body
    local temp_payload=$(mktemp)
    local request_body=$(jq -n \
        --arg event_type "$event_type" \
        --argjson client_payload "$payload" \
        '{
            event_type: $event_type,
            client_payload: $client_payload
        }')
    
    echo "$request_body" > "$temp_payload"
    
    log "Executing: gh api repos/$target_repo/dispatches --input \"$temp_payload\""
    log "Request body: $request_body"
    
    gh_output=$(gh api "repos/$target_repo/dispatches" \
        --method POST \
        --input "$temp_payload" 2>&1)
    gh_exit_code=$?
    
    # Clean up temp file
    rm -f "$temp_payload"
    
    log "GitHub API response: $gh_output"
    log "Exit code: $gh_exit_code"
    
    if [ $gh_exit_code -eq 0 ]; then
        success "Enhanced repository dispatch sent for job: $job_key"
        return 0
    else
        error "Failed to send repository dispatch for job: $job_key"
        error "GitHub API error: $gh_output"
        return 1
    fi
}

# Main processing function
main() {
    local enhanced_mode=false
    local dry_run=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --enhanced)
                enhanced_mode=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [options]"
                echo "Options:"
                echo "  --enhanced      Send enhanced payload with full job context"
                echo "  --dry-run       Show what would be sent without actually sending"
                echo "  --output FILE   Use specific output file (default: output.json)"
                echo "  --help, -h      Show this help"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    log "Starting repository dispatch sender"
    log "Enhanced mode: $enhanced_mode"
    log "Dry run: $dry_run"
    
    # Validate environment
    check_dependencies
    validate_environment
    
    # Get target repository info
    local target_repo
    target_repo=$(get_target_repo_info)
    log "Target repository: $target_repo"
    
    # Check if there are any jobs to process
    local job_count=$(jq '.jobs | length' "$OUTPUT_FILE")
    if [ "$job_count" -eq 0 ]; then
        log "No jobs found in output file"
        exit 0
    fi
    
    log "Found $job_count job(s) to process"
    
    # Get git context for enhanced mode
    local git_context=""
    if [ "$enhanced_mode" = true ]; then
        git_context=$(jq '.git_context' "$OUTPUT_FILE")
    fi
    
    # Process each job
    local success_count=0
    local error_count=0
    
    while IFS= read -r job; do
        local job_key=$(echo "$job" | jq -r '.job_key')
        
        if [ "$dry_run" = true ]; then
            # Convert array to comma string for dry run display
            local modified_files_display=$(echo "$job" | jq -r '.modified_files[] | @csv' | tr -d '"' | paste -sd ',' -)
            
            log "[DRY RUN] Would send repository dispatch for job: $job_key"
            log "  Event type: update-documentation-$(echo "$job" | jq -r '.job_type')"
            log "  Branch: $(echo "$job" | jq -r '.git_context.branch // "unknown"')"
            log "  Modified files: $modified_files_display"
            ((success_count++))
        else
            if [ "$enhanced_mode" = true ]; then
                if send_job_dispatch_enhanced "$job" "$target_repo" "$git_context"; then
                    ((success_count++))
                else
                    ((error_count++))
                fi
            else
                if send_job_dispatch "$job" "$target_repo"; then
                    ((success_count++))
                else
                    ((error_count++))
                fi
            fi
        fi
        
        # Small delay between requests to be nice to GitHub API
        sleep 1
        
    done < <(jq -c '.jobs[]' "$OUTPUT_FILE")
    
    # Summary
    echo ""
    log "=== SUMMARY ==="
    log "Jobs processed: $job_count"
    log "Successful dispatches: $success_count"
    if [ $error_count -gt 0 ]; then
        warning "Failed dispatches: $error_count"
    fi
    log "Target repository: $target_repo"
    
    if [ "$dry_run" = true ]; then
        log "This was a dry run - no actual dispatches were sent"
    fi
    
    if [ $error_count -gt 0 ]; then
        exit 1
    else
        success "All repository dispatches sent successfully!"
        exit 0
    fi
}

# Run the main function
main "$@"