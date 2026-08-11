# Autonomous Multi-Cloud Chaos Resilience & Automated DR Controller

A production-grade Kubernetes Operator built in **Python** using the **kopf** framework that autonomously monitors cluster health, validates resilience through chaos experiments, and orchestrates cross-cloud disaster recovery failover using **Velero** — achieving a measured **RTO of 2.03 seconds** (target was under 2 minutes).

---

## What This Project Does

Modern microservice architectures face unexpected infrastructure failures, region outages, and network degradation. Traditional DR relies on manual failover triggers or brittle shell scripts, leading to unacceptable Recovery Time Objectives (RTO > 30 minutes) and human error during high-stress outages.

This operator solves that by:

1. **Declaring DR policies as Kubernetes custom resources** — cluster admins define `DRPolicy` CRs specifying health endpoints, backup names, and failover parameters.
2. **Continuously probing primary cluster health** — a `@kopf.timer` runs every 10 seconds, sending HTTP requests to the primary workload's health endpoint.
3. **Automatically triggering cross-cloud failover** — when the primary is detected as down, the operator dynamically constructs a Velero `Restore` CR on the secondary cluster, waits for completion, and records the RTO metric.
4. **Exporting real-time telemetry** — Prometheus metrics expose failover counts, health status, and RTO measurements for Grafana dashboards.

---

## Architecture

```
                           +-------------------------------------------------------+
                           |           MANAGEMENT / DR CONTROL CLUSTER             |
                           |                                                       |
                           |    +-----------------------------------------------+  |
                           |    |            Python Kopf DR Operator            |  |
                           |    |  - Monitors Primary Health via Probes         |  |
                           |    |  - Triggers Chaos Mesh Experiments            |  |
                           |    |  - Reconciles 'DRPolicy' Custom Resources    |  |
                           |    +-----------------------+-----------------------+  |
                           +----------------------------|--------------------------+
                                                        |
                                 +----------------------+----------------------+
                                 |                                             |
                                 v                                             v
       +------------------------------------+       +------------------------------------+
       |   PRIMARY CLUSTER (e.g., Azure)     |       |   SECONDARY CLUSTER (e.g., GCP)    |
       |                                    |       |                                    |
       |  [ Workloads ] <--- (Injects Chaos)|       |  [ Warm Standby / Target ]         |
       |        |                           |       |        ^                           |
       |        v                           |       |        | (Restores Workload)       |
       |  [ Velero Backup ]                 |       |  [ Velero Restore Engine ]         |
       +--------+---------------------------+       +--------+---------------------------+
                |                                            ^
                +------------> [ Cloud Object Storage ] -----+
                               (S3 / Azure Blob / MinIO)
```

---

## Technical Stack

| Component | Technology | Purpose |
|---|---|---|
| **Language** | Python 3.11 | Core runtime for operator logic, HTTP probes, and automation |
| **Operator Framework** | `kopf` 1.37.2 | Declarative event handling, timers, and K8s reconciliation loops |
| **K8s Client Library** | `kubernetes` 30.1.0 | Direct interaction with K8s API server for pods, deployments, CRDs |
| **Disaster Recovery** | Velero 1.8+ | Cloud-native backup and restore via S3-compatible object storage |
| **Chaos Engineering** | Chaos Mesh / LitmusChaos | Injecting PodChaos, NetworkChaos, StressChaos via K8s CRDs |
| **Telemetry & Metrics** | `prometheus_client` 0.20.0 | Exporting RTO timing, failover status, and probe latencies |
| **Local Infrastructure** | Kind + MinIO | Multi-cluster simulation on local dev environment |

---

## Project Structure

```
.
├── crd.yaml              # CustomResourceDefinition for DRPolicy (resilience.io/v1)
├── operator.py           # Core Python operator logic (kopf handlers)
├── requirements.txt      # Python dependencies
├── Dockerfile            # Container image for the operator
├── sample-policy.yaml    # Example DRPolicy CR instance
├── credentials-velero    # AWS-format credentials for MinIO/Velero
├── setup-infra.sh        # Automated infrastructure bootstrap script
├── .gitignore            # Git ignore rules
└── README.md             # This file
```

---

## Prerequisites

Install the following on macOS:

```bash
# Docker Desktop (must be running)
brew install --cask docker

# CLI tools
brew install kubectl kind helm velero

# Python 3.11 (required — kopf is incompatible with Python 3.14)
brew install python@3.11
```

---

## Setup

### Option A: Automated (Recommended)

The `setup-infra.sh` script handles everything — Kind clusters, MinIO, Velero, sample workload, backup, and CRD:

```bash
# Create Python 3.11 venv and install dependencies
/opt/homebrew/bin/python3.11 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Bootstrap all infrastructure
./setup-infra.sh
```

> **Note**: After `setup-infra.sh` completes, you'll need to get the primary app's NodePort and update `sample-policy.yaml`:
> ```bash
> kubectl config use-context kind-primary-cluster
> kubectl get svc -n prod-e-commerce
> # Update sample-policy.yaml healthCheckEndpoint with <NODE_IP>:<NODE_PORT>
> ```

### Option B: Manual Step-by-Step

<details>
<summary>Click to expand manual setup instructions</summary>

#### 1. Create Dual Kind Clusters

```bash
kind create cluster --name primary-cluster
kind create cluster --name secondary-cluster
```

#### 2. Set Up MinIO Storage

