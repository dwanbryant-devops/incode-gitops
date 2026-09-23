# incode-gitops

The desired state of everything running **inside** the EKS cluster: add-ons and the RealWorld app. Argo CD syncs it continuously. Nobody runs `kubectl apply` or `helm install` by hand.

AWS resources (VPC, EKS, RDS, IAM) live in [incode-platform](https://github.com/dwanbryant-devops/incode-platform). The app source lives in the two app repos.

## How the bootstrap works

```
terraform (incode-platform, layer 40-platform)
  ├─ helm install argo-cd
  ├─ Secret argocd/in-cluster        <- "GitOps bridge": AWS facts as annotations
  │     (role ARNs, VPC ID/CIDR, DB endpoint, secret ARNs, log groups, ...)
  └─ Application "root"  ──► this repo, path bootstrap/ (recursive)
                               ├─ projects.yaml          AppProjects: platform, realworld
                               ├─ addons/*.yaml          one ApplicationSet per add-on
                               └─ workloads/realworld.yaml
```

Every ApplicationSet uses the **cluster generator**. It creates one Application per registered cluster and templates values from that cluster secret's annotations, for example `{{ .metadata.annotations.aws_lb_controller_role_arn }}`. So:

- **No account IDs, ARNs or endpoints are hardcoded in Git.** Terraform owns those values, and Git owns intent.
- **Adding an environment means registering one more cluster secret** (label `environment: prod`) and adding a `values/prod/` folder. The ApplicationSets pick it up automatically.

## Layout

| Path | What it holds |
|---|---|
| `bootstrap/projects.yaml` | `platform` project: add-ons, may touch anything.<br>`realworld` project: limited to its own namespace and this repo; no RBAC or quota objects. |
| `bootstrap/addons/` | AWS Load Balancer Controller, Cluster Autoscaler, External Secrets, platform-config, Fluent Bit, kube-prometheus-stack. Chart versions are pinned here. |
| `bootstrap/workloads/realworld.yaml` | The app. Its namespace is created with Pod Security `restricted` enforced. |
| `values/addons/` | Shared add-on Helm values. |
| `values/<env>/realworld.yaml` | Per-environment app values. **Image tags live here; CI bumps them.** |
| `charts/platform-config` | Default `gp3` StorageClass, encrypted and tagged `Backup=incode-daily` so the DLM snapshot policy covers every PV. The `ClusterSecretStore`, limited to the `realworld` namespace. Stable Grafana admin credentials. |
| `charts/realworld` | UI and API: Deployments, HPAs, PDBs, zone spreading, ExternalSecrets, the ALB Ingress, default-deny NetworkPolicies, ServiceMonitor, alerts, Grafana dashboard. |

## Deploy flow

1. Merge to `main` in an app repo.
2. CI tests the change, builds and scans the image, and pushes `incode/<app>:<git-sha>` to ECR.
3. CI commits the new tag to `values/dev/realworld.yaml` in this repo.
4. Argo CD syncs and does a rolling update. A PDB keeps one pod up, `maxUnavailable: 0` keeps full capacity during the rollout, readiness probes gate traffic, and the API shuts down gracefully on SIGTERM.

**Rollback:** `git revert` the tag-bump commit. Argo CD rolls back to the previous image, which still exists because ECR tags are immutable.

## Secrets

Git never holds a secret. External Secrets materialises them in the `realworld` namespace:

| Kubernetes Secret | Source |
|---|---|
| `api-database` | RDS-managed master secret in Secrets Manager, templated into `DATABASE_URL` with `sslmode=require` |
| `api-cache` | Valkey auth token secret (created by Terraform), templated into a `rediss://` URL |
| `api-jwt` | Generated once in the cluster by an ESO `Password` generator (`refreshPolicy: CreatedOnce`) |

The External Secrets controller's IAM role (IRSA) can read only those specific Secrets Manager ARNs.

## Operating it

```sh
aws eks update-kubeconfig --name incode-dev --region us-east-1 --profile incode-admin

# Argo CD UI (not exposed publicly)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:80   # http://localhost:8080  (admin)

# Grafana: http://<alb-dns>/grafana  (user admin)
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d

# App URL
kubectl -n realworld get ingress realworld -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```
