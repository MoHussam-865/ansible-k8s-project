# How Everything Works in This Ansible Project

> A beginner-to-intermediate tour of Ansible, taught using this very repository.
> If a term confuses you, check the **Glossary** at the end.
> This file reads best top-to-bottom, then revisited while you explore the code.

## Table of Contents

1. What is Ansible?
2. The players in this project
3. The big picture: what a playbook run does
4. Layer 1 — Configuration: `ansible.cfg`
5. Layer 2 — Inventory: who the machines are
6. Layer 3 — Variables: `group_vars`, `host_vars`, and precedence
7. Layer 4 — Playbooks: the entry points
8. Layer 5 — Roles: reusable units of automation
9. The toolbox: modules, handlers, templates, register, hostvars and friends
10. End-to-end walkthrough: one full `site.yml` run
11. File-by-file reference
12. Glossary
13. How to build your own project from scratch

---

## 1. What is Ansible?

Ansible is a **configuration-management and automation tool**. You write plain-text YAML files describing the *state you want* on your servers, and Ansible makes it happen — over plain SSH, with nothing special installed on the machines.

### The core mental model: "declarative, not procedural"

- **Imperative (run commands):** *"run apt install nginx, then copy this file, then restart the service."*
- **Declarative (Ansible):** *"nginx must be installed, this file must contain this content, the service must be running."*

Ansible compares what you want to what already exists and only does what is missing. That is what makes it safe to run again and again.

### Agentless

Ansible does **not** install a daemon or agent on managed servers. It opens an SSH connection, runs small Python programs (called **modules**) that perform the work, then disconnects.

### Push model

Your machine (the **control node**) *pushes* configuration to the servers. The servers never call home — you always initiate.

### Everything is YAML

Playbooks, inventories, and variables are all YAML files. YAML is just a data format (lists and dictionaries). No compiler, no new programming language — just text files.

### Idempotency — the most important word in Ansible

An operation is **idempotent** if doing it 1 time or 100 times leaves the system in the same state. Ansible reports each task per host as:

- **`ok`** — the target state already existed; nothing to do.
- **`changed`** — Ansible had to do something to reach the target state.
- **`failed`** — something went wrong.

A good playbook shows mostly `ok` on the second run. This repository is built to be idempotent, so its playbooks can be re-run freely.

---

## 2. The players in this project

This repo provisions a small Kubernetes cluster from Ubuntu VMs. The machines involved:

| Host | Role in Ansible | Role in Kubernetes |
|------|-----------------|--------------------|
| your computer (or one VM) | **Ansible controller** | none — only sends SSH commands |
| `control-plane-01` | managed node | control plane (runs the K8s API) |
| `worker-01` | managed node | worker (runs your containers) |
| `worker-02` | managed node | worker (runs your containers) |

```
        ┌──────────────────────────────┐
        │   Ansible Controller         │
        │   (runs ansible-playbook)    │
        └──────┬──────────┬────────────┘
               │ SSH      │ SSH
        ┌──────▼──┐  ┌────▼─────┐  ┌───▼─────┐
        │control- │  │ worker-  │  │ worker- │
        │plane-01 │  │ 01       │  │ 02      │
        └─────────┘  └──────────┘  └─────────┘
```

The controller is **never** part of the Kubernetes cluster. It only manages the nodes over SSH.

---

## 3. The big picture: what happens when you run a playbook

Everything in this repo exists to serve one moment:

```bash
ansible-playbook playbooks/site.yml
```

Under the hood, Ansible does the following (each step is covered in detail later):

1. Reads `ansible.cfg` — learns where the inventory lives and which SSH user to use.
2. Parses the inventory — learns the **hosts**, their **IPs**, and their **groups**.
3. Loads variables from `group_vars/` and `host_vars/`.
4. Reads the playbook and **imports** the other playbooks in order.
5. For every **play**: gathers **facts**, runs **tasks** (or **roles**), then runs notified **handlers** at the end.
6. Prints one line per task per host: `ok` / `changed` / `failed`.

The next five sections explain the five "layers" of files that make this work:
`ansible.cfg` → inventory → variables → playbooks → roles.
## 4. Layer 1 — Configuration: `ansible.cfg`

