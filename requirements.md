lab — Users, Software, Ports

Reference sheet. Ubuntu 24.04 LTS, single host.

Users
User	UID	Groups	Shell	Runs
robertcowher	1000	ml, docker, sudo	/bin/bash	Interactive, tmux, Claude Code, coding agents
beekeeper	2001	ml	/usr/sbin/nologin	Beekeeper orchestrator, training jobs
llm	2002	ml, docker	/usr/sbin/nologin	llama-swap, Open WebUI
files	2003	—	/usr/sbin/nologin	File Browser
Groups
Group	GID	Members	Purpose
ml	3000	robertcowher, beekeeper, llm	Shared read on /data/models, /data/datasets
docker	default	robertcowher, llm	Container control. Root-equivalent.

UIDs and GIDs are fixed, not dynamically allocated — /data ownership must survive a rebuild.

Software
apt — Ubuntu repos

build-essential · git · curl · tmux · htop · jq · unzip · ca-certificates · nvme-cli · smartmontools · restic · unattended-upgrades

apt — third-party repos
Package	Repo
nvidia-driver-<pinned>	Ubuntu
docker-ce, docker-ce-cli, containerd.io, docker-compose-plugin	download.docker.com
nvidia-container-toolkit	nvidia.github.io
tailscale	pkgs.tailscale.com
Binary
Software	Source	Notes
llama-swap	GitHub release, pinned version	/usr/local/bin/, native binary under systemd
Container images
Image	Lifecycle
vllm/vllm-openai	On-demand, spawned by llama-swap
llama.cpp server	On-demand, spawned by llama-swap
Open WebUI	Always-on, compose
File Browser	Always-on, compose
Caddy	Always-on, compose
node_exporter	Always-on, compose
DCGM exporter	Always-on, compose
Not installed

CUDA toolkit (containers carry their own) · Ollama (replaced) · Docker Desktop · docker.io from Ubuntu repos · Grafana · Prometheus

Ports
Port	Service	Bind	Reached by
22	SSH	LAN + tailscale0	robertcowher
80	Caddy	LAN + tailscale0	Browsers
3000	Open WebUI	LAN + tailscale0	Household, via Caddy
8080	llama-swap (API + /ui)	LAN + tailscale0	Open WebUI, Qwen Code, Pi, Pool
8081	File Browser	LAN + tailscale0	Browsers, via Caddy
9100	node_exporter	127.0.0.1	Local scrape
9400	DCGM exporter	127.0.0.1	Local scrape
TBD	Beekeeper	LAN + tailscale0	robertcowher
ephemeral	vLLM / llama.cpp backends	127.0.0.1	llama-swap only

No service binds 0.0.0.0. Nothing is exposed to the internet; remote access is via Tailscale only.

Systemd units
Unit	User	Restart
llama-swap.service	llm	always
beekeeper.service	beekeeper	on-failure
docker-compose@webstack.service	root	always
restic-local.timer	root	daily
restic-remote.timer	root	daily
disk-check.timer	root	hourly
