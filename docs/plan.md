# Infrastructure Upgrade Plan: Dynamic, Scalable, Multi-Master Kubernetes Cluster

> **Document purpose:** Define the architectural goals, design decisions, and phased implementation plan for upgrading this Ansible project from a static 3-node lab cluster to a dynamic, scalable, production-ready Kubernetes cluster with monitoring and high availability.

---

## Table of Contents

1. [Current State](#1-current-state)
2. [Goals](#2-goals)
3. [Target Architecture](#3-target-architecture)
4. [Design Decisions](#4-design-decisions)
5. [Phase 0 — Preparation & Documentation](#5-phase-0--preparation--documentation)
6. [Phase 1 — Inventory & Config Restructuring](#6-phase-1--inventory--config-restructuring)
7. [Phase 2 — HAProxy Role (Load Balancer)](#7-phase-2--haproxy-role-load-balancer)
8. [Phase 3 — Multi-Master Control Plane](#8-phase-3--multi-master-control-plane)
9. [Phase 4 — Node Exporter Role](#9-phase-4--node-exporter-role)
10. [Phase 5 — Prometheus-Stack Role](#10-phase-5--prometheus-stack-role)
11. [Phase 6 — Updated Playbooks & Entry Points](#11-phase-6--updated-playbooks--entry-points)
12. [Phase 7 — Verification & Testing](#12-phase-7--verification--testing)
13. [Phase 8 — Documentation & Cleanup](#13-phase-8--documentation--cleanup)
14. [File Change Summary](#14-file-change-summary)
15. [Risk & Mitigation](#15-risk--mitigation)

---

## 1. Current State

### Architecture

```
Ansible Controller
│
├── SSH ──► control-plane-01   (10.1.0.10)   ├── kubelet, kubectl, kubeadm
│                                            └── kubeadm init (single master)
│
├── SSH ──► worker-01          (10.1.0.8)    └── kubelet, containerd
│
└── SSH ──► worker-02          (10.1.0.6)    └── kubelet, containerd
```

### Limitations

| Area | Limitation |
|---|---|
| **IPs are static** | IPs hardcoded in `inventory/production/hosts.yml`, `host_vars/*.yml`, `group_vars/*.yml`, and documentation |
| **Single control-plane** | All references assume `groups['control-plane'][0]` — no HA, no scaling |
| **No load balancer** | Workers must know the exact control-plane IP; if it goes down, the cluster is headless |
| **No monitoring** | No Prometheus, Grafana, or metrics collection |
| **Duplicate inventory** | Root `hosts` INI file and `inventory/production/hosts.yml` contain the same data |
| **Hardcoded hostnames** | `control-plane-01`, `worker-01`, `worker-02` referenced directly in `hostvars` lookups |

### What Already Works Well

- Role dependency chain: `kubernetes` → `containerd` → `common`
- Join-command handoff from control-plane to workers via `hostvars` / `set_fact`
- Dynamic `ansible_facts` usage for self-describing IPs
- Handlers, templates, and Jinja2 patterns
- Idempotent tasks and check-mode awareness
---

## 2. Goals

### Goal A — Dynamic IPs from Terraform

An external Terraform project creates the infrastructure with dynamic IPs and generates the Ansible `hosts` file. The Ansible project must **accept whatever IPs it receives** — no hardcoded references anywhere.

**Requirements:**
- The `hosts` file (INI format at project root) is the single source of truth
- `ansible.cfg` points to `./hosts`
- All `hostvars` lookups use `groups['groupname'][index]` — never a literal hostname
- All documentation purged of hardcoded IPs
- No duplicate inventory sources

### Goal B — Scalability (N Masters + N Workers)

The cluster must support an arbitrary number of control-plane nodes (for HA) and worker nodes (for compute).

**Requirements:**
- `kubeadm init` targets HAProxy, not a specific master IP
- `kubeadm join --control-plane` for additional masters (with certificate key)
- `kubeadm join` for workers targets HAProxy
- All inventory-driven; no hardcoded node counts
- First control-plane node is special only for `kubeadm init`

### Goal C — New Roles: HAProxy, Prometheus+Stack, Node Exporter

| Role | Purpose | Installed On |
|---|---|---|
| **haproxy** | TCP load balancer for `:6443` — distributes API requests across all control-plane nodes | `haproxy` group |
| **prometheus-stack** | Prometheus (metrics collection) + Grafana (visualization) | `monitoring` group |
| **node-exporter** | Exposes node-level metrics (`:9100`) to Prometheus | `cluster` group (all K8s nodes) |

---

## 3. Target Architecture

```
                 ┌────────────────────────────────────────────────────────────┐
                 │                   Ansible Controller                       │
                 │                (manages everything over SSH)               │
                 └─────┬──────────┬──────────────┬──────────────┬────────────┘
                       │          │              │              │
                  ┌────▼──┐  ┌───▼───┐   ┌──────▼─────┐   ┌────▼─────┐
                  │      │  │       │   │           │   │          │
                  │HAProxy│  │Master1│   │  Master2  │   │  ...     │
                  │:6443  │  │:6443  │   │  :6443    │   │  (more)  │
                  └───┬───┘  └───┬───┘   └──────┬─────┘   └──────────┘
                      │          │              │
                      │   ┌──────▼──────────────▼─────┐
                      │   │   Kubernetes API (HA)     │
                      │   │   (TCP LB across masters) │
                      │   └───────────────────────────┘
                      │
                 ┌────▼─────┐   ┌──────▼──────┐   ┌──────▼─────┐
                 │ Worker-01│   │  Worker-02  │   │   ...      │
                 └──────────┘   └─────────────┘   └────────────┘
                      │                │                 │
                      └────────────────┴─────────────────┘
                                          │
                                   ┌──────▼───────┐
                                   │  Monitoring  │
                                   │  Prometheus  │
                                   │  + Grafana   │
                                   └──────────────┘
```

### Data Flow

| Direction | Protocol | Port | Description |
|---|---|---|---|
| Workers → HAProxy | TCP/HTTPS | 6443 | API requests load-balanced across masters |
| All K8s nodes → Prometheus | HTTP | 9100 | Node metrics (node-exporter) |
| Prometheus → Grafana | HTTP | 9090 (local) | Prometheus is Grafana's data source |
| Admin → Grafana | HTTP | 3000 (default) | Dashboards & visualization |
| Admin → HAProxy | TCP/HTTPS | 6443 | kubectl commands via LB |

### Network Groups

```
all
├── cluster                    # All Kubernetes nodes (parent group)
│   ├── control-plane          # N control-plane nodes (masters)
│   └── workers                # N worker nodes
├── haproxy                    # HAProxy load balancer node(s)
└── monitoring                 # Prometheus + Grafana server(s)
```
## 4. Design Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **Single INI hosts file as inventory** | Terraform generates one file; no duplication; ansible.cfg points directly to it |
| D2 | **group_vars/ moved to root** | With a file inventory, Ansible looks for group_vars/ at the working directory |
| D3 | **HAProxy before kubeadm init** | The first master's kubeadm init needs the HAProxy IP |
| D4 | **TCP mode for HAProxy** | Kubernetes API uses HTTPS/TCP; mode tcp avoids TLS termination complexity |
| D5 | **worker_control_plane_host -> HAProxy** | Workers reach the API through HAProxy, not a specific master |
| D6 | **Certificate key for multi-master** | kubeadm init --upload-certs generates a key; additional masters use kubeadm join --control-plane |
| D7 | **prometheus-stack is one role** | Prometheus + Grafana on the same server; atomic deployment |
| D8 | **node-exporter is a separate role** | Runs on ALL cluster nodes; applied independently |
| D9 | **First master runs kubeadm init** | Only one master bootstraps; others join with certificate key |

---

## 5. Phase 0 -- Preparation and Documentation

> **This file -- docs/plan.md -- is the deliverable of Phase 0.**

Phase 0 is complete. The following has been done:

| Task | Status |
|---|---|
| Comprehensive analysis of current state | Done |
| Architecture diagram and data flow | Done |
| Design decisions documented | Done |
| Phased implementation plan with file lists | Done |
| Risk registry | Done |

---

## 6. Phase 1 -- Inventory and Config Restructuring

### 6.1 Summary

Remove all hardcoded IPs and hostnames. Restructure ansible.cfg, hosts, and group_vars/ so the project is dynamically driven by whatever inventory Terraform generates.

### 6.2 Files to Change

| File | Action | Notes |
|---|---|---|
| ansible.cfg | **Update** inventory = ./hosts; remove hardcoded private_key_file | Points to root INI file |
| hosts | **Rewrite** -- add haproxy + monitoring groups; add control-plane-02, -03; update comments | Temporary IPs for development |
| group_vars/all.yml | **Move** from inventory/production/group_vars/ to group_vars/ | Root location for file inventory |
| group_vars/control-plane.yml | **Move** to root group_vars/ | -- |
| group_vars/workers.yml | **Move** to root group_vars/ | -- |
| group_vars/haproxy.yml | **Create new** | HAProxy-specific variables |
| group_vars/monitoring.yml | **Create new** | Prometheus/Grafana/node-exporter vars |
| group_vars/all.yml | **Update** kubernetes_api_endpoint -- replace control-plane-01 with groups[control-plane][0] | Dynamic reference |
| group_vars/workers.yml | **Update** control_plane_ip -- replace with HAProxy endpoint | Workers go through LB |
| host_vars/control-plane-01.yml | **Delete or purge** hardcoded ansible_host | IP comes from hosts file |
| host_vars/worker-01.yml | **Delete or purge** hardcoded ansible_host | Same |
| host_vars/worker-02.yml | **Delete or purge** hardcoded ansible_host | Same |
| inventory/production/ dir | **Keep as fallback** but mark deprecated | Do NOT delete yet -- rollback safety |

### 6.3 Acceptance Criteria

| Check | Method |
|---|---|
| ansible-inventory --list shows all groups | ansible-inventory --list |
| No file references control-plane-01 literally in hostvars lookups | grep -r hostvars\\[ *.yml playbooks/ |
| ansible.cfg points to ./hosts | grep inventory ansible.cfg |

---

## 7. Phase 2 -- HAProxy Role (Load Balancer)

### 7.1 Summary

Create a new haproxy role that installs HAProxy and configures it as a TCP load balancer for the Kubernetes API (:6443). The backend servers list is dynamically generated from groups[control-plane].

### 7.2 New Files

| File | Purpose |
|---|---|
| playbooks/roles/haproxy/defaults/main.yml | Default variables (port, timeouts, algorithm) |
| playbooks/roles/haproxy/handlers/main.yml | restart haproxy handler |
| playbooks/roles/haproxy/meta/main.yml | Galaxy info + dependency on common |
| playbooks/roles/haproxy/tasks/main.yml | Install, configure, enable, start |
| playbooks/roles/haproxy/templates/haproxy.cfg.j2 | Dynamic config with Jinja2 backend loop |
| playbooks/roles/haproxy/vars/main.yml | Internal vars (service name, paths) |

### 7.3 Template Logic (haproxy.cfg.j2)

The template loops over groups[control-plane] to generate backend server entries:
`
backend kubernetes-masters
    balance roundrobin
    option tcp-check
{% for host in groups['control-plane'] %}
    server {{ host }} {{ hostvars[host].ansible_facts.default_ipv4.address }}:6443 check
{% endfor %}
`

### 7.4 Variables

| Variable | Default | Description |
|---|---|---|
| haproxy_frontend_port | 6443 | Port HAProxy listens on |
| haproxy_backend_port | 6443 | Port kubelet listens on on masters |
| haproxy_mode | tcp | Layer 4 proxy (not HTTP) |
| haproxy_balance_algorithm | roundrobin | Load distribution algorithm |
| haproxy_timeout_connect | 10s | Backend connect timeout |
| haproxy_timeout_client | 1m | Client idle timeout |
| haproxy_timeout_server | 1m | Server idle timeout |

### 7.5 Integration Points

The HAProxy role depends on the common role (OS packages). It reads groups[control-plane] from the inventory to build the dynamic backend list.


## 8. Phase 3 -- Multi-Master Control Plane

### 8.1 Summary

Update the control-plane role and the kubernetes-cluster.yml playbook to support N control-plane nodes. The first master does kubeadm init with the HAProxy endpoint and uploads certificates. Additional masters join using kubeadm join --control-plane with a certificate key.

### 8.2 Files to Change

| File | Action |
|---|---|
| group_vars/control-plane.yml | Add control_plane_endpoint -> HAProxy |
| group_vars/workers.yml | Already updated in Phase 1 -- worker join endpoint -> HAProxy |
| playbooks/roles/control-plane/defaults/main.yml | Update kubeadm_apiserver_endpoint default |
| playbooks/roles/control-plane/tasks/main.yml | Add certificate key generation + set_fact for cert key |
| playbooks/roles/worker/defaults/main.yml | Update worker_control_plane_host -> HAProxy |
| playbooks/kubernetes-cluster.yml | Add new play for joining additional control-plane nodes |

### 8.3 How Multi-Master Works

1. **HAProxy must be running first** (Phase 2)
2. **First control-plane node** runs kubeadm init --control-plane-endpoint=<haproxy_ip>:6443 --upload-certs
   - Creates the cluster AND uploads the CA cert
   - Generates a certificate key (different from the join token)
3. **Additional control-plane nodes** run:
   kubeadm join <haproxy_ip>:6443 --token=<join_token> --control-plane --certificate-key=<cert_key>
   - The --control-plane flag tells kubeadm this is a master, not a worker
4. **Workers** join with: kubeadm join <haproxy_ip>:6443 --token=<join_token>
   - Same command as before, just targeting HAProxy instead of a specific master IP

### 8.4 Updated kubernetes-cluster.yml Play Order

| Play | Hosts | Role | Purpose |
|---|---|---|---|
| Play 1 | all | kubernetes | Install base stack (common -> containerd -> k8s) |
| Play 2 | control-plane (first only) | control-plane | kubeadm init + generate cert key + join command |
| Play 3 | control-plane (rest) | -- | kubeadm join --control-plane (NEW) |
| Play 4 | workers | worker | kubeadm join (through HAProxy) |
| Play 5 | control-plane (first only) | calico | Install Calico CNI |

---

## 9. Phase 4 -- Node Exporter Role

### 9.1 Summary

A lightweight role that installs prometheus-node-exporter on every cluster node. This exposes hardware and OS metrics on port 9100 for Prometheus to scrape.

### 9.2 New Files

| File | Purpose |
|---|---|
| playbooks/roles/node-exporter/defaults/main.yml | Default variables (port, service name) |
| playbooks/roles/node-exporter/handlers/main.yml | restart prometheus-node-exporter |
| playbooks/roles/node-exporter/meta/main.yml | Galaxy info + dependency on common |
| playbooks/roles/node-exporter/tasks/main.yml | Install, enable, start |
| playbooks/roles/node-exporter/vars/main.yml | Internal vars |

### 9.3 Main Tasks

1. Install prometheus-node-exporter via apt
2. Enable the systemd service
3. Start the service

### 9.4 Variables

| Variable | Default | Description |
|---|---|---|
| node_exporter_service_name | prometheus-node-exporter | Systemd unit name |
| node_exporter_service_state | started | Desired service state |
| node_exporter_service_enabled | true | Enable on boot |

### 9.5 Integration

Applied to the cluster group (all K8s nodes). Depends on common role.

---

## 10. Phase 5 -- Prometheus-Stack Role

### 10.1 Summary

A combined role that installs Prometheus (metrics storage + query engine) and Grafana (visualization dashboards). The Prometheus config dynamically targets all cluster nodes from the inventory.

### 10.2 New Files

| File | Purpose |
|---|---|
| playbooks/roles/prometheus-stack/defaults/main.yml | Scrape interval, ports, Grafana config |
| playbooks/roles/prometheus-stack/handlers/main.yml | restart prometheus, restart grafana |
| playbooks/roles/prometheus-stack/meta/main.yml | Galaxy info + dependency on common |
| playbooks/roles/prometheus-stack/tasks/main.yml | Entry point that includes sub-files |
| playbooks/roles/prometheus-stack/tasks/prometheus.yml | Prometheus install + config |
| playbooks/roles/prometheus-stack/tasks/grafana.yml | Grafana install via APT repo |
| playbooks/roles/prometheus-stack/templates/prometheus.yml.j2 | Dynamic targets from groups[cluster] |
| playbooks/roles/prometheus-stack/vars/main.yml | Service names, paths |

### 10.3 Template Logic (prometheus.yml.j2)

The Prometheus config dynamically builds targets from the inventory:
`yaml
scrape_configs:
  - job_name: 'node'
    static_configs:
      - targets:
{% for host in groups['cluster'] %}
        - {{ hostvars[host].ansible_facts.default_ipv4.address }}:9100
{% endfor %}
`

### 10.4 Variables

| Variable | Default | Description |
|---|---|---|
| prometheus_scrape_interval | 15s | How often Prometheus scrapes targets |
| prometheus_local_port | 9090 | Prometheus own metrics port |
| prometheus_service_name | prometheus | Systemd unit name |
| grafana_service_name | grafana-server | Systemd unit name |
| grafana_apt_key_url | https://apt.grafana.com/gpg.key | Grafana GPG key URL |
| grafana_apt_repo_url | https://apt.grafana.com | Grafana APT repo base URL |


## 11. Phase 6 -- Updated Playbooks and Entry Points

### 11.1 Summary

Update the master playbook and create the new playbook files. The new execution order ensures HAProxy -> Kubernetes -> Monitoring.

### 11.2 Files to Create/Update

| File | Action | Purpose |
|---|---|---|
| playbooks/haproxy.yml | **Create** | Install HAProxy (Phase 2 deliverable) |
| playbooks/monitoring.yml | **Create** | Install Prometheus + Grafana + Node Exporter |
| playbooks/site.yml | **Update** | Add new playbooks to the execution chain |
| playbooks/kubernetes-cluster.yml | **Update** | Add Play 3 for additional masters, update endpoints |
| playbooks/bootstrap.yml | **Review** | No changes needed (targets all, works for new groups) |
| playbooks/verify.yml | **Update** | Add checks for HAProxy, Prometheus, Grafana, Node Exporter |

### 11.3 Full Execution Flow

`
site.yml
+-- bootstrap.yml          | all nodes: OS prep (packages, sysctl, chrony)
+-- haproxy.yml            | haproxy: install and configure HAProxy
+-- kubernetes-cluster.yml |
|   +-- Play 1: all        |   Install base stack (common -> containerd -> k8s)
|   +-- Play 2: first cp   |   kubeadm init (with HAProxy endpoint) + upload certs
|   +-- Play 3: rest cp    |   kubeadm join --control-plane (NEW)
|   +-- Play 4: workers    |   kubeadm join (through HAProxy)
|   +-- Play 5: first cp   |   Calico CNI
+-- monitoring.yml         |
|   +-- monitoring host    |   Prometheus + Grafana
|   +-- cluster nodes      |   node-exporter
+-- verify.yml             | all: check services; cp: kubectl get nodes
`

---

## 12. Phase 7 -- Verification and Testing

### 12.1 Summary

Update the verify role to check the new services and create a comprehensive smoke-test playbook.

### 12.2 Files to Change

| File | Action |
|---|---|
| playbooks/roles/verify/defaults/main.yml | Add HAProxy, Prometheus, Grafana, Node Exporter services |
| playbooks/roles/verify/tasks/main.yml | Add new service checks |
| playbooks/verify.yml | Add new plays for monitoring-specific verification |

### 12.3 New Verify Defaults

`yaml
verify_services:
  - name: containerd
    host_group: all
  - name: kubelet
    host_group: all
  - name: haproxy
    host_group: haproxy
  - name: prometheus-node-exporter
    host_group: cluster
  - name: prometheus
    host_group: monitoring
  - name: grafana-server
    host_group: monitoring
`

---

## 13. Phase 8 -- Documentation and Cleanup

### 13.1 Summary

Update all documentation to reflect the new architecture and remove dead references.

### 13.2 Files to Update

| File | Action |
|---|---|
| README.md | Update architecture diagram, host table, usage instructions |
| how-everything-works.md | Add new roles to the file reference table |
| group_vars/all.yml (root) | Add comments about the new variables |
| inventory/production/ | Mark as deprecated; do NOT delete yet |
| .gitignore | Add any new patterns if needed |

### 13.3 Files to Delete/Deprecate

| File | Reason |
|---|---|
| inventory/production/group_vars/all.yml | Moved to root group_vars/all.yml |
| inventory/production/group_vars/control-plane.yml | Moved to root |
| inventory/production/group_vars/workers.yml | Moved to root |
| inventory/production/host_vars/control-plane-01.yml | IP now comes from hosts only |
| inventory/production/host_vars/worker-01.yml | Same |
| inventory/production/host_vars/worker-02.yml | Same |
| inventory/staging/ | Keep as reference for multi-env pattern |

> **Warning:** Do NOT delete inventory/production/hosts.yml until the new hosts file is verified working. Keep both during transition.


---

## 14. File Change Summary

### New Files (23)

`
playbooks/roles/haproxy/defaults/main.yml
playbooks/roles/haproxy/handlers/main.yml
playbooks/roles/haproxy/meta/main.yml
playbooks/roles/haproxy/tasks/main.yml
playbooks/roles/haproxy/templates/haproxy.cfg.j2
playbooks/roles/haproxy/vars/main.yml
playbooks/roles/node-exporter/defaults/main.yml
playbooks/roles/node-exporter/handlers/main.yml
playbooks/roles/node-exporter/meta/main.yml
playbooks/roles/node-exporter/tasks/main.yml
playbooks/roles/node-exporter/vars/main.yml
playbooks/roles/prometheus-stack/defaults/main.yml
playbooks/roles/prometheus-stack/handlers/main.yml
playbooks/roles/prometheus-stack/meta/main.yml
playbooks/roles/prometheus-stack/tasks/main.yml
playbooks/roles/prometheus-stack/tasks/prometheus.yml
playbooks/roles/prometheus-stack/tasks/grafana.yml
playbooks/roles/prometheus-stack/templates/prometheus.yml.j2
playbooks/roles/prometheus-stack/vars/main.yml
playbooks/haproxy.yml
playbooks/monitoring.yml
group_vars/haproxy.yml
group_vars/monitoring.yml
`

### Modified Files (14)

`
ansible.cfg
hosts
group_vars/all.yml
group_vars/control-plane.yml
group_vars/workers.yml
playbooks/roles/control-plane/defaults/main.yml
playbooks/roles/control-plane/tasks/main.yml
playbooks/roles/worker/defaults/main.yml
playbooks/kubernetes-cluster.yml
playbooks/site.yml
playbooks/verify.yml
playbooks/roles/verify/defaults/main.yml
playbooks/roles/verify/tasks/main.yml
README.md
`

### Total: ~37 new/changed files across 8 phases

---

## 15. Risk and Mitigation

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **R1:** ansible.cfg inventory change breaks existing workflows | Medium | High | Keep inventory/production/ intact during transition; test with both paths |
| **R2:** Multi-master kubeadm join fails | Medium | High | The join pattern is identical to worker join (proven). Only the --control-plane flag differs. Test with 2 masters first. |
| **R3:** hostvars cross-group reference fails because facts not gathered | Low | Medium | Ensure gather_facts: true on ALL plays; use ansible.builtin.setup: as fallback in pre_tasks |
| **R4:** HAProxy becomes single point of failure | Medium | Medium | Document that HAProxy HA (keepalived) is next iteration. Single HAProxy is acceptable for dev/demo. |
| **R5:** Prometheus config references hosts that are down | Low | Low | Prometheus handles missing targets gracefully (logs warning, continues scraping) |
| **R6:** host_vars/ files conflict with hosts file | Low | Medium | After migration, ensure no host_vars/ files remain with ansible_host defined |
| **R7:** Grafana APT repo changes URL | Low | Low | Use variable for the URL; update in one place if it changes |

### Rollback Plan

If any phase fails, the rollback sequence is:

1. **Phase 6 (playbooks):** Revert playbooks/site.yml to previous version; run only known-good playbooks
2. **Phase 3 (multi-master):** Keep first master only; remove additional masters from inventory
3. **Phase 2 (HAProxy):** Point workers directly to first master's IP again; disable HAProxy
4. **Phase 1 (inventory):** Revert ansible.cfg to inventory = inventory/production/

Each phase is self-contained and can be rolled back independently.

---

> **End of Plan Document**
>
> *This file is the authoritative reference for the k8s-ansible project upgrade.
> When implementing, follow the phases in order. Each phase builds on the previous one.
> Do NOT skip phases -- the dependencies are linear.*