Ansible looks for `ansible.cfg` in the current directory before anywhere else, which makes it the perfect place to pin project-wide behaviour. This project's file sets:

| Setting | Value | Meaning |
|---|---|---|
| `inventory` | `inventory/production/` | The directory Ansible reads to discover hosts |
| `remote_user` | `ansible` | The SSH user Ansible logs in as on each node |
| `host_key_checking` | `False` | Skips SSH "confirm this host?" prompts (home-lab convenience) |
| `gather_facts` | `True` | Collects system info from each host before tasks run |
| `forks` | `5` | How many hosts Ansible talks to in parallel |
| `timeout` | `30` | SSH connection timeout in seconds |
| `pipelining` | `True` | Reuses one SSH connection for several commands (a 2–3x speedup) |
| `interpreter_python` | `auto_silent` | Finds the right Python on the target automatically |

The `[ssh_connection]` section (`ControlMaster=auto`, `ControlPersist=60s`) also reuses one SSH connection across the whole run. Most of `ansible.cfg` is actually *comments explaining every option* — read it once at your leisure; it is a mini-course by itself.

## 5. Layer 2 — Inventory: who the machines are

Open `inventory/production/hosts.yml`. Simplified, it says:

```yaml
all:
  children:
    cluster:
      children:
        control-plane:
          hosts:
            control-plane-01: { ansible_host: 192.168.1.10 }
        workers:
          hosts:
            worker-01: { ansible_host: 192.168.1.11 }
            worker-02: { ansible_host: 192.168.1.12 }
```

### What each word means

- **Hosts** — the logical names (`control-plane-01`, `worker-01`, `worker-02`). They are the "keys" of your inventory.
- **`ansible_host`** — the actual **IP** Ansible connects to for that host.
- **Groups** — named sets of hosts (`control-plane`, `workers`).
- **Parent group** — `cluster` contains the two groups, so "the whole cluster" is one word.
- **`all`** — a magic built-in group that always contains every host.

### Why groups matter so much

Groups let a playbook say WHO it wants **in one word**:

```yaml
hosts: all            # → all 3 nodes
hosts: control-plane  # → control-plane-01 only
hosts: workers        # → worker-01 + worker-02
```

No playbook in this repo ever writes an IP directly — it always references a group. That is the entire superpower of the inventory.

### The staging inventory

`inventory/staging/` is the same structure with placeholder IPs (`10.0.0.x`) — a ready-made "second environment". Use it with:

```bash
ansible-playbook -i inventory/staging/ playbooks/site.yml
```

…or by changing the `inventory = inventory/production/` line in `ansible.cfg` to `inventory/staging/`.

## 6. Layer 3 — Variables: making everything reusable

Hardcoding ("install version 1.28.3 on this one machine") makes playbooks useless. Variables let one playbook serve many machines.

### Where variables live in this project

| Location | Scope | Example from this repo |
|---|---|---|
| `group_vars/all.yml` | every host in the env | `pod_network_cidr`, `common_packages`, `kubernetes_release` |
| `group_vars/control-plane.yml` | control-plane hosts only | `kubernetes_role`, `kubernetes_api_port` |
| `group_vars/workers.yml` | worker hosts only | `kubernetes_role: worker` |
| `host_vars/<host>.yml` | one specific host | `kubelet_node_type` |
| role `defaults/` | fallback for one role | `common_run_apt_update: true` |
| role `vars/` | internal constants | binary paths like `/usr/bin/kubelet` |

### How a task consumes a variable

The `common` role installs packages with **one task written once**:

```yaml
- name: Install baseline packages
  ansible.builtin.apt:
    name: "{{ item }}"
    state: present
  loop: "{{ common_packages }}"
```

The list `common_packages` lives in `group_vars/all.yml` — *not* inside the role. To change the package list, you edit the variable file, never the role. That is the whole point of the separation.

### Variable precedence — the ladder that decides the winner

When the same variable name appears in several places, Ansible resolves it with a strict order (highest wins):

```
1. extra vars            ansible-playbook -e foo=bar
2. set_fact / register   (values created at runtime)
3. play vars / include_vars
4. host_vars/<host>.yml
5. group_vars/<group>.yml          (control-plane, workers)
6. group_vars/all.yml
7. role vars/main.yml
8. role defaults/main.yml
```

