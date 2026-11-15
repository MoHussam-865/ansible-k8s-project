# MicroCRM — CI/CD Pipeline Documentation

> **Educational-purpose guide** covering Jenkins + ArgoCD GitOps for a
> three-microservice CRM application (API, Frontend, Notification).

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Repository Structure](#repository-structure)
3. [How GitOps Works](#how-gitops-works)
4. [Prerequisites](#prerequisites)
5. [Setup Guide](#setup-guide)
6. [The Jenkins Pipeline Explained](#the-jenkins-pipeline-explained)
7. [The ArgoCD Application Explained](#the-argocd-application-explained)
8. [Image Tagging Strategy](#image-tagging-strategy)
9. [Rollback Procedure](#rollback-procedure)
10. [Troubleshooting](#troubleshooting)
11. [Next Steps](#next-steps)

---
## Architecture Overview

```
 +----------------------+      +----------------------+
 |  Application Repo    |      |  Kubernetes Repo     |
 |  (api-service/       |      |  (deployment.yaml,   |
 |   frontend-service/  |      |   service.yaml, ...)  |
 |   notification-svc/) |      |                      |
 +----------+-----------+      +----------+-----------+
            | 1) git push                  |
            v                             |
 +----------------------+                 |
 |     Jenkins CI       |                 |
 |  - checkout source   |                 |
 |  - run tests         |                 |
 |  - build images      |                 |
 |  - push to DockerHub |                 |
 |  - clone k8s repo    |                 |
 |  - update image tags |                 |
 |  - git commit + push |-----------------+
 +----------------------+  4) git push (new tags)
                                    |
                                    v
                           +------------------+
                           |     ArgoCD       |
                           |  detects commit  |
                           |  kubectl apply   |
                           +--------+---------+
                                    | 5) sync
                                    v
                           +------------------+
                           |  Kubernetes      |
                           |  Cluster         |
                           |  [API Pods]      |
                           |  [Frontend Pods] |
                           |  [Notif. Pods]   |
                           |  [Postgres]      |
                           +------------------+
```

**Key principle:** Jenkins never talks to the cluster directly.
It only reads/writes Git repositories. ArgoCD is the sole deployer.

---
## Repository Structure

### Application Repository (this repo — where the Jenkinsfile lives)

```
.
+-- api-service/
|   +-- app/   ... (source code)
|   +-- Dockerfile
+-- frontend-service/
|   +-- app/   ... (source code)
|   +-- Dockerfile
+-- notification-service/
|   +-- app/   ... (source code)
|   +-- Dockerfile
+-- Jenkinsfile          <-- CI pipeline definition
+-- README.md
```

### Kubernetes Manifests Repository (separate repo)

```
.
+-- api/
|   +-- deployment.yaml      <-- image: mohussam/microcrm-api:<sha>
|   +-- service.yaml
+-- frontend/
|   +-- deployment.yaml      <-- image: mohussam/microcrm-frontend:<sha>
|   +-- service.yaml
+-- notification/
|   +-- deployment.yaml      <-- image: mohussam/microcrm-notification:<sha>
|   +-- service.yaml
+-- postgres/
|   +-- deployment.yaml
|   +-- service.yaml
|   +-- pvc.yaml
+-- argo-app.yaml            <-- ArgoCD Application manifest
```

---

## How GitOps Works  (Jenkins + ArgoCD)

| Step | Who | What Happens |
|------|-----|-------------|
| 1 | Developer | `git push` to the **application repo** |
| 2 | Jenkins | Polls SCM (or receives webhook), starts pipeline |
| 3 | Jenkins | Checks out source, runs tests |
| 4 | Jenkins | Builds 3 Docker images, tags with `git rev-parse --short HEAD` |
| 5 | Jenkins | Pushes images to Docker Hub |
| 6 | Jenkins | Clones the **Kubernetes manifests repo** |
| 7 | Jenkins | Replaces `image:` tags with the new SHA via `sed` |
| 8 | Jenkins | Commits + pushes the change to the k8s repo |
| 9 | ArgoCD | Polls the k8s repo every 3 min, detects new commit |
| 10 | ArgoCD | Runs `kubectl apply` and reconciles the cluster |

**Why not let Jenkins run `kubectl apply`?**

- Jenkins would need cluster credentials -> security risk.
- If the cluster is down, Jenkins fails -> tight coupling.
- Auditing: "who changed what?" is answered by `git log` on the k8s repo.

---
## Prerequisites

| Component | Version / Notes |
|-----------|----------------|
| Jenkins | 2.x with plugins: **Docker Pipeline**, **Git**, **Credentials Binding** |
| Jenkins agent | Linux agent with `docker`, `git`, `bash`, `sed`. Label it `docker`. |
| Docker Hub | Account + repositories: `microcrm-api`, `microcrm-frontend`, `microcrm-notification` |
| ArgoCD | Installed on the Kubernetes cluster |
| Kubernetes | Any cluster (minikube, kind, EKS, AKS, GKE) |
| Git | Two GitHub repositories (app + k8s manifests) |

---

## Setup Guide

### 1. Store Credentials in Jenkins

Go to **Dashboard -> Manage Jenkins -> Credentials -> System -> Global -> Add Credentials**

| Credential ID | Type | Value |
|---------------|------|-------|
| `dockerhub-credentials` | **Secret text** | Docker Hub password or access token |
| `github-credentials` | **Secret text** | GitHub [Personal Access Token](https://github.com/settings/tokens) with `repo` scope |

> Secret text ensures the token NEVER appears in console logs.

### 2. Create the Jenkins Pipeline Job

1. **New Item** -> **Pipeline** -> Name: `MicroCRM-CI`
2. **Pipeline -> Definition**: **Pipeline script from SCM**
3. **SCM**: Git -> enter the application repo URL
4. **Script Path**: `Jenkinsfile`
5. **Save**

### 3. Configure the Jenkins Agent

The agent must have the `docker` label and these tools:

```bash
# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker jenkins

# Verify tools are available
docker --version
git --version
sed --version
```

In Jenkins: **Manage Jenkins -> Nodes -> (your agent) -> Labels** -> add `docker`.

### 4. Install ArgoCD on the Cluster

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

# Get the initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d
```

### 5. Apply the ArgoCD Application

```bash
kubectl apply -f argo-app.yaml

# Access the ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open https://localhost:8080  (user: admin, pw: from step 4)
```

### 6. Trigger Your First Pipeline

Push a commit to the application repo, or click **Build Now** in Jenkins.
Watch the pipeline run, then check the ArgoCD UI - `microcrm` will appear and sync.

---
## The Jenkins Pipeline Explained

### Stage 1 — Checkout Source
- `checkout scm` pulls the application code from the configured Git repo.
- Captures `GIT_COMMIT_SHORT` (7-char SHA) — this becomes the Docker image tag.

### Stage 2 — Run Tests (parallel)
- Tests run for all 3 services simultaneously using the `parallel` block.
- If any test fails, the entire pipeline stops — no images built.
- Replace the `echo` placeholders with real test commands (e.g. `npm test`, `pytest`).

### Stage 3 — Build Docker Images (parallel)
- All 3 images are built in parallel to save time.
- Each image is tagged **twice**:
  - `<image>:<git-sha>` — **immutable deployment tag** used in k8s manifests.
  - `<image>:latest` — convenience tag for local development.

### Stage 4 — Push Images to Docker Hub
- `withCredentials` injects the Docker Hub token securely from Jenkins credential store.
- Never hard-coded — the token never appears in console logs.
- Pushes both tags (`sha` and `latest`) for each image.

### Stage 5 — Update Kubernetes Manifests
- Clones the k8s manifests repo using the GitHub token embedded in the clone URL.
- Uses `sed` to find-and-replace image tags in all YAML files:
  - Finds lines containing `image: mohussam/microcrm-api:*`
  - Replaces them with `image: mohussam/microcrm-api:<new-sha>`
- Prints `git diff` so the changes are visible in the Jenkins console log.

### Stage 6 — Commit & Push
- Configures `git user.name` / `git user.email` for the commit.
- Only creates a commit if actual changes exist (idempotent — safe to re-run).
- `[skip ci]` in the commit message prevents Jenkins from re-triggering itself.

### Post Actions
- **always**: cleans up the cloned k8s repo and logs out of Docker Hub.
- **success**: logs success message (placeholder for Slack/email).
- **failure**: logs failure message (placeholder for Slack/email).

---
## The ArgoCD Application Explained

| Field | Value | Why |
|-------|-------|-----|
| `source.repoURL` | k8s manifests repo | ArgoCD continuously watches this repo for changes |
| `source.targetRevision` | `main` | Tracks the main branch (change for `dev`/`staging`) |
| `destination.server` | `https://kubernetes.default.svc` | Deploy to the same cluster ArgoCD runs in |
| `destination.namespace` | `microcrm` | All application resources go into this namespace |
| `syncPolicy.automated.prune` | `true` | Delete resources from cluster that are removed from Git |
| `syncPolicy.automated.selfHeal` | `true` | Revert any manual kubectl edits to match Git |
| `syncOptions.CreateNamespace` | `true` | Auto-create the namespace if it does not exist |
| `syncOptions.PruneLast` | `true` | Delete old resources AFTER applying new ones (less downtime) |

---

## Image Tagging Strategy

We use the **short Git commit SHA (7 characters)** as the Docker image tag.

| Approach | Pros | Cons |
|----------|------|------|
| `:latest` | Simple | Not traceable — what code is running in production? |
| Semantic version `v1.2.3` | Human-readable | Requires manual bumping or complex tooling |
| **Git SHA** | Immutable, traceable, automatic | Not human-readable (use `git log` instead) |

Every running pod tells you exactly which commit created it:

```bash
kubectl get deploy api -o jsonpath=''{.spec.template.spec.containers[0].image}''
# -> mohussam/microcrm-api:a3f2b1c

git show a3f2b1c   # shows the exact source code that built this image
```

---

## Rollback Procedure

### Option A — Git revert (recommended, fully auditable)

```bash
cd k8s-manifests-repo
git log --oneline              # find the commit with the old/working SHA
git revert <bad-commit>        # creates a new commit restoring old tags
git push                       # ArgoCD auto-syncs the cluster back
```

### Option B — Manual kubectl (quick fix, but selfHeal will fight you)

```bash
kubectl set image deploy/api api=mohussam/microcrm-api:<old-sha>
# Note: selfHeal will revert this after ~3 minutes unless you pause sync.
```

---
## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| "docker: command not found" in Jenkins | Agent missing Docker CLI | Install Docker on agent; add `jenkins` user to `docker` group |
| "denied: requested access to the resource is denied" | Docker Hub auth failure | Verify `dockerhub-credentials` secret in Jenkins credential store |
| "Repository not found" on clone | GitHub token lacks permissions | Generate a new token with `repo` scope at github.com/settings/tokens |
| ArgoCD shows "Unknown" health status | YAML manifests are invalid | Run `kubectl apply --dry-run=client -f deployment.yaml` locally |
| ArgoCD "OutOfSync" never resolves | Image pull error from registry | `kubectl describe pod` — check for Docker Hub rate limits or image name typos |
| `sed` does not replace image tags | YAML format differs from the regex pattern | Inspect actual YAML and adjust the `grep`/`sed` regex in Stage 5 |
| Jenkins agent shows "(pending—Waiting for next available executor)" | No agent has the `docker` label | Add the `docker` label to your agent in Manage Jenkins -> Nodes |

---

## Next Steps / Improvements

1. **Slack / Email notifications** — Uncomment and configure the `post { success {} failure {} }` blocks.
2. **Multi-environment support** — Add a `choice` parameter (`dev`, `staging`, `prod`) and conditional stages.
3. **Kustomize or Helm** — Replace `sed` with `kustomize edit set image` or `helm upgrade --set` for safer tag updates.
4. **Image vulnerability scanning** — Add a Trivy or Snyk stage before pushing images to Docker Hub.
5. **GitHub Webhooks** — Replace `pollSCM` with real webhooks for instant pipeline triggers.
6. **Sealed Secrets / HashiCorp Vault** — Manage Postgres passwords and other secrets securely.
7. **Pull Request validation** — Add `when { changeRequest() }` conditions to run tests (but skip push) on PRs.
8. **ArgoCD Notifications** — Configure ArgoCD to send Slack/Teams alerts on sync success/failure.

---

## Quick Reference

```bash
# Trigger Jenkins build manually (if webhook not configured)
curl -X POST "https://jenkins.example.com/job/MicroCRM-CI/build"

# Check ArgoCD application sync status
argocd app get microcrm

# Force an immediate sync (rarely needed)
argocd app sync microcrm

# Preview what ArgoCD would change (dry-run diff)
argocd app diff microcrm

# View ArgoCD sync history
argocd app history microcrm

# Rollback via ArgoCD CLI
argocd app rollback microcrm <deployment-id>
```

---

> **Happy deploying!** This setup ensures every change is traceable,
> every deployment is auditable, and your cluster always reflects the
> desired state stored in Git.


## What you still need to do

1. __In Jenkins__: Store `dockerhub-credentials` and `github-credentials` as __Secret text__ credentials.
2. __Jenkins agent__: Ensure your agent has `docker`, `git`, `sed`, `bash` and is labeled `docker`.
3. __ArgoCD__: Install it on your cluster and `kubectl apply -f argo-app.yaml`.
4. __Replace test placeholders__ in Stage 2 with real commands (`npm test`, `pytest`, etc.).
5. __Update the k8s repo URL__ in the pipeline parameters and `argo-app.yaml` to match your actual repo.