```bash
docker run -d --name minio-s3 \
  -p 9000:9000 -p 9001:9001 \
  -e "MINIO_ROOT_USER=minioadmin" \
  -e "MINIO_ROOT_PASSWORD=minioadmin" \
  minio/minio server /data --console-address ":9001"

# Create bucket
docker exec minio-s3 mc alias set myminio http://localhost:9000 minioadmin minioadmin
docker exec minio-s3 mc mb myminio/velero-backups

# Connect MinIO to Kind network (critical for cluster-to-MinIO connectivity)
docker network connect kind minio-s3
MINIO_IP=$(docker inspect minio-s3 --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}')
echo "MinIO IP on Kind network: $MINIO_IP"
```

#### 3. Install Velero on Both Clusters

```bash
# Primary
kubectl config use-context kind-primary-cluster
velero install \
    --provider aws \
    --plugins velero/velero-plugin-for-aws:v1.8.0 \
    --bucket velero-backups \
    --secret-file ./credentials-velero \
    --use-node-agent \
    --backup-location-config region=minio,s3ForcePathStyle="true",s3Url=http://${MINIO_IP}:9000

# Secondary
kubectl config use-context kind-secondary-cluster
velero install \
    --provider aws \
    --plugins velero/velero-plugin-for-aws:v1.8.0 \
    --bucket velero-backups \
    --secret-file ./credentials-velero \
    --use-node-agent \
    --backup-location-config region=minio,s3ForcePathStyle="true",s3Url=http://${MINIO_IP}:9000
```

#### 4. Deploy Sample App & Create Backup

```bash
kubectl config use-context kind-primary-cluster
kubectl create namespace prod-e-commerce
kubectl create deployment web-app --image=nginx -n prod-e-commerce
kubectl expose deployment web-app --port=80 --type=NodePort -n prod-e-commerce
velero backup create e-commerce-golden-backup --include-namespaces prod-e-commerce --wait
```

#### 5. Apply CRD

```bash
kubectl config use-context kind-secondary-cluster
kubectl apply -f crd.yaml
```

</details>

---

## Running the Operator

```bash
# 1. Switch to secondary cluster (DR controller host)
kubectl config use-context kind-secondary-cluster

# 2. Activate Python 3.11 venv
source venv/bin/activate

# 3. Start the operator
kopf run --all-namespaces operator.py

# 4. In another terminal, apply the DR policy
kubectl apply -f sample-policy.yaml
```

The operator will begin probing the primary health endpoint every 10 seconds.

### Simulating a Region Outage

```bash
kubectl config use-context kind-primary-cluster
kubectl delete namespace prod-e-commerce --now
```

### Expected Operator Output

```
[03:56:14] WARNING  Health check probe failed for 'http://172.18.0.5:31698': ConnectTimeoutError
[03:56:14] ERROR    CRITICAL: Primary endpoint is down! Evaluating Failover...
[03:56:14] WARNING  Initiating Automated Multi-Cloud DR Restoration...
[03:56:14] INFO     Submitting Velero Restore manifest 'auto-restore-1786487174'...
[03:56:16] INFO     Velero Restore Status: Completed
[03:56:16] INFO     Automated Disaster Recovery completed in 2.03 seconds. Phase: Completed
[03:56:29] INFO     System is already in 'FailedOver' state. Skipping action.
```

### Verifying Recovery

```bash
kubectl config use-context kind-secondary-cluster
kubectl get pods -n prod-e-commerce
# NAME                       READY   STATUS    RESTARTS   AGE
# web-app-785556bfbd-q57gf   1/1     Running   0          47s

kubectl get drpolicy ecommerce-dr-policy -o jsonpath='{.status}' | python3 -m json.tool
# {
#     "lastFailoverTime": "2026-08-11T22:26:16.928458+00:00",
#     "lastRtoSeconds": 2.03,
#     "phase": "FailedOver"
# }
```

---

## Prometheus Metrics

The operator exports metrics on port `8000`:

| Metric | Type | Description |
|---|---|---|
| `dr_failover_events_total` | Counter | Total automated failovers executed |
| `dr_primary_health_status` | Gauge | 1 = healthy, 0 = degraded |
| `dr_last_rto_seconds` | Gauge | Last recorded RTO in seconds |

---

## Docker Build & Run

```bash
# Build
docker build -t chaosdr-operator:dev .

# Run (with kubeconfig mounted)
docker run --rm \
  -v ~/.kube/config:/root/.kube/config \
  -p 8000:8000 \
  chaosdr-operator:dev
```

---

## Findings

### Performance

| Metric | Value |
|--------|-------|
| **Measured RTO** | **2.03 seconds** |
| **Target RTO** | < 2 minutes |
| **Health check interval** | 10 seconds |
| **Failover loop guard** | Correctly prevents re-triggering |

### Key Observations

1. **Velero restore is fast for small workloads** — A single-deployment namespace restored in ~2 seconds via the MinIO backend. Larger workloads with PVCs and multi-pod deployments will take longer.

2. **The operator is stateless** — All state lives in the `DRPolicy` CR status subresource. The operator can crash and restart without losing failover context.

3. **Health probe timeout matters** — The 3-second HTTP timeout plus the 10-second timer interval means worst-case detection time is ~13 seconds before failover begins.

4. **Python 3.11 is required** — `kopf` 1.37.2 is incompatible with Python 3.14 due to changes in the `logging.Handler.lock` mechanism within thread pool executors. Python 3.11 works correctly.

5. **MinIO must be on the Kind Docker network** — Kind clusters use an isolated Docker network. MinIO must be explicitly connected to the `kind` network for Velero's BackupStorageLocation to reach it.

---

## License

MIT
