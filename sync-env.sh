#!/bin/bash

# ==========================================
# 0. Capture the BWS Access Token
# ==========================================
read -sp "Enter Bitwarden Secrets Manager Access Token: " BWS_ACCESS_TOKEN
echo -e "\nToken received."

# ==========================================
# 1. Configuration & Setup
# ==========================================
BWS_PROJECT_NAME="Homelab"
ENV_FILE=".env"

# Helper function to run BWS via Docker
bws_cmd() {
    docker run --rm -e BWS_ACCESS_TOKEN="$BWS_ACCESS_TOKEN" bitwarden/bws:latest "$@"
}

# Check if .env exists
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: $ENV_FILE not found!"
    exit 1
fi

# ==========================================
# 2. Resolve BWS Project
# ==========================================
echo "Resolving Project ID..."
# We fetch the project list once
BWS_PROJECT_ID=$(bws_cmd project list | \
                 jq -r ".[] | select(.name==\"$BWS_PROJECT_NAME\") | .id")

if [ -z "$BWS_PROJECT_ID" ] || [ "$BWS_PROJECT_ID" == "null" ]; then
    echo "Error: Could not find BWS project '$BWS_PROJECT_NAME'"
    exit 1
fi
echo "Project ID resolved: $BWS_PROJECT_ID"

# ==========================================
# 3. Process Local .env File
# ==========================================
echo "Processing local $ENV_FILE..."

# Associative array to store local secrets: [KEY]="VALUE"
declare -A LOCAL_SECRETS

# We use sed to quit reading immediately when we hit the stop line
# We also filter out comments (#) and empty lines
while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue
    
    # Extract Key and Value (splitting at the first '=')
    key=$(echo "$line" | cut -d '=' -f 1)
    value=$(echo "$line" | cut -d '=' -f 2-)
    
    # Remove surrounding quotes if present (basic handling)
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"

    if [ -n "$key" ]; then
        LOCAL_SECRETS["$key"]="$value"
    fi
done < <(sed '/^# __SYNC_END__/q' "$ENV_FILE")

echo "Found ${#LOCAL_SECRETS[@]} secrets locally."

# ==========================================
# 4. Fetch Remote Secrets from BWS
# ==========================================
echo "Fetching remote secrets from BWS..."

# Associative arrays for remote data
declare -A REMOTE_IDS    # [KEY]="ID"
declare -A REMOTE_VALUES # [KEY]="VALUE"

# Fetch all secrets for this project
# Output format is line-delimited JSON for easy iteration
RAW_REMOTE_SECRETS=$(bws_cmd secret list "$BWS_PROJECT_ID" | jq -c '.[]')

count_remote=0
while IFS= read -r secret_json; do
    [ -z "$secret_json" ] && continue
    
    r_key=$(echo "$secret_json" | jq -r '.key')
    r_val=$(echo "$secret_json" | jq -r '.value')
    r_id=$(echo "$secret_json" | jq -r '.id')
    
    REMOTE_IDS["$r_key"]="$r_id"
    REMOTE_VALUES["$r_key"]="$r_val"
    ((count_remote++))
done <<< "$RAW_REMOTE_SECRETS"

echo "Found $count_remote secrets remotely."
echo "---------------------------------------------------"

# ==========================================
# 5. Sync Logic
# ==========================================

# --- PART A: Check Local Secrets against Remote ---
for key in "${!LOCAL_SECRETS[@]}"; do
    local_val="${LOCAL_SECRETS[$key]}"
    
    if [[ -v REMOTE_IDS["$key"] ]]; then
        # Secret exists both places
        remote_val="${REMOTE_VALUES[$key]}"
        remote_id="${REMOTE_IDS[$key]}"
        
        if [ "$local_val" == "$remote_val" ]; then
            echo "[SKIP] $key: Values match."
            # Remove from REMOTE_IDS to mark as processed (useful for Part B)
            unset REMOTE_IDS["$key"]
        else
            echo "[DIFF] $key: Local value differs from Remote."
            read -p "       Do you want to OVERWRITE the remote value? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo "       Updating remote..."
                bws_cmd secret edit "$remote_id" --key "$key" --value "$local_val" > /dev/null
                echo "       Done."
            else
                echo "       Skipped."
            fi
            # Mark as processed
            unset REMOTE_IDS["$key"]
        fi
    else
        # Secret exists locally but NOT remotely
        echo "[NEW]  $key: Found locally only."
        echo "       Creating in BWS..."
        bws_cmd secret create "$key" "$local_val" "$BWS_PROJECT_ID" > /dev/null
        echo "       Created."
    fi
done

# --- PART B: Check Remaining Remote Secrets (Remote Only) ---
# Any key left in REMOTE_IDS was not found in the local loop
for key in "${!REMOTE_IDS[@]}"; do
    remote_id="${REMOTE_IDS[$key]}"
    
    echo "[RM?]  $key: Found in Remote but NOT locally."
    read -p "       Do you want to DELETE it from remote? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "       Deleting from BWS..."
        bws_cmd secret delete "$remote_id" > /dev/null
        echo "       Deleted."
    else
        echo "       Skipped."
    fi
done

echo "---------------------------------------------------"
echo "Sync complete."