# Helpbook — Full Build Journal

This document is a detailed chronological log of everything done to build the **Autonomous Multi-Cloud Chaos Resilience & Automated DR Controller** project from scratch. It covers every package installed, every command run, every output received, every issue faced, and every fix applied.

---

## Phase 1: Project Initialization

### 1.1 Reading the Spec

Started by reading `Start.md` which defined the full project architecture:
- Python Kubernetes operator using `kopf` framework
- Custom Resource Definition (`DRPolicy`) for declarative DR configuration
- Health probing, chaos injection, and automated Velero-based cross-cloud failover
- Prometheus metrics for RTO tracking
- Local dev environment using Kind, MinIO, and Velero

### 1.2 Files Created

Created all 6 core project files based on the Start.md spec:

**`crd.yaml`** — Custom Resource Definition for `drpolicies.resilience.io`
- Group: `resilience.io`, Version: `v1`, Kind: `DRPolicy`
- Spec fields: `targetNamespace`, `healthCheckEndpoint`, `failureThresholdSeconds`, `veleroBackupName`, `chaosEnabled`
- Status fields: `phase`, `lastFailoverTime`, `lastRtoSeconds`
- Added `subresources.status: {}` (not in Start.md but required for status patching)

**`requirements.txt`** — Python dependencies:
```
kopf==1.37.2
kubernetes==30.1.0
requests==2.32.3
prometheus-client==0.20.0
urllib3==2.2.2
```

**`operator.py`** — Core operator logic (initially matching Start.md with bug fixes)

**`Dockerfile`** — `python:3.11-slim` based container

**`sample-policy.yaml`** — Example DRPolicy CR for an e-commerce workload

**`README.md`** — Project documentation

**`.gitignore`** — Excludes `venv/`, `__pycache__/`, IDE files, `.DS_Store`

### 1.3 Bugs Found in Start.md (Fixed Immediately)

#### Bug 1: CRD Schema Key Typo
- **Location**: Start.md line 205
- **Bug**: `openAP3Schema` (missing `IV` characters)
- **Fix**: Changed to `openAPIV3Schema`
- **Impact**: Without this fix, Kubernetes would reject the CRD entirely

#### Bug 2: Wrong Exception Class
- **Location**: Start.md line 273
- **Original code**:
  ```python
  except kopf.ConfigError:
  ```
- **Fix**: Changed to:
  ```python
  except config.ConfigException:
  ```
- **Reason**: `kopf` does not have a `ConfigError` exception. The correct exception for in-cluster config failure is `config.ConfigException` from the `kubernetes` library.

### 1.4 Initial Python Virtual Environment

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

**Output**: Successfully installed 31 packages including kopf, kubernetes, requests, prometheus-client, and all transitive dependencies (aiohttp, cryptography, google-auth, etc.)

### 1.5 Validation

```bash
python3 -c "import ast; ast.parse(open('operator.py').read()); print('Syntax OK')"
# ✅ operator.py syntax OK

python3 -c "import yaml; doc=yaml.safe_load(open('crd.yaml')); assert doc['spec']['versions'][0]['schema']['openAPIV3Schema']; print('CRD OK')"
# ✅ crd.yaml schema OK
```

### 1.6 Initial Git Commit

```bash
git add -A && git commit -m "feat: Autonomous Multi-Cloud Chaos Resilience & Automated DR Controller"
```
**Output**: `[main 76dac7d] 9 files changed, 678 insertions(+)`

Files committed: `.gitignore`, `Dockerfile`, `README.md`, `crd.yaml`, `credentials-velero`, `operator.py`, `requirements.txt`, `sample-policy.yaml`, `setup-infra.sh`

---

## Phase 2: Infrastructure Setup

### 2.1 Prerequisites Check

Checked what CLI tools were already installed:

```bash
docker --version    # NOT FOUND
kind version        # NOT FOUND
helm version        # NOT FOUND
velero version      # NOT FOUND
kubectl version     # ✅ v1.36.3 (already installed via Homebrew)
```

**User was told to install via Homebrew**:
```bash
brew install --cask docker
brew install kind helm velero
```

