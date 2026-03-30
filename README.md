# Claude Code Docker

A self-contained, security-hardened Docker Compose setup for
[Claude Code](https://github.com/anthropics/claude-code),
developed for manual Docker management, based on **Node.js 24 LTS**.

---

## Files

```
.
├── Dockerfile           # Node 24-slim + Claude Code + firewall tooling
├── docker-compose.yml   # Compose service definition
├── init-firewall.sh     # iptables/ipset egress firewall (default-deny)
├── init-ssh.sh          # init SSH KEY for claude code github access
├── .env.example         # Copy to .env and fill in secrets
├── LICENSE
└── README.md
```

---

## Quick Start

```bash
# 1. Copy env file and set your API key
cp .env.example .env
$EDITOR .env          # set ANTHROPIC_API_KEY and PROJECT_DIR

# 2. Build and start
docker compose up --build -d

# 3. Open a shell inside the container
docker compose exec claude-code zsh

# 4. Inside the container: start Claude Code
cd /workspace
claude
```

## Installed services

The Claude Code docker container installs:

- `yarn` and `pnpm`,
- `zsh` with Powerline10k theme

*HINT:* Do not use `npm`, it is outdated.

---

## Security Model

The `init-firewall.sh` script runs at container startup and configures a
**default-deny egress firewall** using `iptables` + `ipset`:

| Layer | Mechanism |
|---|---|
| Privilege control | Non-root `node` user; `sudo` only for the firewall script |
| Network isolation | `iptables` with default `DROP` on INPUT/OUTPUT/FORWARD |
| Allowlist | `ipset` hash table of permitted destination IPs |

**Allowed outbound destinations:**
- `api.anthropic.com` and related Anthropic infra
- GitHub (dynamic IP ranges from `api.github.com/meta` + direct names)
- npm registry (`registry.npmjs.org`)
- Ubuntu apt repos (for in-container package installs)

Everything else is **rejected** (ICMP unreachable, for fast feedback).

The container requires two Linux capabilities for this to work:
```yaml
cap_add:
  - NET_ADMIN   # iptables rules, ipset, DROP policies
  - NET_RAW     # ICMP rejection packets
```

---

## Architecture: One Container vs. Per-Project

This is the most common question for Claude Code with Docker. Here is the
honest answer:

### Option A — One shared Claude Code container (recommended for most people)

```
~/projects/
  ├── project-a/
  ├── project-b/
  └── project-c/

docker-compose.yml
  └── claude-code container
        └── /workspace → ~/projects/  (entire dir mounted)
```

You switch projects by `cd`-ing inside the container.

**Pros:**
- Single image to build/update
- Shared Claude config volume (auth, memory, settings)
- Low overhead — one container for everything

**Cons:**
- All projects share the same Node version / toolchain
- You need all project runtimes (Node, Python, Rust…) installed in one image

**When to use:** Most solo dev workflows, or when your projects share a
similar tech stack.

---

### Option B — Per-project container (Docker Compose inside each project)

```
project-a/
  ├── docker-compose.yml   ← has both claude-code AND nodejs services
  ├── docker
  └── src/

project-b/
  ├── docker-compose.yml   ← has claude-code AND python services
  ├── docker
  └── src/
```

**Pros:**
- Full isolation: each project pins its own Node/Python/Rust version
- Compose network lets Claude Code reach `localhost:3000` of the app service
- Great for teams: contributors get a reproducible environment

**Cons:**
- Multiple containers running if you work on several projects simultaneously
- Each project needs its own Claude config volume (or share via `.env`)
- More maintenance

**When to use:** Projects with conflicting toolchain requirements, or team
projects where you want reproducible environments.

---

### The important question you asked: can Claude Code and the app run in separate containers?

**Short answer: no, not easily.**

Claude Code works by executing shell commands *directly in the container it
runs in*. When you ask it to "run the tests" or "start the dev server", it
runs `npm test` / `cargo build` / `python manage.py` **inside its own
container**. It cannot exec into a sibling container.

So the rule is: **Claude Code must live in the same container as the
runtime it needs to orchestrate.**

The right mental model is:

```
WRONG ✗
  claude-code container  ──(can't exec)──►  nodejs container
                                            └── npm run dev

CORRECT ✓  (Option A or B)
  claude-code + nodejs in ONE container
  ├── claude (the AI CLI)
  ├── node / npm
  ├── your app source code
  └── optional: separate postgres/redis containers (fine — Claude just
      runs `psql` or connects via the Docker network)
```

Databases and other *pure service* containers are fine as siblings — Claude
Code can connect to them over the Docker Compose network (e.g.
`postgres://postgres:5432`). But the language runtime Claude Code needs to
*run commands in* must be co-located.

---

### Recommended layout for a multi-runtime solo developer

```
~/docker/
  claude-code/
    Dockerfile          ← installs Node 24 + Python 3 + Rust + Go + ...
    docker-compose.yml
    init-firewall.sh
    .env

~/projects/
  web-app/             mounted into /workspace/web-app
  rust-backend/        mounted into /workspace/rust-backend
  python-scripts/      mounted into /workspace/python-scripts
```

In `docker-compose.yml`, mount your whole projects root:
```yaml
volumes:
  - ~/projects:/workspace:cached
```

Then install all runtimes you need in the single `Dockerfile`. The image
gets a bit larger but you only manage one container.

---

## Useful Commands

```bash
# Start (detached)
docker compose up -d

# Open a shell
docker compose exec claude-code zsh

# Stop
docker compose down

# Rebuild after Dockerfile changes
docker compose up --build -d

# Remove everything including volumes (loses Claude auth/config!)
docker compose down -v
```

---

## Updating Claude Code

Simply rebuild the container, the official Claude Code *installation script* will install the latest version.

## License

MIT License

Copyright (c) 2026 Michael Schaefer <https://github.com/mischa-robots/claude-code-docker>
