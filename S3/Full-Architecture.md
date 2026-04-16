# Full Production Architecture - Multi-Region Kubernetes + DR Setup

---

## 1. Overview

```
User (Browser/Mobile)
        |
   Route53 / Global Accelerator (DNS Failover)
        |
   _____|_____
   |         |
Mumbai     Chennai
Cluster    Cluster
   |         |
   DB LB    DB LB
   |         |
DB-PROD-A  DB-PROD-B
(Primary)  (Replica)
```

---

## 2. Kubernetes Cluster Architecture

### Per Region - Same Structure

```
EKS Cluster (Mumbai / Chennai)
  |
  |-- Namespaces
        |-- dev
        |     |-- dev-nginx (Deployment, Service)
        |     |-- dev-busybox (Deployment)
        |
        |-- stage
        |     |-- stage-nginx (Deployment, Service)
        |     |-- stage-busybox (Deployment)
        |
        |-- prod
              |-- prod-nginx (Deployment, Service)
              |-- prod-busybox (Deployment)
              |-- prod-backend (Deployment, Service)
```

### Node Setup (Per Node Default Components)

| Component     | Role                              |
|---------------|-----------------------------------|
| kubelet       | Pod lifecycle management          |
| kube-proxy    | Service networking (iptables)     |
| containerd    | Container runtime                 |
| aws-node (CNI)| VPC networking for pods           |
| kindnet/flannel| Overlay network (local cluster)  |

---

## 3. Namespace Strategy

| Namespace | Purpose             | Replicas | Resources  |
|-----------|---------------------|----------|------------|
| dev       | Development testing | 2        | Low        |
| stage     | Pre-prod testing    | 2        | Medium     |
| prod      | Live traffic        | 3+       | High       |
| kube-system| Core K8s components| -        | -          |

---

## 4. Application Deployment

### Deployment (per env)

```yaml
# dev example
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dev-nginx
  namespace: dev
spec:
  replicas: 2          # dev: 2, stage: 2, prod: 3+
  template:
    spec:
      containers:
      - name: nginx
        image: docker.io/library/nginx:alpine
        resources:
          requests:
            cpu: 50m       # dev low, prod high
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 256Mi
```

### Service (ClusterIP - internal)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: prod-nginx-svc
  namespace: prod
spec:
  type: ClusterIP       # internal only
  selector:
    app: prod-nginx
  ports:
  - port: 80
    targetPort: 80
```

### Ingress (external access)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prod-nginx-ingress
  namespace: prod
spec:
  ingressClassName: nginx
  rules:
  - host: www.myapp.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: prod-nginx-svc
            port:
              number: 80
```

---

## 5. Networking Flow

```
Internet User
     |
     v
Route53 (DNS) -> www.myapp.com
     |
     v
AWS Global Accelerator / ALB
     |
     v
Ingress Controller (nginx/alb)
     |
     v
Service (ClusterIP) -> prod-nginx-svc
     |
     v
Pods (prod-nginx-xxx) on Worker Nodes
     |
     v
Backend API Pods
     |
     v
DB-LB-PROD (Load Balancer)
     |
  ---|----------|----------
  |            |           |
DB-PROD-A   DB-PROD-B   DB-PROD-C
(Primary)   (Replica)   (Replica)
```

---

## 6. Database Architecture

### Single Region

```
DB-LB-PROD
  |-- DB-PROD-A (Primary - Read + Write)
  |-- DB-PROD-B (Replica - Read only)
  |-- DB-PROD-C (Replica - Read only)
```

### Multi-Region (Mumbai + Chennai)

```
Mumbai                        Chennai
DB-LB-PROD-MUM               DB-LB-PROD-CHN
  |                              |
DB-PROD-A (Primary) <---------> DB-PROD-B (Replica)
  Writes here                   Promoted on failover
```

### Failover Flow

```
1. Mumbai cluster/DB down
2. Route53 health check detects failure (~30-60 sec)
3. DNS points to Chennai
4. DB-PROD-B promoted to Primary
5. Chennai serves all traffic
6. Downtime: 1-2 min (warm) / 5-10 min (cold)
```

---

## 7. ConfigMap + Secret + Vault Strategy

### ConfigMap (non-sensitive)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prod-db-config
  namespace: prod
data:
  DB_HOST: "DB-LB-PROD-MUM"   # LB endpoint, not direct DB
  DB_PORT: "5432"
  DB_NAME: "ecommerce_prod"
  APP_ENV: "production"
```

### Secret (sensitive - basic)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: prod-db-secret
  namespace: prod
type: Opaque
stringData:
  DB_USER: "prod_user"
  DB_PASSWORD: "strongpassword"   # never in Git
```

### Deployment me reference (password direct nahi)

```yaml
env:
- name: DB_HOST
  valueFrom:
    configMapKeyRef:
      name: prod-db-config
      key: DB_HOST
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: prod-db-secret
      key: DB_PASSWORD
```

### Secret by Environment

| Env   | DB_HOST value       | Secret name      |
|-------|---------------------|------------------|
| dev   | DB-LB-DEV           | dev-db-secret    |
| stage | DB-LB-STAGE         | stage-db-secret  |
| prod  | DB-LB-PROD-MUM      | prod-db-secret   |

