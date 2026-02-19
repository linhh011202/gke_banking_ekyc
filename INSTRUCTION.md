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

## Troubleshooting

| Issue | Solution |
|-------|----------|
| **Certificate Provisioning** | Takes time (up to 60m). Status `Provisioning` is normal. |
| **DNS not resolving** | Check Cloud Endpoints deployment: `gcloud endpoints services list` |
| **502 Bad Gateway** | Kong pod might not be ready or health check failing. Check `kubectl get events`. |
| **face-matching OOMKilled** | TF needs ~2.5GB RAM. Increase node pool machine type or the memory limit in `face-matching-deployment.yaml`. |
| **face-matching CrashLoopBackOff** | Check logs: `kubectl logs -l app=face-matching --previous`. Usually a missing secret or wrong `CONFIG_PATH`. |
| **PubSub permission denied** | Grant the GKE node service account `roles/pubsub.subscriber` on the `banking-ekyc-sign-up-sub` subscription. |