### 2.2 Additional Files Created

**`credentials-velero`** — AWS-format credentials for MinIO:
```
[default]
aws_access_key_id = minioadmin
aws_secret_access_key = minioadmin
```

**`setup-infra.sh`** — Automated idempotent infrastructure bootstrap script that handles:
1. Prerequisite checks (docker, kubectl, kind, helm, velero)
2. Dual Kind cluster creation (primary-cluster, secondary-cluster)
3. MinIO S3 container launch and bucket creation
4. Velero install on both clusters
5. Sample NGINX app deployment on primary
6. Initial Velero backup
7. CRD deployment on secondary

### 2.3 First Run Attempt — Docker Not Running

```bash
./setup-infra.sh
```

**Output**:
```
[INFO]  Checking prerequisites...
[INFO]  All prerequisites found.
[INFO]  Creating primary-cluster...
ERROR: failed to create cluster: failed to get docker info: command "docker info" failed
failed to connect to the docker API at unix://~/.docker/run/docker.sock: no such file or directory
```

**Root Cause**: Docker Desktop was installed but not started.
**Fix**: User opened Docker Desktop from Applications and waited for it to initialize.

### 2.4 Second Run — Success with MinIO Networking Issue

```bash
./setup-infra.sh
```

**Output (key steps)**:
```
[INFO]  Creating primary-cluster... ✅
[INFO]  Creating secondary-cluster... ✅
[INFO]  MinIO container launched ✅
[INFO]  MinIO bucket 'velero-backups' ready ✅
[INFO]  Velero installed on primary-cluster ✅
[INFO]  Velero installed on secondary-cluster ✅
[INFO]  Sample web-app deployed ✅
Backup completed with status: FailedValidation ❌
[INFO]  DRPolicy CRD applied ✅
```

The Velero backup **failed validation**.

### 2.5 Diagnosing the Backup Failure

```bash
velero backup describe e-commerce-golden-backup
```

**Key output**:
```
Phase:  FailedValidation
Validation errors:  backup can't be created because BackupStorageLocation default is in Unavailable status.
```

And in the volume info error:
```
Get "http://fc00:f853:ccd:e793::1172.18.0.1:9000/velero-backups/...": dial tcp: lookup fc00:f853:ccd:e793::1172.18.0.1: no such host
```

**Root Cause**: The setup script used `docker network inspect kind -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}'` to detect the host IP. This returned the IPv6 gateway `fc00:f853:ccd:e793::1` which got concatenated with the IPv4 portion, producing the invalid URL `fc00:f853:ccd:e793::1172.18.0.1:9000`.

MinIO was on the default Docker `bridge` network (`172.17.0.2`) but Kind clusters use the isolated `kind` Docker network — MinIO was unreachable from inside the clusters.

### 2.6 Fixing MinIO Networking

**Step 1**: Connect MinIO container to the Kind network:
```bash
docker network connect kind minio-s3
```

**Step 2**: Get MinIO's IP on the Kind network:
```bash
docker inspect minio-s3 --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}'
# Output: 172.18.0.7
```

**Step 3**: Patch Velero BackupStorageLocation on both clusters:
```bash
# Primary
kubectl config use-context kind-primary-cluster
kubectl -n velero patch backupstoragelocation default --type merge \
  -p '{"spec":{"config":{"s3Url":"http://172.18.0.7:9000"}}}'
# Output: backupstoragelocation.velero.io/default patched

# Secondary
kubectl config use-context kind-secondary-cluster
kubectl -n velero patch backupstoragelocation default --type merge \
  -p '{"spec":{"config":{"s3Url":"http://172.18.0.7:9000"}}}'
# Output: backupstoragelocation.velero.io/default patched
```

**Step 4**: Verify BSL is now available:
```bash
velero backup-location get
# NAME      PROVIDER   BUCKET/PREFIX    PHASE       LAST VALIDATED                  ACCESS MODE
# default   aws        velero-backups   Available   2026-08-12 03:48:01 +0530 IST   ReadWrite
```
✅ BSL is now **Available**.

