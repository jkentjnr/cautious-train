#!/bin/bash

# Job-based documentation processor for git changes
set -e

# Configuration
DOCUMENTATION_CONFIG="documentation.json"
OUTPUT_FILE="output.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global array to store job results
declare -a JOB_RESULTS=()

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
    command -v git >/dev/null 2>&1 || missing_deps+=("git")
    
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
    
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        error "Not in a git repository"
        exit 1
    fi
    
    # Validate JSON syntax
    if ! jq empty "$DOCUMENTATION_CONFIG" 2>/dev/null; then
        error "Invalid JSON in $DOCUMENTATION_CONFIG"
        exit 1
    fi
}

# Get list of all files changed in the last commit
get_changed_files() {
    git diff --name-only --diff-filter=ACMRT HEAD~1 HEAD
}

# Check if any files in the input array have been modified
get_modified_input_files() {
    local job_key="$1"
    local input_files_json="$2"
    local changed_files="$3"
    
    local modified_files=()
    
    # Convert JSON array to bash array
    local input_files=($(echo "$input_files_json" | jq -r '.[]'))
    
    # Check each input file against the list of changed files
    for input_file in "${input_files[@]}"; do
        if echo "$changed_files" | grep -Fxq "$input_file"; then
            modified_files+=("$input_file")
        fi
    done
    
    # Return the modified files as a space-separated string
    printf '%s\n' "${modified_files[@]}"
}

# Process a single job
process_job() {
    local job="$1"
    local changed_files="$2"
    
    local job_key=$(echo "$job" | jq -r '.key')
    local job_type=$(echo "$job" | jq -r '.type')
    local input_files_json=$(echo "$job" | jq -c '.input')
    local documentation_files=$(echo "$job" | jq -r '.documentation[]?' | tr '\n' ' ')
    
    log "Checking job: $job_key"
    log "  Type: $job_type"
    log "  Input files: $(echo "$input_files_json" | jq -r '.[]' | tr '\n' ' ')"
    
    # Get list of modified input files for this job
    local modified_files
    modified_files=$(get_modified_input_files "$job_key" "$input_files_json" "$changed_files")
    
    if [ -n "$modified_files" ]; then
        success "Job $job_key has modified input files:"
        echo "$modified_files" | sed 's/^/    /'
        
        # Call external routine with the modified files
        call_external_routine "$job_key" "$job_type" "$documentation_files" "$modified_files"
        
        return 0
    else
        log "  No input files modified for job: $job_key"
        return 1
    fi
}

# Call your external routine - now outputs to JSON
call_external_routine() {
    local job_key="$1"
    local job_type="$2"
    local documentation_files="$3"
    local modified_files="$4"
    
    log "Calling external routine for job: $job_key"
    log "  Modified files: $modified_files"
    log "  Documentation files: $documentation_files"
    
    # Get current git context
    local current_commit=$(git rev-parse HEAD)
    local previous_commit=$(git rev-parse HEAD~1)
    local branch=$(git branch --show-current 2>/dev/null || echo "unknown")
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Convert space-separated strings to JSON arrays
    local modified_files_array=""
    local documentation_files_array=""
    
    # Convert modified files to JSON array
    if [ -n "$modified_files" ]; then
        modified_files_array=$(echo "$modified_files" | tr ' ' '\n' | jq -R . | jq -s .)
    else
        modified_files_array="[]"
    fi
    
    # Convert documentation files to JSON array
    if [ -n "$documentation_files" ] && [ "$documentation_files" != " " ]; then
        documentation_files_array=$(echo "$documentation_files" | tr ' ' '\n' | grep -v '^$' | jq -R . | jq -s .)
    else
        documentation_files_array="[]"
    fi
    
    # Determine urgency based on file types or count
    local urgent=false
    local file_count=$(echo "$modified_files" | wc -w)
    if [[ "$modified_files" =~ \.(flow-meta\.xml|cls|trigger)$ ]] || [ "$file_count" -gt 3 ]; then
        urgent=true
    fi
    
    # Create job result JSON object
    local job_result=$(jq -n \
        --arg job_key "$job_key" \
        --arg job_type "$job_type" \
        --argjson modified_files "$modified_files_array" \
        --argjson documentation_files "$documentation_files_array" \
        --arg current_commit "$current_commit" \
        --arg previous_commit "$previous_commit" \
        --arg branch "$branch" \
        --arg timestamp "$timestamp" \
        --argjson file_count "$file_count" \
        --argjson urgent "$urgent" \
        --arg triggered_by "$(git config user.name 2>/dev/null || echo 'Unknown')" \
        --arg repository "$(git config --get remote.origin.url 2>/dev/null || echo 'Unknown')" \
        '{
            job_key: $job_key,
            job_type: $job_type,
            modified_files: $modified_files,
            documentation_files: $documentation_files,
            modified_count: $file_count,
            urgent: $urgent,
            git_context: {
                current_commit: $current_commit,
                previous_commit: $previous_commit,
                branch: $branch,
                repository: $repository
            },
            metadata: {
                triggered_by: $triggered_by,
                timestamp: $timestamp,
                processing_status: "queued"
            }
        }')
    
    # Add to global results array
    JOB_RESULTS+=("$job_result")
    
    # Display the information (optional, for debugging)
    echo "=== EXTERNAL ROUTINE CALL ==="
    echo "Job Key: $job_key"
    echo "Job Type: $job_type"
    echo "Documentation Files: $documentation_files"
    echo "Modified Files: $modified_files"
    echo "File Count: $file_count"
    echo "Urgent: $urgent"
    echo "============================="
}