**Memory trick: specific beats general; runtime beats files; files beat role defaults.**

Practical effects in this repo:

- `kubelet_service_name: kubelet` is a role **default** — overridable from anywhere.
- `pod_network_cidr: 10.0.0.0/16` is in `group_vars/all.yml` — the same for all hosts.
- If you wanted only `worker-01` to behave differently, `host_vars/worker-01.yml` would win over both.
## 7. Layer 4 — Playbooks: the entry points

A **playbook** is a list of **plays**. A **play** says: *"on these hosts, as this user, do these roles/tasks."*

### `playbooks/site.yml` — the master switch

```yaml
- name: Stage 5 — Bootstrap OS on all nodes
  ansible.builtin.import_playbook: bootstrap.yml

- name: Stages 5-10 — Provision Kubernetes cluster
  ansible.builtin.import_playbook: kubernetes-cluster.yml

- name: Stage 11 — Verify cluster health
  ansible.builtin.import_playbook: verify.yml
```

`import_playbook` pastes another playbook into this one, in order. `site.yml` exists so the whole cluster can be built with a single command.

### Anatomy of a play — from `playbooks/bootstrap.yml`

```yaml
- name: Bootstrap all nodes — OS preparation
  hosts: all
  gather_facts: true
  become: true

  pre_tasks:                       # run BEFORE roles (validation, checks)
    - name: Ensure we are running on Ubuntu
      ansible.builtin.fail: ...
      when: ansible_distribution != "Ubuntu"

  roles:                           # the actual work
    - role: common

  post_tasks:                      # run AFTER roles (summary, reporting)
    - name: Display bootstrap completion message
      ansible.builtin.debug: ...
```

The three keywords at the top are the heart of every play:

- `hosts` — **who** this play targets (a group, or `all`).
- `become: true` — run as **root** (via sudo).
- `gather_facts` — collect facts first (OS, IP, kernel…) so tasks can adapt.

`pre_tasks` / `post_tasks` are optional hooks that run before/after the play's roles.

### `playbooks/kubernetes-cluster.yml` — the 4-play pipeline

The most important file in the repo. Its four plays:

| Play | hosts | role | job |
|---|---|---|---|
| 1 | all | `kubernetes` | add the K8s repo, install kubeadm/kubelet/kubectl (also chains containerd + common via dependencies) |
| 2 | control-plane | `control-plane` | run `kubeadm init`, capture the join command |
| 3 | workers | `worker` | wait for the API port, then `kubeadm join` |
| 4 | all | `calico` | install CNI pod networking |

**Order is the logic.** You cannot join a cluster that does not exist, so `init` (play 2) strictly precedes `join` (play 3). Play 3 even blocks on `wait_for` until the control-plane API port (6443) answers.

### `playbooks/verify.yml` — prove it works

Runs the `verify` role on every node (are containerd and kubelet healthy?) and then a summary play on the control plane (`kubectl get nodes`). Safe to re-run at any time as a smoke test.

## 8. Layer 5 — Roles: reusable units of automation

A **role** is a self-contained folder that packages everything for one job. It is why "OS prep" can be reused in a different project just by copying one folder.

### The standard skeleton (auto-loaded)

```
roles/common/
├── defaults/            # lowest-precedence variables
├── handlers/            # restart tasks, run at play end when notified
├── meta/                # metadata + dependencies
├── tasks/               # THE actual work (runs top to bottom)
├── templates/           # .j2 files rendered at deploy time (some roles)
└── vars/                # internal constants (higher precedence)
```

`tasks/main.yml`, `defaults/main.yml`, etc. are *magic names*: when a role is included, Ansible auto-loads `tasks/main.yml`; the other folders are loaded when their content is needed.

### The dependency trick (`meta/main.yml`)

`control-plane/meta/main.yml` contains:

```yaml
dependencies:
  - role: kubernetes
```

`kubernetes` depends on `containerd`, which depends on `common`. So `role: control-plane` automatically runs:

```
common → containerd → kubernetes → control-plane
```

Nobody must remember the order in the playbook — **the roles enforce their own prerequisites.** This is a professional-grade pattern, and one of the best things to copy from this repo.