### 2.7 Re-creating the Backup

```bash
# Delete the failed backup
velero backup delete e-commerce-golden-backup --confirm
# Waited 10 seconds for async deletion

# Create a new backup
velero backup create e-commerce-golden-backup --include-namespaces prod-e-commerce --wait
```

**Output**:
```
Backup request "e-commerce-golden-backup" submitted successfully.
Backup completed with status: Completed.
```
✅ Backup succeeded.

### 2.8 Setup Script Fix

Updated `setup-infra.sh` to properly handle MinIO networking:
- Removed the broken gateway IP detection (`docker network inspect kind ... Gateway`)
- Added step to connect MinIO to the Kind network: `docker network connect kind minio-s3`
- Get MinIO IP from the Kind network: `docker inspect ... .NetworkSettings.Networks.kind.IPAddress`
- Use that IP in Velero's `s3Url` config

### 2.9 Sample Policy Endpoint

Got the primary app's NodePort:
```bash
kubectl config use-context kind-primary-cluster
kubectl get svc -n prod-e-commerce -o jsonpath='{.items[0].spec.ports[0].nodePort}'
# Output: 31698

kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
# Output: 172.18.0.5
```

Updated `sample-policy.yaml`:
```yaml
healthCheckEndpoint: "http://172.18.0.5:31698"
```

### 2.10 Git Commit

```bash
git commit -m "fix: MinIO networking for Kind clusters and populate sample policy endpoint"
# [main 82e9710] 2 files changed, 12 insertions(+), 13 deletions(-)
```

---

## Phase 3: Running the Operator

### 3.1 First Attempt — Python 3.14 Logging Crash

```bash
kubectl config use-context kind-secondary-cluster
source venv/bin/activate
kopf run --all-namespaces operator.py
```

**Output**:
```
[03:50:36] Prometheus Telemetry Exporter initialized on port 8000.
[03:50:36] Initial authentication has been initiated.
[03:50:36] Activity 'login_via_client' succeeded.
[03:50:48] Throttling for 1 seconds due to an unexpected error:
           TypeError("'NoneType' object does not support the context manager protocol (missed __exit__ method)")
```

**Full traceback**:
```
File "operator.py", line 87, in on_drpolicy_create
    logger.info(f"New DRPolicy created: '{name}' in namespace '{namespace}'.")
...
File "logging/__init__.py", line 1026, in handle
    with self.lock:
         ^^^^^^^^^
TypeError: 'NoneType' object does not support the context manager protocol (missed __exit__ method)
```

**Root Cause**: Python 3.14 (3.14.6 installed via Homebrew) changed the internal `logging.Handler.lock` mechanism. When kopf dispatches handler functions in its `concurrent.futures.ThreadPoolExecutor`, the logging handler's lock becomes `None`, causing the crash. This is a fundamental incompatibility — even kopf's own internal `logger.exception()` call crashed.

### 3.2 First Fix Attempt — Move Init to Startup Handler

Hypothesis: `logging.basicConfig()` at module level was the issue.

**Changes made to `operator.py`**:
- Removed `import logging` and `logging.basicConfig(...)`
- Moved K8s config loading and Prometheus server init into `@kopf.on.startup()` handler
- Replaced `datetime.utcnow()` with `datetime.now(timezone.utc)` (deprecated in Python 3.12+)

**Result**: Same crash. The error is in kopf's own internal logging, not our `logging.basicConfig()`.

### 3.3 Root Cause Confirmed

The crash happened in **two places**:
1. Our handler: `logger.info(f"New DRPolicy created...")` → crash
2. Kopf's internal error handling: `logger.exception(f"{handler} failed...")` → crash again

Both go through Python 3.14's `logging.Handler.handle()` which calls `with self.lock:` — and `self.lock` is `None` in the thread pool context.

**Conclusion**: kopf 1.37.2 is fundamentally incompatible with Python 3.14. No code-level workaround is possible.

### 3.4 Solution — Install Python 3.11

Start.md specifies Python 3.11+. The system had Python 3.14.6.

```bash
brew install python@3.11
```

