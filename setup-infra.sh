#!/usr/bin/env bash
# =============================================================================
# setup-infra.sh
# Automates the full local infrastructure setup for ChaosDR Operator:
#   - Dual Kind clusters (primary + secondary)
#   - MinIO S3-compatible object storage
#   - Velero backup/restore engine on both clusters
#   - Sample workload deployment on primary cluster
#   - Initial Velero backup creation
# =============================================================================

set -euo pipefail

# --- Color helpers ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Prerequisite checks ---
info "Checking prerequisites..."
for cmd in docker kubectl kind helm velero; do
    if ! command -v "$cmd" &>/dev/null; then
        error "'$cmd' is not installed. Please install it before running this script."
    fi
done
info "All prerequisites found."

# NOTE: MinIO IP is determined after connecting it to the Kind network (see Step 2).

# =============================================================================
# STEP 1: Create Dual Kind Clusters
# =============================================================================
info "=== Step 1: Creating Kind clusters ==="

if kind get clusters 2>/dev/null | grep -q "^primary-cluster$"; then
    warn "primary-cluster already exists, skipping creation."
else
    info "Creating primary-cluster..."
    kind create cluster --name primary-cluster
fi

if kind get clusters 2>/dev/null | grep -q "^secondary-cluster$"; then
    warn "secondary-cluster already exists, skipping creation."
else
    info "Creating secondary-cluster..."
    kind create cluster --name secondary-cluster
fi

info "Both Kind clusters are ready."

# =============================================================================
# STEP 2: Set Up MinIO Storage
# =============================================================================
info "=== Step 2: Setting up MinIO S3 storage ==="

if docker ps -a --format '{{.Names}}' | grep -q "^minio-s3$"; then
    if docker ps --format '{{.Names}}' | grep -q "^minio-s3$"; then
        warn "minio-s3 container already running, skipping."
    else
        info "Starting existing minio-s3 container..."
        docker start minio-s3
    fi
else
    info "Launching MinIO container..."
    docker run -d --name minio-s3 \
        -p 9000:9000 -p 9001:9001 \
        -e "MINIO_ROOT_USER=minioadmin" \
        -e "MINIO_ROOT_PASSWORD=minioadmin" \
        minio/minio server /data --console-address ":9001"
fi

# Wait for MinIO to be ready
info "Waiting for MinIO to become healthy..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:9000/minio/health/live &>/dev/null; then
        info "MinIO is healthy."
        break
    fi
    if [ "$i" -eq 30 ]; then
        error "MinIO failed to start within 30 seconds."
    fi
    sleep 1
done

# Create backup bucket (using mc inside the container)
info "Creating velero-backups bucket..."
docker exec minio-s3 mc alias set myminio http://localhost:9000 minioadmin minioadmin 2>/dev/null || true
docker exec minio-s3 mc mb --ignore-existing myminio/velero-backups 2>/dev/null || true
info "MinIO bucket 'velero-backups' is ready."

# Connect MinIO to the Kind Docker network so cluster nodes can reach it directly
info "Connecting MinIO to Kind Docker network..."
docker network connect kind minio-s3 2>/dev/null || warn "MinIO already on Kind network."
MINIO_IP=$(docker inspect minio-s3 --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}')
if [ -z "$MINIO_IP" ]; then
    error "Failed to get MinIO IP on the Kind network."
fi
info "MinIO reachable from Kind clusters at: $MINIO_IP:9000"

# =============================================================================
# STEP 3: Install Velero on Both Clusters
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="$SCRIPT_DIR/credentials-velero"

if [ ! -f "$CREDS_FILE" ]; then
    error "credentials-velero file not found at $CREDS_FILE"
fi

install_velero_on_cluster() {
    local context="$1"
    info "Installing Velero on context: $context"
    kubectl config use-context "$context"

    # Check if velero namespace already exists (indicates prior install)
    if kubectl get namespace velero &>/dev/null; then
        warn "Velero namespace already exists on $context, skipping install."
        return
    fi

    velero install \
        --provider aws \
        --plugins velero/velero-plugin-for-aws:v1.8.0 \
        --bucket velero-backups \
        --secret-file "$CREDS_FILE" \
        --use-node-agent \
        --backup-location-config region=minio,s3ForcePathStyle="true",s3Url="http://${MINIO_IP}:9000"

    info "Waiting for Velero deployment to be ready on $context..."
    kubectl -n velero wait --for=condition=available deployment/velero --timeout=120s
    info "Velero is ready on $context."
}

info "=== Step 3: Installing Velero ==="
install_velero_on_cluster "kind-primary-cluster"
install_velero_on_cluster "kind-secondary-cluster"

# =============================================================================
# STEP 4: Deploy Sample Application on Primary Cluster
# =============================================================================
info "=== Step 4: Deploying sample application on primary-cluster ==="
kubectl config use-context kind-primary-cluster

if kubectl get namespace prod-e-commerce &>/dev/null; then
    warn "Namespace prod-e-commerce already exists, skipping app deployment."
else
    kubectl create namespace prod-e-commerce
    kubectl create deployment web-app --image=nginx -n prod-e-commerce
    kubectl expose deployment web-app --port=80 --type=NodePort -n prod-e-commerce

    info "Waiting for web-app deployment to be ready..."
    kubectl -n prod-e-commerce wait --for=condition=available deployment/web-app --timeout=120s
    info "Sample web-app deployed successfully."
fi

# =============================================================================
# STEP 5: Create Initial Velero Backup
# =============================================================================
info "=== Step 5: Creating initial Velero backup ==="

if velero backup get e-commerce-golden-backup &>/dev/null; then
    warn "Backup 'e-commerce-golden-backup' already exists, skipping."
else
    velero backup create e-commerce-golden-backup --include-namespaces prod-e-commerce --wait
    info "Velero backup 'e-commerce-golden-backup' created successfully."
fi

# =============================================================================
# STEP 6: Deploy CRD on Secondary Cluster
# =============================================================================
info "=== Step 6: Deploying DRPolicy CRD on secondary-cluster ==="
kubectl config use-context kind-secondary-cluster
kubectl apply -f "$SCRIPT_DIR/crd.yaml"
info "DRPolicy CRD applied."

# =============================================================================
# Summary
# =============================================================================
echo ""
info "=============================================="
info " Infrastructure setup complete!"
info "=============================================="
echo ""
info "Primary Cluster:   kind-primary-cluster   (workloads + Velero backups)"
info "Secondary Cluster: kind-secondary-cluster  (DR target + operator host)"
info "MinIO Console:     http://localhost:9001    (minioadmin / minioadmin)"
info "Velero Bucket:     velero-backups"
echo ""
info "Next steps:"
info "  1. Get the primary app NodePort:"
info "     kubectl config use-context kind-primary-cluster"
info "     kubectl get svc -n prod-e-commerce"
info ""
info "  2. Update sample-policy.yaml with the correct endpoint"
info ""
info "  3. Start the operator:"
info "     kubectl config use-context kind-secondary-cluster"
info "     source venv/bin/activate"
info "     kopf run --all-namespaces operator.py"
info ""
info "  4. Apply the DR policy:"
info "     kubectl apply -f sample-policy.yaml"
echo ""