---

## 8. Vault (Production Secret Management)

```
HashiCorp Vault
  |
  |-- secret/dev/db     -> DB_USER, DB_PASSWORD
  |-- secret/stage/db   -> DB_USER, DB_PASSWORD
  |-- secret/prod/db    -> DB_USER, DB_PASSWORD
  |-- secret/prod/payment -> PAYMENT_API_KEY
  |-- pki/             -> TLS certificates
```

Pod annotation se inject:
```yaml
annotations:
  vault.hashicorp.com/agent-inject: "true"
  vault.hashicorp.com/role: "prod-backend"
  vault.hashicorp.com/agent-inject-secret-db: "secret/prod/db"
```

---

## 9. Storage Strategy

| Storage Type | Use Case                        | Tool           |
|--------------|---------------------------------|----------------|
| S3           | Static files, YAML backups      | AWS S3         |
| S3 CRR       | Cross-region file replication   | S3 Replication |
| EBS          | Pod local persistent storage    | EBS CSI        |
| EFS          | Shared storage across pods      | EFS CSI        |
| PVC          | K8s persistent volume claim     | StorageClass   |

### S3 Cross-Region Replication

```
Mumbai S3 Bucket (ap-south-1)
        |
        | Auto replication
        v
Chennai S3 Bucket (ap-south-2)
```

---

## 10. CI/CD Pipeline

```
Developer
   |
   v
Git Push (main/feature branch)
   |
   v
CI (GitHub Actions / Jenkins)
   |-- Build Docker image
   |-- Run tests
   |-- Push image to ECR (Elastic Container Registry)
   |
   v
CD (ArgoCD / Flux)
   |-- Watch Git repo
   |-- Detect YAML change
   |-- Apply to Mumbai EKS
   |-- Apply to Chennai EKS
```

### ArgoCD Multi-Cluster

```yaml
# ArgoCD Application
spec:
  destination:
    server: https://mumbai-eks-endpoint
    namespace: prod
  source:
    path: k8s/prod
    repoURL: https://github.com/org/app
```

---

## 11. Terraform Structure

```
terraform/
  |-- modules/
  |     |-- eks/        # Shared EKS module
  |     |-- rds/        # Shared RDS module
  |     |-- vpc/        # Shared VPC module
  |     |-- s3/         # Shared S3 module
  |
  |-- mumbai/
  |     |-- main.tf     # Mumbai infra
  |     |-- variables.tf
  |     |-- terraform.tfvars
  |
  |-- chennai/
        |-- main.tf     # Chennai infra
        |-- variables.tf
        |-- terraform.tfvars
```

### Drift Detection (CI me regularly chalao)

```bash
cd terraform/mumbai && terraform plan
cd terraform/chennai && terraform plan
```

---

## 12. Monitoring + Alerting

| Tool            | Kaam                              |
|-----------------|-----------------------------------|
| Prometheus      | Metrics collect karna             |
| Grafana         | Dashboard + visualization         |
| AlertManager    | Alerts send karna (Slack/PagerDuty)|
| CloudWatch      | AWS level logs + metrics          |
| Loki            | Log aggregation                   |
| Datadog/NewRelic| Full observability (enterprise)   |

---

## 13. Disaster Recovery Summary

| Scenario              | Action                          | Downtime     |
|-----------------------|---------------------------------|--------------|
| Pod crash             | Auto restart by Deployment      | Seconds      |
| Node down             | Pods recreate on other nodes    | 1-2 min      |
| Full cluster down     | Route53 failover to other region| 2-5 min      |
| DB Primary down       | Replica promoted to primary     | 1-2 min      |
| Full region down      | Active-Active: near 0 downtime  | Near zero    |
|                       | Active-Passive: DNS failover    | 5-10 min     |

---

## 14. Security Checklist

- Secrets kabhi Git me push nahi honge
- ConfigMap me sirf non-sensitive data
- DB direct public expose nahi hoga kabhi
- RBAC: har namespace ka alag access
- Network Policy: namespace isolation
- TLS/HTTPS: Ingress pe certificate
- Vault: prod secrets rotation
- S3 bucket: private, encryption enabled
- ECR images: vulnerability scan enabled

---

## 15. File Structure (This Project)

```
projects/
  |-- S3/
  |     |-- dev/apps.yaml       # dev-nginx + dev-busybox
  |     |-- stage/apps.yaml     # stage-nginx + stage-busybox
  |     |-- prod/apps.yaml      # prod-nginx + prod-busybox
  |     |-- yaml/               # PV, PVC, test pods
  |     |-- pv-data/            # Local host mount path
  |
  |-- testapp/
        |-- demo/
        |     |-- dev/apps.yaml
        |     |-- stage/apps.yaml
        |     |-- prod/apps.yaml
        |     |-- nginx-complete.yaml
        |-- k8s/
        |     |-- deployment.yaml
        |     |-- service.yaml
        |     |-- ingress-alb.yaml
        |-- Dockerfile
        |-- package.json
        |-- src/
```
