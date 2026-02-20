# GKE Banking eKYC — Deployment Documentation

## Architecture Overview

```
Internet (Client)
  │
  ▼
┌──────────────────────────────────────────────┐
│  Cloud Endpoints DNS (api.endpoints...)      │
│  GKE Ingress (Global Static IP 34.120.0.187) │
│  + Google Managed Certificate (SSL)          │
└──────────────────────┬───────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────┐
│  Kong API Gateway (NodePort Service)         │
└──────────────────────┬───────────────────────┘
                       │ route: / → identity-service
                       ▼
┌──────────────────────────────────────────────┐
│  Identity Service (ClusterIP Service)        │
│  • Handles user auth, registration, eKYC     │
│  • Publishes "user_ekyc_completed" to PubSub │
└──────────────────────────────────────────────┘

  Google Cloud PubSub
  (banking-ekyc-sign-up topic)
          │
          ▼
┌──────────────────────────────────────────────┐
│  Face Matching Worker (PubSub Subscriber)    │
│  • No HTTP port — runs as internal worker    │
│  • Downloads eKYC images from Firebase       │
│  • Extracts ArcFace 512-dim embeddings (TF)  │
│  • Stores embeddings in Neon pgvector DB     │
└──────────────────────────────────────────────┘
```

## Access Points

| Endpoint | URL |
|----------|-----|
| **API Domain** | **https://api.endpoints.banking-ekyc-487718.cloud.goog** |
| Swagger Docs | https://api.endpoints.banking-ekyc-487718.cloud.goog/docs |
| Ingress IP | `34.120.0.187` |

> **Certificate Status**: Google Managed Certificates take **15-60 minutes** to provision. Until then, you may see SSL errors. Use `kubectl get managedcertificate` to check status.

---

## Deployment Steps

### Prerequisites
- `gcloud` CLI authenticated
- `kubectl` configured

### 1. Reserve Global IP
```bash
gcloud compute addresses create kong-ingress-ip --global
```

### 2. Configure DNS (Cloud Endpoints)
Deploy `openapi.yaml` to create the DNS mapping:
```bash
gcloud endpoints services deploy openapi.yaml --project banking-ekyc-487718
```

### 3. Deploy Application & Ingress
```bash
cd /path/to/gke_banking_ekyc

# Apply Identity Service
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml  # Must be ClusterIP

# Apply Kong
kubectl apply -f kong-configmap.yaml
kubectl apply -f kong-deployment.yaml
kubectl apply -f kong-service.yaml # Must be NodePort

# Apply Ingress & Certs
kubectl apply -f managed-cert.yaml
kubectl apply -f frontend-config.yaml
kubectl apply -f ingress.yaml

# Apply Face Matching Worker
kubectl apply -f face-matching-deployment.yaml
```

### 4. Set up Face Matching secrets (first time only)

The face-matching worker needs its own K8s secret with `config.yaml` and `firebase_credentials.json`:

```bash
# Fetch firebase credentials from Secret Manager
gcloud secrets versions access latest \
  --secret=firebase-credentials \
  --project=banking-ekyc-487718 > firebase_credentials.json

# Create the secret (replace config.yaml with face_matching's config)
kubectl create secret generic face-matching-secrets \
  --from-file=config.yaml=<path-to-face-matching-config.yaml> \
  --from-file=firebase_credentials.json=firebase_credentials.json
```

> **Note:** The face-matching worker is a PubSub subscriber, **not** a web server.
> It has no Service or Ingress — it connects outbound to PubSub and Neon DB.

### 5. Verify
Check Certificate Status:
```bash
kubectl get managedcertificate kong-managed-cert
# Expect: "Provisioning" -> "Active"
```

Check DNS:
```bash
ping api.endpoints.banking-ekyc-487718.cloud.goog
# Expect: Reply from 34.120.0.187
```

Check Face Matching worker:
```bash
kubectl get pods -l app=face-matching
# Expect: STATUS=Running

kubectl logs -l app=face-matching -f
# Expect: "PubSubSubscriber initialized", "Starting PubSub subscriber on..."
```

---

---

## Cost Optimization (Auto Scale-Down)

GKE nodes run continuously even with no traffic, incurring unnecessary costs. Follow the steps below to **shut down the cluster when not in use**.

### 1. Enable Cluster Autoscaler with min-nodes = 0

When all deployments scale to 0 replicas, the cluster autoscaler automatically removes idle nodes after ~10 minutes.

```bash
# Replace POOL_NAME with your node pool name (see: gcloud container node-pools list --cluster=banking-ekyc-cluster --region=us-central1)
gcloud container clusters update banking-ekyc-cluster \
  --region us-central1 \
  --project banking-ekyc-487718

gcloud container node-pools update <POOL_NAME> \
  --cluster banking-ekyc-cluster \
  --region us-central1 \
  --enable-autoscaling \
  --min-nodes=0 \
  --max-nodes=3
```

### 2. Use Spot Nodes (save 60–91%)

```bash
# Add a dedicated node pool using Spot VMs
gcloud container node-pools create spot-pool \
  --cluster banking-ekyc-cluster \
  --region us-central1 \
  --spot \
  --machine-type=e2-standard-2 \
  --enable-autoscaling \
  --min-nodes=0 \
  --max-nodes=3 \
  --num-nodes=0
```

> **Note:** Spot nodes can be preempted by Google at any time — use only for dev/staging, not production.

### 3. Manual scale (fastest)

```bash
# Stop everything when not in use
./scripts/scale-down.sh

# Bring it back up when needed
./scripts/scale-up.sh
```

### 4. Auto-scale on working hours (Mon–Fri, 07:00–23:00 ICT)

```bash
kubectl apply -f auto-scale-cronjob.yaml

# Check CronJob status
kubectl get cronjobs
# NAME             SCHEDULE      SUSPEND   ACTIVE
# scale-down-eod   0 16 * * 1-5  False     0
# scale-up-sod     0 0  * * 1-5  False     0

# Run immediately (no need to wait for the schedule)
kubectl create job --from=cronjob/scale-down-eod test-scale-down
kubectl logs -l job-name=test-scale-down -f
```

### 5. Estimated savings

| Configuration | Estimated cost/month |
|---------------|----------------------|
| Standard nodes, 24/7 | ~$120–200 |
| Standard nodes, 8h/day × 5 days/week | ~$35–60 |
| Spot nodes, 8h/day × 5 days/week | ~$5–15 |

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| **Certificate Provisioning** | Takes time (up to 60m). Status `Provisioning` is normal. |
| **DNS not resolving** | Check Cloud Endpoints deployment: `gcloud endpoints services list` |
| **502 Bad Gateway** | Kong pod might not be ready or health check failing. Check `kubectl get events`. |
| **face-matching OOMKilled** | TF needs ~2.5GB RAM. Increase node pool machine type or the memory limit in `face-matching-deployment.yaml`. |
| **face-matching CrashLoopBackOff** | Check logs: `kubectl logs -l app=face-matching --previous`. Usually a missing secret or wrong `CONFIG_PATH`. |
| **PubSub 403 publish denied** | The pod SA lacks `roles/pubsub.publisher`. Either grant it to the node SA (`<PROJECT_NUMBER>-compute@developer.gserviceaccount.com`) or use Workload Identity: create `identity-service-sa`, grant it `roles/pubsub.publisher`, annotate K8s SA `identity-service-ksa`, and set `serviceAccountName: identity-service-ksa` in `deployment.yaml`. |
| **PubSub 403 subscribe denied** | Grant the GKE node service account `roles/pubsub.subscriber` on the `banking-ekyc-sign-up-sub` subscription. |
