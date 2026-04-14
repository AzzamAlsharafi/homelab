#!/bin/bash
set -euo pipefail

# ==========================================
# Configuration
# ==========================================
HOMELAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HOMELAB_DIR/.env"

# Load environment variables for ntfy credentials
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

NTFY_BASE_URL="https://ntfy.home.alsharafi.dev"
NTFY_TOPIC="${NTFY_TOPIC:?NTFY_TOPIC is not set}"
NTFY_TOKEN="${NTFY_TOKEN:?NTFY_TOKEN is not set}"

# Services that require manual intervention (only updated when --manual/-M flag is passed)
MANUAL_SERVICES=(
    "traefik"
    "zitadel"
    "oauth2-proxy"
)

# Services that are never updated automatically or manually
EXCLUDED_SERVICES=(
)

# ==========================================
# Parse Arguments
# ==========================================
MANUAL_MODE=false
for arg in "$@"; do
    if [[ "$arg" == "--manual" || "$arg" == "-M" ]]; then
        MANUAL_MODE=true
    fi
done

LOG_FILE="$($MANUAL_MODE && echo /dev/null || echo "$HOMELAB_DIR/update.log")"

# ==========================================
# Colors
# ==========================================
RESET='\033[0m'
DIM='\033[2m'
BOLD='\033[1m'
C_OK='\033[2m'           # dim
C_SKIP='\033[0;90m'      # dark gray
C_OUTDATED='\033[0;35m'  # magenta
C_PULL='\033[0;34m'      # blue
C_UPDATED='\033[0;92m'   # bright green
C_ERROR='\033[1;31m'     # bold red
C_WARN='\033[0;33m'      # yellow
C_RESTART='\033[0;36m'   # cyan

# ==========================================
# Helpers
# ==========================================
log() {
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    local message="$*"

    # Pick label color based on the [LABEL] prefix or === header
    local label_color="$RESET"
    if [[ "$message" == ===* ]]; then
        label_color="$BOLD"
    elif [[ "$message" =~ ^\[([A-Z]+)\] ]]; then
        case "${BASH_REMATCH[1]}" in
            OK)       label_color="$C_OK" ;;
            SKIP)     label_color="$C_SKIP" ;;
            OUTDATED) label_color="$C_OUTDATED" ;;
            PULL)     label_color="$C_PULL" ;;
            UPDATED)  label_color="$C_UPDATED" ;;
            ERROR)    label_color="$C_ERROR" ;;
            WARN)     label_color="$C_WARN" ;;
            RESTART)  label_color="$C_RESTART" ;;
        esac
    fi

    # Colored output to stdout, plain text to log file
    echo -e "${DIM}[${timestamp}]${RESET} ${label_color}${message}${RESET}"
    echo "[${timestamp}] ${message}" >> "$LOG_FILE"
}

is_excluded() {
    local service="$1"
    for excluded in "${EXCLUDED_SERVICES[@]}"; do
        if [[ "$service" == "$excluded" ]]; then return 0; fi
    done
    return 1
}

is_manual() {
    local service="$1"
    for manual in "${MANUAL_SERVICES[@]}"; do
        if [[ "$service" == "$manual" ]]; then return 0; fi
    done
    return 1
}

get_local_digest() {
    local image="$1"
    local output
    output=$(docker image inspect "$image" --format '{{index .RepoDigests 0}}' 2>/dev/null) || return 0
    echo "$output" | awk -F'@' '{print $2}'
}

get_remote_digest() {
    local image="$1"
    local output
    output=$(docker buildx imagetools inspect "$image" 2>/dev/null) || return 0
    echo "$output" | awk '/^Digest:/{print $2; exit}'
}

short_digest() {
    echo "${1:0:19}"  # "sha256:" + 12 chars
}

send_ntfy() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"

    curl -s \
        -H "Authorization: Bearer $NTFY_TOKEN" \
        -H "Title: $title" \
        -H "Priority: $priority" \
        -d "$message" \
        "$NTFY_BASE_URL/$NTFY_TOPIC" > /dev/null
}

# ==========================================
# Main
# ==========================================
if $MANUAL_MODE; then
    log "=== Homelab Update Started (manual services only) ==="
else
    log "=== Homelab Update Started ==="
fi

# Per-service report data: newline-separated entries stored as associative array values
declare -A service_updated_images   # service -> "image|old_digest|new_digest\n..."
declare -A service_failed_images    # service -> "image|reason\n..."
updated_services=()
failed_services=()

