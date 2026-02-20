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

GKE nodes chạy liên tục dù không có traffic → tốn tiền. Các bước dưới đây giúp **tắt cluster khi không dùng**.

### 1. Bật Cluster Autoscaler với min-nodes = 0

Khi tất cả deployments scale về 0 replicas, cluster autoscaler sẽ tự xóa node idle sau ~10 phút.

```bash
# Thay POOL_NAME bằng tên node pool của bạn (xem: gcloud container node-pools list --cluster=banking-ekyc-cluster --region=us-central1)
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

### 2. Dùng Spot Nodes (tiết kiệm 60–91%)

```bash
# Thêm node pool riêng dùng Spot VM
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

> **Lưu ý:** Spot nodes có thể bị Google preempt bất kỳ lúc nào — chỉ nên dùng cho dev/staging, không dùng cho production.

### 3. Scale thủ công (nhanh nhất)

```bash
# Tắt tất cả khi không dùng
./scripts/scale-down.sh

# Bật lại khi cần
./scripts/scale-up.sh
```

### 4. Tự động scale theo giờ làm việc (Mon–Fri, 07:00–23:00 ICT)

```bash
kubectl apply -f auto-scale-cronjob.yaml

# Kiểm tra CronJob
kubectl get cronjobs
# NAME             SCHEDULE      SUSPEND   ACTIVE
# scale-down-eod   0 16 * * 1-5  False     0
# scale-up-sod     0 0  * * 1-5  False     0

# Chạy thử ngay (không cần đợi schedule)
kubectl create job --from=cronjob/scale-down-eod test-scale-down
kubectl logs -l job-name=test-scale-down -f
```

### 5. Ước tính tiết kiệm

| Cấu hình | Chi phí/tháng (ước tính) |
|----------|--------------------------|
| Standard nodes, 24/7 | ~$120–200 |
| Standard nodes, 8h/ngày × 5 ngày/tuần | ~$35–60 |
| Spot nodes, 8h/ngày × 5 ngày/tuần | ~$5–15 |

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
