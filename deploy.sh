#!/bin/bash
set -e

# Ensure the script is running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (use sudo)."
  exit 1
fi

echo "--- Homelab 'One-Command' Restore System ---"

# 0. Update and Install Dependencies
echo "Updating system and installing dependencies..."

dnf update -y

dnf config-manager addrepo --from-repofile https://download.docker.com/linux/fedora/docker-ce.repo
dnf install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
systemctl enable --now docker

# 1. Capture the BWS Access Token
read -sp "Enter Bitwarden Secrets Manager Access Token: " BWS_ACCESS_TOKEN
echo -e "\nToken received."

# Configuration
BWS_PROJECT_NAME="Homelab"

# 2. Resolve BWS Project & Fetch Secrets
echo "Resolving Project ID and fetching secrets..."
BWS_PROJECT_ID=$(docker run --rm -e BWS_ACCESS_TOKEN=$BWS_ACCESS_TOKEN bitwarden/bws:latest project list | \
                 jq -r ".[] | select(.name==\"$BWS_PROJECT_NAME\") | .id")

if [ -z "$BWS_PROJECT_ID" ] || [ "$BWS_PROJECT_ID" == "null" ]; then
    echo "Error: Could not find BWS project '$BWS_PROJECT_NAME'"
    exit 1
fi

echo "Project ID resolved: $BWS_PROJECT_ID"

# Generate .env file directly using BWS
docker run --rm -e BWS_ACCESS_TOKEN=$BWS_ACCESS_TOKEN bitwarden/bws:latest secret list $BWS_PROJECT_ID --output env > .env
chmod 600 .env

# Load and Export variables for this script
set -a
source .env
set +a

# 3. Environment Guard (Validation)
REQUIRED_VARS=("KOPIA_PASSWORD" "B2_BUCKET_NAME" "B2_APP_KEY_ID" "B2_APP_KEY" "B2_BUCKET_ENDPOINT")
for VAR in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!VAR}" ]; then
        echo "ERROR: Required environment variable '$VAR' is missing from Bitwarden."
        exit 1
    fi
done

# 4. Kopia Restore
echo "Connecting and Restoring from Backblaze B2..."

# Check if storage directory exists
if [ -d "/storage" ]; then
    echo "ERROR: /storage directory already exists. Please remove or rename it before proceeding."
    exit 1
fi

# We use a single docker run and pass a string of commands to /bin/sh
docker run --rm \
  -v "/storage:/data/storage" \
  -e KOPIA_PASSWORD="$KOPIA_PASSWORD" \
  --entrypoint "/bin/sh" \
  --hostname homelab \
  kopia/kopia:latest -c "
    kopia repository connect s3 \
      --bucket='$B2_BUCKET_NAME' \
      --endpoint='$B2_BUCKET_ENDPOINT' \
      --access-key='$B2_APP_KEY_ID' \
      --secret-access-key='$B2_APP_KEY' && \
    kopia snapshot restore /data/storage
  "

echo "Data restoration complete."

# --- 5. Host Preparation ---
echo "Preparing host environment..."
echo "Disabling systemd-resolved service to run adguard..."

systemctl stop systemd-resolved
systemctl disable systemd-resolved
rm /etc/resolv.conf
echo "nameserver 1.1.1.1" | tee /etc/resolv.conf

# --- 6. Launch Infrastructure ---
echo "Launching all services from the 'services/' directory..."

# Find all docker-compose.yml files exactly one level deep inside 'services/'
# Then loop through them
for compose_file in services/*/docker-compose.yml; do
    if [ -f "$compose_file" ]; then
        service_name=$(basename "$(dirname "$compose_file")")
        echo "Starting service: $service_name"
        
        # Use --env-file to point to the root .env we fetched from BWS
        # --project-directory ensures relative paths in the yml resolve correctly
        docker compose --env-file .env -f "$compose_file" up -d
    fi
done

echo "All services started."

# 7. Cleanup
unset BWS_ACCESS_TOKEN
echo "--- SYSTEM RESTORED SUCCESSFULLY ---"