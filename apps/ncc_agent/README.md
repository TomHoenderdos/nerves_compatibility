# ncc_agent

The remote builder agent. It runs on a builder host next to Docker, holds an
mTLS identity issued by the portal's builder CA, claims build jobs from the
portal's `/builder/v1` API, runs the `ncc-worker` image for them and uploads
the results. It ships as the `ncc_agent` release (with its own ERTS) from the
umbrella root.

On first boot it fetches the portal CA, checks its sha256 against the prefix
in the enrolment token, and trades the token and a CSR for a client
certificate. The identity lives in the data dir (`ca.pem`, `client.pem`,
`client-key.pem` at 0600, `client.csr`) and is renewed when it is within 30
days of expiry.

## Configuration

Read from the environment (in production, `/etc/ncc-agent.env`):

| Key | Default | Meaning |
| --- | --- | --- |
| `NCC_PORTAL_URL` | required | The portal's builder endpoint, `https://host:8443` |
| `NCC_ENROLMENT_TOKEN` | none | One-time token from `/admin` → Builders; needed only until enrolled |
| `NCC_SLOTS` | `1` | Concurrent builds, 1..16 |
| `NCC_CPUS`, `NCC_MEMORY` | none | Per-container `docker run --cpus` / `--memory` |
| `NCC_BUILD_CONCURRENCY` | none | Passed to the worker as its build concurrency |
| `NCC_DATA_DIR` | `/srv/ncc` | Identity, scratch, Nerves/Hex caches, releases |
| `NCC_BUILD_USER` | required non-root | `docker run --user`, the `uid:gid` of the `ncc-build` user; the agent runs as root and refuses `0:*` |
| `NCC_DOCKER_BIN` | `docker` | Docker CLI to run |
| `NCC_EGRESS_SCRIPT` | `priv/egress.sh` | Installs the containers' egress ruleset |

A missing or invalid `NCC_PORTAL_URL`, `NCC_SLOTS` or `NCC_BUILD_USER` stops
the release at boot.

## Running in dev against a local portal

From the umbrella root, with the portal's builder endpoint up and a token
created in `/admin`:

```bash
NCC_PORTAL_URL=https://localhost:8443 \
NCC_ENROLMENT_TOKEN=<token> \
NCC_DATA_DIR=$PWD/tmp/agent \
iex -S mix run --no-start -e 'Application.ensure_all_started(:ncc_agent)'
```

then `NccAgent.Identity.ensure()` enrols. Tests (`mix test apps/ncc_agent/test/`,
from the root) run against a fake portal and do not read the environment.

See `docs/REMOTE_BUILDERS.md` for the design and operations.
