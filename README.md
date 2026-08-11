# Autonomous Multi-Cloud Chaos Resilience & Automated DR Controller

An intelligent Kubernetes Operator built in **Python** that continuously validates system resilience through automated chaos experiments, monitors cluster health via synthetic probes, and orchestrates cross-cloud disaster recovery failover using **Velero** — targeting an **RTO under 2 minutes**.

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
| --- | --- | --- |
| **Language** | Python 3.11+ | Core runtime for operator logic, HTTP probes, and automation |
| **Operator Framework** | `kopf` | Declarative event handling, timers, and K8s reconciliation loops |
| **K8s Client Library** | `kubernetes` SDK | Direct interaction with K8s API server for pods, deployments, CRDs |
| **Disaster Recovery** | Velero | Cloud-native backup and restore via object storage (S3/Azure Blob) |
| **Chaos Engineering** | Chaos Mesh / LitmusChaos | Injecting PodChaos, NetworkChaos, StressChaos via K8s CRDs |
| **Telemetry & Metrics** | `prometheus_client` | Exporting RTO timing, failover status, and probe latencies |
| **Local Infrastructure** | Kind / K3s / MinIO | Multi-cluster simulation on local dev environment |

---

## Key Subsystems

1. **Reconciliation Loop** (`@kopf.on.create` / `@kopf.on.update`) — Registers DRPolicy, initializes Prometheus metrics
2. **Periodic Health Probe Loop** (`@kopf.timer`, 10s interval) — Synthetic HTTP/TCP checks against the primary cluster workload
3. **Chaos Experiment Controller** — Applies `PodChaos`/`NetworkChaos` CRDs to test auto-healing
4. **Automated Failover Orchestrator** — Finds latest Velero Backup, applies Restore CRD to secondary cluster, updates DNS/routes, publishes RTO metric

---

## Project Structure

```
.
├── crd.yaml              # CustomResourceDefinition for DRPolicy
├── operator.py           # Core Python operator logic (kopf handlers)
├── requirements.txt      # Python dependencies
├── Dockerfile            # Container image for the operator
├── sample-policy.yaml    # Example DRPolicy CR instance
└── README.md             # This file
```

---

## Prerequisites

Install the following tools:

- Docker Engine (v24.0+)
- `kubectl`
- `kind` (Kubernetes in Docker)
- `helm` (v3+)
- Python 3.11+ and `pip`

---

## Environment Setup

### Step 1: Spin Up Dual Kind Clusters

```bash
# Create Primary Cluster (simulating Azure/AWS Primary)
kind create cluster --name primary-cluster

# Create Secondary Cluster (simulating GCP/On-Prem Standby)
kind create cluster --name secondary-cluster
```

### Step 2: Set Up MinIO Storage (Shared Cloud Bucket Simulation)

```bash
docker run -d --name minio-s3 \
  -p 9000:9000 -p 9001:9001 \
  -e "MINIO_ROOT_USER=minioadmin" \
  -e "MINIO_ROOT_PASSWORD=minioadmin" \
  minio/minio server /data --console-address ":9001"

# Create bucket
docker exec -it minio-s3 mc alias set myminio http://localhost:9000 minioadmin minioadmin
docker exec -it minio-s3 mc mb myminio/velero-backups
```

### Step 3: Install Velero on Both Clusters

Create `credentials-velero` file:
```
[default]
aws_access_key_id = minioadmin
aws_secret_access_key = minioadmin
```

Install Velero on each cluster:
```bash
# Primary Cluster
kubectl config use-context kind-primary-cluster
velero install \
    --provider aws \
    --plugins velero/velero-plugin-for-aws:v1.8.0 \
    --bucket velero-backups \
    --secret-file ./credentials-velero \
    --use-node-agent \
    --backup-location-config region=minio,s3ForcePathStyle="true",s3Url=http://<YOUR_LOCAL_IP>:9000

# Secondary Cluster
kubectl config use-context kind-secondary-cluster
velero install \
    --provider aws \
    --plugins velero/velero-plugin-for-aws:v1.8.0 \
    --bucket velero-backups \
    --secret-file ./credentials-velero \
    --use-node-agent \
    --backup-location-config region=minio,s3ForcePathStyle="true",s3Url=http://<YOUR_LOCAL_IP>:9000
```

---

## Deployment & Validation

### Step 1: Deploy CRD and Operator

```bash
kubectl config use-context kind-secondary-cluster

# Apply CRD
kubectl apply -f crd.yaml

# Run the Python Operator locally
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
kopf run --all-namespaces operator.py
```

### Step 2: Deploy Sample Application in Primary Cluster

```bash
kubectl config use-context kind-primary-cluster

# Deploy application
kubectl create namespace prod-e-commerce
kubectl create deployment web-app --image=nginx -n prod-e-commerce
kubectl expose deployment web-app --port=80 --type=NodePort -n prod-e-commerce

# Create initial Velero Backup
velero backup create e-commerce-golden-backup --include-namespaces prod-e-commerce --wait
```

### Step 3: Apply the DRPolicy Instance

Update `sample-policy.yaml` with your primary cluster's NodeIP and NodePort, then:

```bash
kubectl config use-context kind-secondary-cluster
kubectl apply -f sample-policy.yaml
```

### Step 4: Simulate Region Outage

```bash
kubectl config use-context kind-primary-cluster
kubectl delete namespace prod-e-commerce --now
```

### Step 5: Observe Automated Failover

Watch operator logs for automated DR execution:
```
2026-08-12 03:30:10 - WARNING - Health check probe failed for 'http://172.18.0.2:30080': ConnectionRefusedError
2026-08-12 03:30:10 - ERROR - CRITICAL: Primary endpoint is down! Evaluating Failover...
2026-08-12 03:30:10 - WARNING - Initiating Automated Multi-Cloud DR Restoration...
2026-08-12 03:30:28 - INFO - Automated Disaster Recovery completed in 18.42 seconds. Phase: Completed
```

Verify recovery in secondary cluster:
```bash
kubectl config use-context kind-secondary-cluster
kubectl get pods -n prod-e-commerce
# OUTPUT: web-app-7d58b9f787-x829q   1/1     Running   0          20s
```

---

## Prometheus Metrics

The operator exports metrics on port `8000`:

| Metric | Type | Description |
| --- | --- | --- |
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

## License

MIT