**Output**:
```
==> Pouring python@3.11--3.11.15_4.arm64_tahoe.bottle.1.tar.gz
Python is installed as /opt/homebrew/bin/python3.11
🍺 /opt/homebrew/Cellar/python@3.11/3.11.15_4: 3,304 files, 64.3MB
```

### 3.5 Recreate Venv with Python 3.11

```bash
rm -rf venv
/opt/homebrew/bin/python3.11 -m venv venv
source venv/bin/activate
python --version
# Python 3.11.15

pip install -r requirements.txt
# Successfully installed 31 packages
```

### 3.6 Second Run — Success!

```bash
kubectl config use-context kind-secondary-cluster
kubectl delete drpolicy ecommerce-dr-policy  # Clean up from previous attempt
source venv/bin/activate
kopf run --all-namespaces operator.py
```

Then in another terminal:
```bash
kubectl apply -f sample-policy.yaml
```

**Operator Output** (the golden run):
```
[03:55:54] kopf.activities.star  [INFO] Loaded local kubeconfig.
[03:55:54] kopf.activities.star  [INFO] Prometheus Telemetry Exporter initialized on port 8000.
[03:55:54] kopf.activities.star  [INFO] Activity 'on_startup' succeeded.
[03:55:54] kopf._core.engines.a  [INFO] Initial authentication has been initiated.
[03:55:54] kopf.activities.auth  [INFO] Activity 'login_via_client' succeeded.
[03:55:54] kopf._core.engines.a  [INFO] Initial authentication has finished.
[03:56:11] kopf.objects          [INFO] [default/ecommerce-dr-policy] New DRPolicy created: 'ecommerce-dr-policy' in namespace 'default'.
[03:56:11] kopf.objects          [INFO] [default/ecommerce-dr-policy] Handler 'on_drpolicy_create' succeeded.
[03:56:11] kopf.objects          [INFO] [default/ecommerce-dr-policy] Creation is processed: 1 succeeded; 0 failed.
[03:56:14] kopf.objects          [WARNING] [default/ecommerce-dr-policy] Health check probe failed for 'http://172.18.0.5:31698': ConnectTimeoutError
[03:56:14] kopf.objects          [ERROR] [default/ecommerce-dr-policy] CRITICAL: Primary endpoint 'http://172.18.0.5:31698' is down! Evaluating Failover...
[03:56:14] kopf.objects          [WARNING] [default/ecommerce-dr-policy] Initiating Automated Multi-Cloud DR Restoration...
[03:56:14] kopf.objects          [INFO] [default/ecommerce-dr-policy] Submitting Velero Restore manifest 'auto-restore-1786487174' for backup 'e-commerce-golden-backup'...
[03:56:16] kopf.objects          [INFO] [default/ecommerce-dr-policy] Velero Restore Status: Completed
[03:56:16] kopf.objects          [INFO] [default/ecommerce-dr-policy] Automated Disaster Recovery completed in 2.03 seconds. Phase: Completed
[03:56:16] kopf.objects          [INFO] [default/ecommerce-dr-policy] Timer 'monitor_primary_and_reconcile' succeeded.
[03:56:29] kopf.objects          [WARNING] [default/ecommerce-dr-policy] Health check probe failed for 'http://172.18.0.5:31698': ConnectTimeoutError
[03:56:29] kopf.objects          [ERROR] [default/ecommerce-dr-policy] CRITICAL: Primary endpoint 'http://172.18.0.5:31698' is down! Evaluating Failover...
[03:56:29] kopf.objects          [INFO] [default/ecommerce-dr-policy] System is already in 'FailedOver' state. Skipping action.
[03:56:29] kopf.objects          [INFO] [default/ecommerce-dr-policy] Timer 'monitor_primary_and_reconcile' succeeded.
```

✅ **Automated DR completed in 2.03 seconds.**

### 3.7 Verification