### The 7 roles

| Role | One-liner |
|---|---|
| `common` | apt update, baseline packages, disable swap, kernel modules, sysctl, reboot |
| `containerd` | install + configure the container runtime |
| `kubernetes` | add the K8s apt repo/GPG key; install kubeadm, kubelet, kubectl |
| `control-plane` | `kubeadm init`; save the join command; kubelet config |
| `worker` | wait for the API; `kubeadm join`; kubelet config |
| `calico` | apply the Calico manifest via `kubectl apply -f` |
| `verify` | health checks (services + `kubectl get nodes`) |
## 9. The toolbox: Ansible features used all over this project

### Modules

Modules are the built-in "verbs" of Ansible: `apt`, `service`, `file`, `copy`, `template`, `sysctl`, `stat`, `command`, `shell`, `debug`, `get_url`, `unarchive`, `blockinfile`, `dpkg_selections`… A **task** is exactly one module call with parameters. Modules are designed to be idempotent (they check state before changing it).

### `become` (sudo)

`become: true` means "run this as root". This project needs it almost everywhere: installing packages, writing files in `/etc`, managing systemd services.

### Conditionals: `when`

```yaml
when: ansible_distribution != "Ubuntu"
```

The task is skipped unless the condition is true. This is how one project safely supports different operating systems.

### Loops: `loop`

```yaml
loop: "{{ common_packages }}"
```

Runs the task once per item. Inside the task, `{{ item }}` is the current value.

### Facts

Automatically discovered information about each host: `ansible_facts['default_ipv4'].address`, `ansible_facts['distribution']`, `ansible_facts['hostname']`. Facts make tasks adaptive — the playbook always uses the node's *real* IP instead of a hardcoded one.

### Handlers

```yaml
- name: restart containerd
  ansible.builtin.service:
    name: containerd
    state: restarted
```

A task that changes something says `notify: restart containerd`. The handler runs **once, at the end of the play, only if some task reported `changed`**. No change → no restart. This is how Ansible avoids needless service restarts.

### Templates (Jinja2)

Template files end in `.j2` and contain `{{ placeholder }}` spots:

```
root: "{{ containerd_root }}"
```

Ansible renders them on the target with the correct variable values, then writes the result to the destination. One template can therefore produce different configs on different hosts.

### `register` → `set_fact` → `hostvars` (the cluster trick)

This is THE pattern that makes a multi-node cluster buildable in one run:

```yaml
# Play 2, on the control plane:
- name: Initialize the cluster with kubeadm
  ansible.builtin.command:
    cmd: "kubeadm init ..."
  register: kubeadm_init_result          # capture the program output

- name: Extract the join command
  ansible.builtin.set_fact:
    kubeadm_join_command_raw: "{{ ... }}"   # share it with everyone
  run_once: true
```

1. The control plane runs `kubeadm init` and captures its output with `register`.
2. `set_fact` saves just the `kubeadm join --token=...` line as a variable.
3. The command is **also written to a file** (`/var/lib/kubeadm/join-command.txt`), because in-memory variables disappear when the playbook process ends.
4. Worker nodes read it with `hostvars['control-plane-01']['kubeadm_join_command_raw']` — "the variable that lives on that other host".

### `delegate_to` / `run_once`

- **`delegate_to`** — run a task on a *different* host than the play's target. A worker checking the control-plane's API port uses `delegate_to: "{{ groups['control-plane'][0] }}"`.
- **`run_once: true`** — run a task only once even when the play has many hosts. `kubeadm init` must run on exactly one node.

### Tags

Every task is tagged (`common`, `kubernetes`, `worker`, `calico`, `verify`, …). With `--tags worker`, you can run only the worker-related tasks of a playbook.

### Idempotency patterns used here

- `state: present` rather than blind installs.
- `notify` + handlers instead of always restarting services.
- `stat` a marker file (e.g., the CA certificate) to skip `kubeadm init` on re-runs.
- `changed_when: false` for read-only checks.
- `block` + `rescue` + `always` (in the `verify` role) to report health instead of crashing.
## 10. End-to-end walkthrough: what `ansible-playbook playbooks/site.yml` does

Follow one complete run, node by node.

