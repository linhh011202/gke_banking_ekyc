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
```

### 4. Verify
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

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| **Certificate Provisioning** | Takes time (up to 60m). Status `Provisioning` is normal. |
| **DNS not resolving** | Check Cloud Endpoints deployment: `gcloud endpoints services list` |
| **502 Bad Gateway** | Kong pod might not be ready or health check failing. Check `kubectl get events`. |
