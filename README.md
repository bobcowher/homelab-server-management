# homelab-server-management

Ansible configuration for `lab` — a two-GPU (RTX 3090 + RTX 3060) inference and
training server running Ubuntu 26.04 LTS.

Declarative and reproducible: the machine can be rebuilt without hand-restoring
users, permissions, GPU plumbing, or services.

## Start here

| Document | What it's for |
|---|---|
| **[docs/RUNBOOK.md](docs/RUNBOOK.md)** | **Day-to-day operations.** How to run it, change it, repair it, and add models. Start here. |
| [docs/superpowers/specs/2026-09-04-lab-server-ansible-design.md](docs/superpowers/specs/2026-09-04-lab-server-ansible-design.md) | Design and the reasoning behind it — why Caddy exists, why beekeeper is not proxied, why conda is load-bearing |
| [docs/superpowers/plans/2026-09-05-lab-server-ansible.md](docs/superpowers/plans/2026-09-05-lab-server-ansible.md) | The task-by-task implementation plan this was built from |
| [requirements.md](requirements.md) | Original reference sheet — superseded by the spec where they disagree |

## Quick start

```bash
# apply everything, then verify
ansible-playbook -i inventory/hosts.yml hosts/lab/main.yml

# health check only, changes nothing
ansible-playbook -i inventory/hosts.yml hosts/lab/verify.yml
```

A healthy apply ends `changed=0`. Verification runs automatically after every
apply and asserts ~70 facts by reading the host back, because `changed=0`
proves Ansible didn't redo work — not that the machine is correct.

## Layout

```
inventory/hosts.yml           # how to reach the host (mDNS name; the LAN is DHCP)
inventory/group_vars/all.yml  # fleet invariants only: UID/GID map, LAN subnet
hosts/lab/main.yml            # this host's playbook: its roles, in order
hosts/lab/vars.yml            # host specifics: versions, tool lists, conda envs
hosts/lab/verify.yml          # end-state assertions, tagged per role
roles/                        # shared library, one responsibility each
```

Roles are shared; each host composes the ones it wants. A second machine gets
its own `hosts/<name>/` rather than conditionals inside the roles.

## Known gaps

**There are no backups.** `/data` is on a single NVMe with no redundancy. See
[Known gaps](docs/RUNBOOK.md#known-gaps) in the runbook for the full list.