**Step 0 — startup.** Ansible reads `ansible.cfg`, parses `inventory/production/`, and loads `group_vars` / `host_vars`. It now knows: 3 hosts, 2 groups, and every shared variable.

**Step 1 — `bootstrap.yml` is imported.**
Play "Bootstrap all nodes" targets `all`, becomes root:

- `pre_tasks`: fail fast if the host is not Ubuntu.
- role `common`:
  1. `apt update` (cached within the configured timeout).
  2. install every package in `common_packages` (`curl`, `wget`, `gnupg`, `apt-transport-https`, …).
  3. disable swap (`swapoff -a` + edit `/etc/fstab`) — Kubernetes requires it.
  4. write kernel modules (`overlay`, `br_netfilter`, the `ip_vs` family…) to `/etc/modules-load.d/k8s.conf` and load them.
  5. apply sysctl settings from `k8s_sysctl_settings` (IP forwarding, bridge traffic, `vm.overcommit_memory`, `vm.swappiness`…).
  6. check `/var/run/reboot-required`; if present and allowed, reboot and wait for the host to return.
- `post_tasks`: print a completion message.

**Step 2 — `kubernetes-cluster.yml` is imported.**

*Play 1 "Install base stack" (hosts: all).* Role `kubernetes` runs — and because of `meta/main.yml`, its dependency chain (`containerd` → `common`) runs first. The role downloads the K8s GPG key, adds the apt repo, installs `kubeadm`, `kubelet`, `kubectl`, holds their versions, writes `/etc/default/kubelet`, starts kubelet (it may crash-loop harmlessly until a cluster exists — expected), and verifies `kubectl version`.

*Play 2 "Initialize control plane" (hosts: control-plane).* Role `control-plane`:

- ensures `/etc/kubernetes` exists;
- skips if the cluster already initialized (it `stat`s existing certificates);
- runs `kubeadm init` with options built from variables (`--pod-network-cidr`, `--control-plane-endpoint=<real-ip>:6443`, cert validity);
- `register`s the output, `set_fact`s the `kubeadm join …` command, and writes it to `/var/lib/kubeadm/join-command.txt`;
- deploys `kubelet-config.yaml.j2`, restarts kubelet, prints the join command.

*Play 3 "Join workers" (hosts: workers).* Role `worker`:

- `wait_for` the control-plane API port (a delegated task) until it answers;
- pulls the join command from `hostvars['control-plane-01']…`;
- skips if the node already joined (`/etc/kubernetes/pki/ca.crt` exists);
- runs `kubeadm join --token=… <cp-ip>:6443`;
- deploys `kubelet-worker-config.yaml.j2`, starts kubelet.

*Play 4 "Install Calico CNI" (hosts: control-plane).* Role `calico`:

- runs `kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml` on the control plane (once, using the `admin.conf` kubeconfig);
- the Calico DaemonSet then deploys CNI plugin binaries and configuration onto **every** node automatically;
- no manual directory creation, tarball extraction, or containerd config changes are needed — the manifest handles everything.

> **Why the change?** Older Calico releases shipped standalone CNI binary `.tar.gz` files that were downloaded per-node. Starting with Calico v3.26+, those tarballs are no longer published. The `kubectl apply` manifest approach is the modern, supported method.

**Step 3 — `verify.yml` is imported.** The `verify` role checks the `containerd` and `kubelet` services on all nodes (block/rescue/always), then delegated `kubectl` tasks on the control plane print `kubectl get nodes` and per-node readiness. A final play prints the summary and next commands.

When every task reports `ok` (or a small, expected set of `changed`), your cluster is up.

## 11. File-by-file reference

### Root files

| File | Why it exists | When it is loaded |
|---|---|---|
| `ansible.cfg` | pins inventory, SSH user, speed/connection options | every `ansible` / `ansible-playbook` run |
| `.gitignore` | keeps `.retry` files, caches, editor junk out of git | every `git` operation |
| `.ansible-lint` | style/rules config for the `ansible-lint` tool | when you run `ansible-lint` |
| `README.md` | project documentation and quickstart | by humans |
| `how-everything-works.md` | this course | by humans |
| `prompt.md` | the original AI prompt that generated the repo (useful "requirements" document) | by humans |
| `requirements.yml` | placeholder for Ansible Galaxy role dependencies | `ansible-galaxy install -r requirements.yml` |

