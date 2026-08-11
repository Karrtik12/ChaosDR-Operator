import kopf
import time
import requests
import logging
from datetime import datetime
from kubernetes import client, config
from prometheus_client import start_http_server, Counter, Gauge

# --- Prometheus Metrics Definition ---
FAILOVER_EVENTS = Counter('dr_failover_events_total', 'Total number of automated failovers executed', ['policy'])
PRIMARY_HEALTH_GAUGE = Gauge('dr_primary_health_status', '1 if Primary is healthy, 0 if degraded', ['policy'])
RTO_GAUGE = Gauge('dr_last_rto_seconds', 'Last recorded Recovery Time Objective in seconds', ['policy'])

# Configure Logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# Load K8s Config (In-cluster or Kubeconfig)
try:
    config.load_incluster_config()
except config.ConfigException:
    config.load_kube_config()

# Start Prometheus Telemetry Server on Port 8000
start_http_server(8000)
logging.info("Prometheus Telemetry Exporter initialized on port 8000.")


# Helper Function: Execute Velero Restore CRD
def trigger_velero_restore(backup_name: str, target_namespace: str, logger) -> float:
    """Constructs and applies a Velero Restore CRD to execute automated restoration."""
    start_time = time.time()

    custom_api = client.CustomObjectsApi()
    restore_name = f"auto-restore-{int(time.time())}"

    restore_manifest = {
        "apiVersion": "velero.io/v1",
        "kind": "Restore",
        "metadata": {
            "name": restore_name,
            "namespace": "velero"
        },
        "spec": {
            "backupName": backup_name,
            "includedNamespaces": [target_namespace],
            "existingResourcePolicy": "update"
        }
    }

    logger.info(f"Submitting Velero Restore manifest '{restore_name}' for backup '{backup_name}'...")

    custom_api.create_namespaced_custom_object(
        group="velero.io",
        version="v1",
        namespace="velero",
        plural="restores",
        body=restore_manifest
    )

    # Wait for Restore Completion
    while True:
        time.sleep(2)
        restore_obj = custom_api.get_namespaced_custom_object(
            group="velero.io",
            version="v1",
            namespace="velero",
            plural="restores",
            name=restore_name
        )

        phase = restore_obj.get('status', {}).get('phase', 'New')
        logger.info(f"Velero Restore Status: {phase}")

        if phase in ['Completed', 'PartiallyFailed', 'Failed']:
            break

    elapsed_rto = round(time.time() - start_time, 2)
    logger.info(f"Automated Disaster Recovery completed in {elapsed_rto} seconds. Phase: {phase}")
    return elapsed_rto


# --- Kopf Event Handlers ---

@kopf.on.create('resilience.io', 'v1', 'drpolicies')
def on_drpolicy_create(spec, name, namespace, logger, **kwargs):
    """Initializes the DR Policy status upon registration."""
    logger.info(f"New DRPolicy created: '{name}' in namespace '{namespace}'.")
    PRIMARY_HEALTH_GAUGE.labels(policy=name).set(1)

    return {'phase': 'Active', 'lastHealthCheck': str(datetime.utcnow())}


@kopf.timer('resilience.io', 'v1', 'drpolicies', interval=10.0)
def monitor_primary_and_reconcile(spec, name, namespace, status, patch, logger, **kwargs):
    """Periodic health probe loop running every 10 seconds."""
    endpoint = spec.get('healthCheckEndpoint')
    backup_name = spec.get('veleroBackupName')
    target_ns = spec.get('targetNamespace')

    if not endpoint or not backup_name:
        logger.error("Invalid spec: Missing endpoint or backup configuration.")
        return

    is_healthy = False
    try:
        response = requests.get(endpoint, timeout=3.0)
        if response.status_code == 200:
            is_healthy = True
    except Exception as e:
        logger.warning(f"Health check probe failed for '{endpoint}': {str(e)}")

    if is_healthy:
        PRIMARY_HEALTH_GAUGE.labels(policy=name).set(1)
        patch.status['phase'] = 'Healthy'
        logger.debug(f"Primary endpoint '{endpoint}' is healthy.")
    else:
        PRIMARY_HEALTH_GAUGE.labels(policy=name).set(0)
        logger.error(f"CRITICAL: Primary endpoint '{endpoint}' is down! Evaluating Failover...")

        # Check if already failed over to prevent execution loops
        current_phase = status.get('phase', '')
        if current_phase == 'FailedOver':
            logger.info("System is already in 'FailedOver' state. Skipping action.")
            return

        # Execute DR Failover
        logger.warning("Initiating Automated Multi-Cloud DR Restoration...")
        rto_seconds = trigger_velero_restore(backup_name, target_ns, logger)

        # Metrics & Status Updates
        FAILOVER_EVENTS.labels(policy=name).inc()
        RTO_GAUGE.labels(policy=name).set(rto_seconds)

        patch.status['phase'] = 'FailedOver'
        patch.status['lastFailoverTime'] = datetime.utcnow().isoformat()
        patch.status['lastRtoSeconds'] = rto_seconds