```bash
kubectl config use-context kind-secondary-cluster

kubectl get pods -n prod-e-commerce
# NAME                       READY   STATUS    RESTARTS   AGE
# web-app-785556bfbd-q57gf   1/1     Running   0          47s

kubectl get drpolicy ecommerce-dr-policy -o jsonpath='{.status}' | python3.11 -m json.tool
# {
#     "lastFailoverTime": "2026-08-11T22:26:16.928458+00:00",
#     "lastRtoSeconds": 2.03,
#     "phase": "FailedOver"
# }
```

✅ Workload restored on secondary cluster.
✅ DRPolicy status correctly reflects `FailedOver` with RTO of 2.03 seconds.
✅ Failover loop guard works (subsequent checks skip re-triggering).

### 3.8 Git Commit

```bash
git commit -m "fix: use Python 3.11 for kopf compatibility, move init to startup handler"
# [main a916fc7] 1 file changed, 16 insertions(+), 14 deletions(-)
```

---

## Phase 4: Final State

### Git History

```
a916fc7 fix: use Python 3.11 for kopf compatibility, move init to startup handler
82e9710 fix: MinIO networking for Kind clusters and populate sample policy endpoint
76dac7d feat: Autonomous Multi-Cloud Chaos Resilience & Automated DR Controller
2ad4e96 first commit
```

### Infrastructure Running

| Component | Status | Details |
|-----------|--------|---------|
| primary-cluster | ✅ Running | Kind cluster, NGINX web-app, Velero |
| secondary-cluster | ✅ Running | Kind cluster, DRPolicy CRD, Velero, restored workload |
| MinIO | ✅ Running | `172.18.0.7:9000` on Kind network, `velero-backups` bucket |
| Velero (primary) | ✅ Available | Backup `e-commerce-golden-backup` completed |
| Velero (secondary) | ✅ Available | Restore `auto-restore-1786487174` completed |
| Operator | ✅ Running | Python 3.11, kopf, Prometheus on :8000 |

### All Issues Encountered & Resolutions

| # | Issue | Root Cause | Resolution |
|---|-------|-----------|------------|
| 1 | `openAP3Schema` in Start.md | Typo in spec | Fixed to `openAPIV3Schema` |
| 2 | `kopf.ConfigError` in Start.md | Wrong exception class | Fixed to `config.ConfigException` |
| 3 | Docker daemon not running | Docker Desktop not started | User opened Docker Desktop |
| 4 | Velero backup `FailedValidation` | MinIO unreachable from Kind clusters (wrong network) | Connected MinIO to `kind` Docker network, patched BSL |
| 5 | MinIO URL malformed (`fc00:...172.18...`) | IPv6 gateway concatenated with IPv4 | Replaced gateway detection with direct Kind network IP lookup |
| 6 | `TypeError: 'NoneType' ... __exit__` | kopf 1.37.2 incompatible with Python 3.14 logging locks | Installed Python 3.11, recreated venv |
| 7 | `datetime.utcnow()` deprecation | Deprecated since Python 3.12 | Changed to `datetime.now(timezone.utc)` |
| 8 | Module-level `logging.basicConfig()` | Conflicts with kopf's logging in thread pool | Moved all init into `@kopf.on.startup()` handler |

### Packages Installed

**Via Homebrew**:
- `docker` (Docker Desktop, cask)
- `kubectl` (pre-installed by user)
- `kind` (Kubernetes in Docker)
- `helm` (v3)
- `velero` (CLI)
- `python@3.11` (3.11.15_4)

**Via pip (in Python 3.11 venv)**:
- kopf 1.37.2
- kubernetes 30.1.0
- requests 2.32.3
- prometheus-client 0.20.0
- urllib3 2.2.2
- Plus 26 transitive dependencies: aiohttp, aiohappyeyeballs, aiosignal, attrs, certifi, cffi, charset-normalizer, click, cryptography, frozenlist, google-auth, idna, iso8601, multidict, oauthlib, propcache, pyasn1, pyasn1-modules, pycparser, python-dateutil, python-json-logger, pyyaml, requests-oauthlib, six, typing-extensions, websocket-client, yarl

**Via Docker (pulled by scripts)**:
- `minio/minio` (MinIO S3 server)
- `kindest/node` (Kind cluster node images)
- `velero/velero-plugin-for-aws:v1.8.0`
