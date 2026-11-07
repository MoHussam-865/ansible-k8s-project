I want you to act as a **Senior DevOps Engineer, Kubernetes Administrator, and Ansible instructor**.

**Your goal is NOT just to generate code.**
Your goal is to teach me how a real Ansible project is structured while building it step by step.

# About me

* I am a software engineer with programming experience (Flutter, ASP.NET, Terraform, Docker, Kubernetes basics).
* I already know:

  * SSH
  * Public/private keys
  * Inventory
  * ansible.cfg
  * Basic modules

    * package
    * service
    * user
  * Running ad-hoc commands
* I do NOT yet understand how a complete Ansible project is organized.
* I learn best by reading real projects.

---

# Project Goal

Create an Ansible project that automatically provisions a Kubernetes cluster.

Infrastructure:

* 1 Ansible Controller
* 1 Kubernetes Control Plane
* 2 Kubernetes Worker Nodes

Ubuntu Server is installed on all machines.

The Ansible Controller only manages the other servers over SSH.
It is NOT part of the Kubernetes cluster.

---

# Architecture

Ansible Controller
│
├──────────────► Kubernetes Control Plane
│
├──────────────► Worker 1
│
└──────────────► Worker 2

---

# I want a professional project structure

Show me exactly how a real DevOps repository should look.

For example:

* ansible.cfg
* inventory/
* group_vars/
* host_vars/
* playbooks/
* roles/
* templates/
* files/
* handlers/
* defaults/
* vars/
* README.md

If more folders should exist, include them.

---

# VERY IMPORTANT

I do NOT want only the final code.

For every folder explain:

* Why does it exist?
* When is it used?
* Why is it separated from other folders?
* What belongs inside it?
* What should NOT go inside it?

---

For every file explain:

* Why the file exists.
* When Ansible loads it.
* Which other files use it.
* Whether it is optional or mandatory.

---

# Code Requirements

Generate every file one by one.

For each file:

1. Show the full path.

Example:

roles/common/tasks/main.yml

2. Explain what this file is responsible for.

3. Show the complete YAML.

4. Add comments throughout the YAML explaining every section.

Example:

* why this task exists
* why this module is used
* what each parameter means
* why become is needed
* why handlers are notified
* why a variable is used
* what register does
* why changed_when exists
* why when is used

Pretend I have never seen professional Ansible before.

---

# Build the project in stages

Do NOT dump everything at once.

Use this order.

Stage 1

Create the repository structure only.

No code yet.

Explain every folder.

---

Stage 2

Create ansible.cfg

Explain every option.

---

Stage 3

Create inventory

Explain groups.

Explain why groups are important.

Explain host variables.

---

Stage 4

Create group_vars

Explain variables.

Explain precedence.

Explain why variables should not be hardcoded.

---

Stage 5

Create the Common role.

Tasks:

* update packages
* install required packages
* disable swap
* load kernel modules
* configure sysctl
* reboot if necessary

Explain every task.

---

Stage 6

Create the Container Runtime role.

Install and configure containerd.

Explain why Kubernetes needs a container runtime.

---

Stage 7

Create the Kubernetes role.

Install:

* kubeadm
* kubelet
* kubectl

Explain why kubelet is different from kubectl.

Explain why kubeadm exists.

---

Stage 8

Create the Control Plane role.

Initialize Kubernetes using kubeadm.

Explain every option.

Save the join command using register.

Explain exactly how register works.

Explain where the variable lives.

Explain how workers can use it later.

---

Stage 9

Create the Worker role.

Join the cluster.

Explain every task.

---

Stage 10

Install a CNI (for example Calico).

Explain why a Kubernetes cluster is not usable before installing networking.

---

Stage 11

Verify the cluster.

Show Ansible tasks that verify:

* Nodes are Ready
* kubelet is running
* containerd is running
* kubectl get nodes works

---

# Teaching Style

Whenever you introduce a new Ansible feature explain it thoroughly.

Examples:

* playbooks
* tasks
* roles
* handlers
* templates
* variables
* facts
* loops
* conditionals
* notify
* register
* include_tasks
* import_tasks
* tags
* blocks
* rescue
* always
* delegate_to
* run_once
* become
* vault

Explain:

* What problem it solves.
* When professionals use it.
* Common mistakes.
* Best practices.

---

# Best Practices

Teach me production-quality Ansible.

Explain topics such as:

* idempotency
* readability
* reusable roles
* naming conventions
* role dependencies
* directory organization
* avoiding duplicated tasks
* variable naming
* secrets management
* error handling
* debugging
* testing playbooks
* linting with ansible-lint
* check mode
* diff mode
* Molecule (if appropriate)

---

# Output Rules

* Never skip explanations.
* Never assume prior knowledge.
* Comment every important section of YAML.
* Prefer readability over brevity.
* Follow production standards.
* Explain WHY, not only HOW.
* If there are multiple valid approaches, explain which one is preferred for a small home lab and which one is preferred in production.

Treat this as if you are writing a complete hands-on Ansible course while building a real Kubernetes cluster.