for compose_file in "$HOMELAB_DIR/services"/*/docker-compose.yml; do
    [ -f "$compose_file" ] || continue

    service_name=$(basename "$(dirname "$compose_file")")

    if is_excluded "$service_name"; then
        log "[SKIP] $service_name (excluded)"
        continue
    fi

    if $MANUAL_MODE && ! is_manual "$service_name"; then
        continue
    fi

    if ! $MANUAL_MODE && is_manual "$service_name"; then
        log "[SKIP] $service_name (manual)"
        continue
    fi

    # Extract image references from compose config (works even if service is not running)
    images=$(docker compose --env-file "$ENV_FILE" -f "$compose_file" config --format json 2>/dev/null \
        | jq -r '.services[].image // empty' | sort -u) || {
        log "[ERROR] $service_name: failed to read compose config"
        service_failed_images[$service_name]="compose-config|failed to read compose config"
        failed_services+=("$service_name")
        continue
    }

    if [[ -z "$images" ]]; then
        log "[SKIP] $service_name: no images found in compose config"
        continue
    fi

    # --- Phase 1: check which images need updating ---
    images_to_pull=()
    declare -A pending_old_digest   # image -> old local digest
    declare -A pending_remote_digest  # image -> expected remote digest

    while IFS= read -r image; do
        [[ -z "$image" ]] && continue

        local_digest=$(get_local_digest "$image")
        remote_digest=$(get_remote_digest "$image")

        if [[ -z "$remote_digest" ]]; then
            log "[WARN] $service_name: could not fetch remote digest for $image, skipping"
            continue
        fi

        if [[ -z "$local_digest" || "$local_digest" != "$remote_digest" ]]; then
            log "[OUTDATED] $service_name: $image $(short_digest "${local_digest:-none}") -> $(short_digest "$remote_digest")"
            images_to_pull+=("$image")
            pending_old_digest[$image]="${local_digest:-none}"
            pending_remote_digest[$image]="$remote_digest"
        else
            log "[OK] $service_name: $image $(short_digest "$local_digest")"
        fi
    done <<< "$images"

    if [[ ${#images_to_pull[@]} -eq 0 ]]; then
        unset pending_old_digest pending_remote_digest
        continue
    fi

    # --- Phase 2: pull only images that need updating ---
    service_had_update=false
    service_had_failure=false

    for image in "${images_to_pull[@]}"; do
        log "[PULL] $service_name: pulling $image..."
        if docker pull "$image" >> "$LOG_FILE" 2>&1; then
            # Verify the pull actually updated the digest
            new_local_digest=$(get_local_digest "$image")
            expected="${pending_remote_digest[$image]}"

            if [[ "$new_local_digest" == "$expected" ]]; then
                log "[UPDATED] $service_name: $image $(short_digest "${pending_old_digest[$image]}") -> $(short_digest "$new_local_digest")"
                service_updated_images[$service_name]+="${image}|${pending_old_digest[$image]}|${new_local_digest}"$'\n'
                service_had_update=true
            else
                log "[ERROR] $service_name: $image digest mismatch after pull (got $(short_digest "${new_local_digest:-none}"), expected $(short_digest "$expected"))"
                service_failed_images[$service_name]+="${image}|digest mismatch after pull"$'\n'
                service_had_failure=true
            fi
        else
            log "[ERROR] $service_name: failed to pull $image"
            service_failed_images[$service_name]+="${image}|pull failed"$'\n'
            service_had_failure=true
        fi
    done

    # --- Phase 3: restart service if any image was updated ---
    if $service_had_update; then
        log "[RESTART] $service_name"
        if docker compose --env-file "$ENV_FILE" -f "$compose_file" up -d >> "$LOG_FILE" 2>&1; then
            updated_services+=("$service_name")
        else
            log "[ERROR] $service_name: up -d failed"
            service_failed_images[$service_name]+="compose-up|docker compose up -d failed"$'\n'
            service_had_failure=true
            # Still count as updated since images were pulled successfully
            updated_services+=("$service_name")
        fi
    fi

    if $service_had_failure; then
        failed_services+=("$service_name")
    fi

    unset pending_old_digest pending_remote_digest
done

log "=== Homelab Update Finished ==="

# ==========================================
# Report
# ==========================================
if [[ ${#updated_services[@]} -eq 0 && ${#failed_services[@]} -eq 0 ]]; then
    if $MANUAL_MODE; then
        log "All services up to date."
    else
        log "All services up to date — no notification sent."
    fi
    exit 0
fi

message=""

if [[ ${#updated_services[@]} -gt 0 ]]; then
    message+="Updated (${#updated_services[@]}):"$'\n'
    for svc in "${updated_services[@]}"; do
        message+="  $svc"$'\n'
        if [[ -n "${service_updated_images[$svc]:-}" ]]; then
            while IFS='|' read -r img old new; do
                [[ -z "$img" ]] && continue
                message+="    $(basename "$img") $(short_digest "$old") -> $(short_digest "$new")"$'\n'
            done <<< "${service_updated_images[$svc]}"
        fi
    done
fi

if [[ ${#failed_services[@]} -gt 0 ]]; then
    # Deduplicate: a service can appear in both arrays if some images updated and some failed
    seen_failures=()
    [[ -n "$message" ]] && message+=$'\n'
    message+="Failed:"$'\n'
    for svc in "${failed_services[@]}"; do
        [[ " ${seen_failures[*]} " == *" $svc "* ]] && continue
        seen_failures+=("$svc")
        message+="  $svc"$'\n'
        if [[ -n "${service_failed_images[$svc]:-}" ]]; then
            while IFS='|' read -r img reason; do
                [[ -z "$img" ]] && continue
                message+="    $img: $reason"$'\n'
            done <<< "${service_failed_images[$svc]}"
        fi
    done
fi

priority="default"
if [[ ${#failed_services[@]} -gt 0 ]]; then
    priority="high"
fi

if $MANUAL_MODE; then
    log "Report:"$'\n'"$message"
else
    send_ntfy "Homelab Update Report" "$message" "$priority"
    log "Notification sent."
fi