### inventory/

| File | Role |
|---|---|
| `inventory/production/hosts.yml` | the phone book: 3 hosts, groups `control-plane` + `workers` under `cluster` |
| `inventory/production/group_vars/all.yml` | variables for every host |
| `inventory/production/group_vars/control-plane.yml` | variables for the control-plane group |
| `inventory/production/group_vars/workers.yml` | variables for the workers group |
| `inventory/production/host_vars/*.yml` | per-host overrides (optional) |
| `inventory/staging/*` | ready-made second environment (same groups, placeholder IPs) |

### playbooks/

| File | Purpose |
|---|---|
| `site.yml` | master playbook: imports bootstrap → kubernetes-cluster → verify |
| `bootstrap.yml` | OS prep (common role) on all nodes |
| `kubernetes-cluster.yml` | 4 plays: k8s install, kubeadm init, join workers, CNI |
| `verify.yml` | cluster health smoke test |

### roles/ (each folder contains the auto-loaded `main.yml`)

| Role | Key files besides tasks |
|---|---|
| `common` | defaults (tunables), vars (paths), handlers (reboot) |
| `containerd` | defaults, vars, handlers (restart), templates/containerd_config.yml.j2 |
| `kubernetes` | defaults, vars, handlers (restart kubelet) |
| `control-plane` | defaults, vars, handlers, templates/kubelet-config.yaml.j2 |
| `worker` | defaults, vars, handlers, templates/kubelet-worker-config.yaml.j2 |
| `calico` | defaults only |
| `verify` | defaults only (plus meta) |
## 12. Glossary

- **Control node** — the machine running `ansible-playbook`.
- **Managed node** — a server Ansible configures over SSH.
- **Playbook** — a YAML file containing one or more plays.
- **Play** — "on these hosts, do these roles/tasks".
- **Task** — one module call (the smallest unit of work).
- **Module** — a built-in "verb" (`apt`, `service`, …).
- **Role** — a packaged, reusable unit (tasks/vars/handlers/templates).
- **Handler** — a task that only runs at play end when notified.
- **Template** — a `.j2` file rendered with variables.
- **Inventory** — the list of hosts/groups to manage.
- **Group** — a named set of hosts.
- **Variable** — a named value; its precedence depends on where it's defined.
- **Fact** — a variable Ansible auto-gathers about a host.
- **become** — run a task as another user (usually root).
- **register** — store a task's result in a variable.
- **set_fact** — create a variable at runtime.
- **hostvars** — the dict of every host's variables (cross-host access).
- **delegate_to** — run a task on another host.
- **run_once** — run a task only once across a play.
- **Tag** — a label for running only subsets of tasks (`--tags worker`).
- **Idempotency** — safe to run repeatedly; same end state every time.
- **Check mode** — `--check`: a dry run that reports what WOULD change.
- **Ansible Galaxy** — the community repository of roles and collections.
- **Ansible Vault** — encryption for secrets kept in the repo.

## 13. How to build your own project from scratch

The roadmap this repo followed (also reflected in `prompt.md`):

1. `mkdir myproject && cd myproject`
2. Create `ansible.cfg` with an `inventory` line and `remote_user`.
3. Create `inventory/production/hosts.yml` with hosts and groups; test with `ansible all -m ping`.
4. Split variables into `inventory/production/group_vars/`.
5. Write a first tiny playbook that does *one* thing (e.g., install `curl`) and run it.
6. Turn it into a role: `roles/common/{tasks,defaults,vars,handlers,meta}`.
7. Repeat for each concern (`containerd`, `kubernetes`, …) — one role each.
8. Wire the ordering into `meta/main.yml` dependencies instead of playbook order.
9. Use `register` / `set_fact` / `hostvars` for data that must cross hosts (the join command!).
10. Add a `verify` role and a `site.yml` master playbook.
11. Only then add extra environments, Vault secrets, `requirements.yml`, a linter, and CI tests.

**Rule of thumb:** if you can explain what a file does by tracing it (a play imports it, a task references it, a role depends on it), keep it. If nothing references it, it is decoration.