# Write results to JSON file
write_output_json() {
    local total_jobs="$1"
    local jobs_with_changes="$2"
    local changed_files="$3"
    
    # Get overall git context
    local current_commit=$(git rev-parse HEAD)
    local previous_commit=$(git rev-parse HEAD~1)
    local branch=$(git branch --show-current 2>/dev/null || echo "unknown")
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local repository=$(git config --get remote.origin.url 2>/dev/null || echo "Unknown")
    
    # Convert changed files to JSON array
    local changed_files_array=""
    if [ -n "$changed_files" ]; then
        changed_files_array=$(echo "$changed_files" | jq -R . | jq -s .)
    else
        changed_files_array="[]"
    fi
    
    # Create jobs array from results
    local jobs_json="[]"
    if [ ${#JOB_RESULTS[@]} -gt 0 ]; then
        jobs_json=$(printf '%s\n' "${JOB_RESULTS[@]}" | jq -s .)
    fi
    
    # Create the final output JSON
    local output_json=$(jq -n \
        --argjson jobs "$jobs_json" \
        --argjson total_jobs "$total_jobs" \
        --argjson jobs_with_changes "$jobs_with_changes" \
        --argjson changed_files "$changed_files_array" \
        --arg current_commit "$current_commit" \
        --arg previous_commit "$previous_commit" \
        --arg branch "$branch" \
        --arg timestamp "$timestamp" \
        --arg repository "$repository" \
        --arg triggered_by "$(git config user.name 2>/dev/null || echo 'Unknown')" \
        '{
            summary: {
                total_jobs_checked: $total_jobs,
                jobs_with_changes: $jobs_with_changes,
                has_changes: ($jobs_with_changes > 0),
                timestamp: $timestamp,
                triggered_by: $triggered_by
            },
            git_context: {
                repository: $repository,
                branch: $branch,
                current_commit: $current_commit,
                previous_commit: $previous_commit,
                changed_files: $changed_files,
                changed_file_count: ($changed_files | length)
            },
            jobs: $jobs
        }')
    
    # Write to output file
    echo "$output_json" > "$OUTPUT_FILE"
    
    log "Output written to: $OUTPUT_FILE"
    
    # Also output a summary for easy reading
    echo "$output_json" | jq '.summary'
}

# Main processing function
main() {
    log "Starting job-based documentation processor"
    
    # Validate environment
    check_dependencies
    validate_environment
    
    # Get list of changed files from the last commit
    local changed_files
    changed_files=$(get_changed_files)
    
    if [ -z "$changed_files" ]; then
        log "No files changed in the last commit"
        
        # Still create output file with empty results
        write_output_json 0 0 ""
        exit 0
    fi
    
    log "Files changed in last commit:"
    echo "$changed_files" | sed 's/^/  /'
    echo ""
    
    # Get all jobs from the configuration
    local jobs_with_changes=0
    local total_jobs=0
    
    # Process each job
    while IFS= read -r job; do
        if [ -n "$job" ]; then
            ((total_jobs++))
            if process_job "$job" "$changed_files"; then
                ((jobs_with_changes++))
            fi
            echo ""
        fi
    done < <(jq -c '.jobs[]' "$DOCUMENTATION_CONFIG")
    
    # Write results to JSON file
    write_output_json "$total_jobs" "$jobs_with_changes" "$changed_files"
    
    # Summary
    log "=== SUMMARY ==="
    log "Total jobs checked: $total_jobs"
    log "Jobs with modified input files: $jobs_with_changes"
    log "Output file: $OUTPUT_FILE"
    
    if [ $jobs_with_changes -gt 0 ]; then
        success "Found jobs that need documentation updates!"
    else
        log "No jobs have modified input files"
    fi
}

# Run the main function
main "$@"