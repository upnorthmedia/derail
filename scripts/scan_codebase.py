#!/usr/bin/env python3
"""scan_codebase.py - static inventory of an app repo for a Railway/Vercel -> AWS migration.

Usage:
  python3 scan_codebase.py <repo-path> [--out migration/inventory/codebase.json]
                                       [--md migration/inventory/CODEBASE.md] [--json-only]
                                       [--vercel-node 24 | --vercel-node migration/inventory/vercel/SUMMARY.md]

Stdlib only (Python 3.9+). Read-only on the repo. Never prints env var VALUES: only names,
file counts and classifications. `.env*` files are read for variable NAMES only.

Detects: package manager, node version, framework, Next.js specifics (standalone output present or
missing, edge runtime routes, middleware/proxy, ISR/revalidate, next/image, cacheHandler), Payload CMS
adapters, auth libs, ORMs, DB drivers, queue/worker libraries vs in-process schedulers, third-party
webhook SDKs/routes, Vercel-specific imports, env var references classified secret / public build-time
/ config, platform markers, hard-coded platform hostnames, ports (Dockerfile EXPOSE/CMD, Procfile,
start commands, code literals), health endpoints, cron definitions, start/build commands, tests,
Docker metadata, database TLS verification disabled, Twilio validateRequest(req.url), local
filesystem writes (Railway volume -> S3/EFS decision). Emits JSON and a Markdown report with a
"Migration flags" section.
"""
import argparse
import json
import os
import re
import sys
from collections import defaultdict
from typing import Dict, List, Optional, Set, Tuple

SKIP_DIRS = {
    "node_modules", ".git", ".next", "dist", "build", "out", ".turbo", ".vercel", ".venv", "venv",
    "__pycache__", "coverage", ".cache", "vendor", "target", ".svelte-kit", ".nuxt", ".output",
    ".pnpm-store", ".yarn", ".idea", ".vscode", "tmp", ".tox", ".mypy_cache", ".pytest_cache",
    ".terraform", "migration",
}
CODE_EXT = {
    ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".mts", ".cts", ".vue", ".svelte", ".astro",
    ".py", ".go", ".rs", ".rb", ".php", ".java", ".kt", ".cs", ".ex", ".exs",
}
CONFIG_EXT = {".json", ".toml", ".yaml", ".yml", ".prisma", ".sql", ".sh", ".env", ".html", ".txt", ".cfg", ".ini"}
SPECIAL_NAMES = {"Dockerfile", "Procfile", "Makefile"}
MAX_FILE_BYTES = 2 * 1024 * 1024

# ---------------------------------------------------------------- regexes
ENV_PATTERNS = [
    re.compile(r"process\.env\.([A-Za-z_][A-Za-z0-9_]*)"),
    re.compile(r"\benv\(\s*\"([A-Za-z_][A-Za-z0-9_]*)\"\s*\)"),  # Prisma schema.prisma: url = env("DATABASE_URL")
    re.compile(r"process\.env\[\s*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]\s*\]"),
    re.compile(r"import\.meta\.env\.([A-Za-z_][A-Za-z0-9_]*)"),
    re.compile(r"Deno\.env\.get\(\s*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]"),
    re.compile(r"Bun\.env\.([A-Za-z_][A-Za-z0-9_]*)"),
    re.compile(r"os\.environ\[\s*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]\s*\]"),
    re.compile(r"os\.environ\.get\(\s*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]"),
    re.compile(r"os\.getenv\(\s*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]"),
    re.compile(r"environ\.get\(\s*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]"),
    re.compile(r"os\.Getenv\(\s*\"([A-Za-z_][A-Za-z0-9_]*)\""),
    re.compile(r"os\.LookupEnv\(\s*\"([A-Za-z_][A-Za-z0-9_]*)\""),
    re.compile(r"std::env::var\(\s*\"([A-Za-z_][A-Za-z0-9_]*)\""),
    re.compile(r"env::var\(\s*\"([A-Za-z_][A-Za-z0-9_]*)\""),
    re.compile(r"ENV(?:\.fetch)?[\[(]\s*['\"]([A-Za-z_][A-Za-z0-9_]*)['\"]"),
    re.compile(r"System\.getenv\(\s*\"([A-Za-z_][A-Za-z0-9_]*)\""),
]
# pydantic BaseSettings / env() helpers: field names are ambiguous, skipped on purpose.

HOSTNAME_PATTERNS = {
    "up.railway.app": re.compile(r"[A-Za-z0-9.-]*up\.railway\.app"),
    "railway.internal": re.compile(r"[A-Za-z0-9.-]*\.railway\.internal"),
    "proxy.rlwy.net": re.compile(r"[A-Za-z0-9.-]*\.proxy\.rlwy\.net"),
    "storageapi.dev": re.compile(r"[A-Za-z0-9.-]*storageapi\.dev"),
    "vercel.app": re.compile(r"[A-Za-z0-9.-]*\.vercel\.app"),
    "blob.vercel-storage.com": re.compile(r"[A-Za-z0-9.-]*blob\.vercel-storage\.com"),
    "vercel-dns.com": re.compile(r"[A-Za-z0-9.-]*vercel-dns\.com"),
    "neon.tech": re.compile(r"[A-Za-z0-9.-]*\.neon\.tech"),
    "upstash.io": re.compile(r"[A-Za-z0-9.-]*\.upstash\.io"),
    "supabase.co": re.compile(r"[A-Za-z0-9.-]*\.supabase\.co"),
}

PORT_PATTERNS = [
    re.compile(r"process\.env\.PORT\s*(?:\|\||\?\?)\s*['\"]?(\d{2,5})"),
    re.compile(r"PORT\s*(?:\|\||\?\?|or)\s*['\"]?(\d{2,5})"),
    re.compile(r"\.listen\(\s*(\d{2,5})"),
    re.compile(r"os\.environ\.get\(\s*['\"]PORT['\"]\s*,\s*['\"]?(\d{2,5})"),
    re.compile(r"os\.getenv\(\s*['\"]PORT['\"]\s*,\s*['\"]?(\d{2,5})"),
    re.compile(r"--port[= ]+['\"]?(\d{2,5})"),
    re.compile(r"-p\s+['\"]?(\d{2,5})\b"),
    re.compile(r"\bport\s*[:=]\s*(\d{2,5})\b", re.IGNORECASE),
    re.compile(r"EXPOSE\s+(\d{2,5})"),
]
# Ports inside a start command (Dockerfile CMD/ENTRYPOINT in shell or exec form, Procfile, railway
# startCommand, package.json start): `--port 8000`, `--port=8000`, `"--port", "8000"`, `-p 8000`,
# `--bind 0.0.0.0:8000`, `:::8000`, `-b :8080`, `PORT=8000 node ...`
COMMAND_PORT_PATTERNS = [
    re.compile(r"--port(?:[= ]+|\"\s*,\s*\")['\"]?(\d{2,5})\b"),
    re.compile(r"(?:^|[\s\"'\[,])-p(?:\s+|\"\s*,\s*\")['\"]?(\d{2,5})\b"),
    re.compile(r"(?:--bind|--host|-b|--listen|--address|--addr)(?:[= ]+|\"\s*,\s*\")['\"]?[\w.\-\[\]:]*?:(\d{2,5})\b"),
    re.compile(r"(?:^|\s)PORT=(\d{2,5})\b"),
    re.compile(r"\bEXPOSE\s+(\d{2,5})"),
]
PORT_ENV_IN_COMMAND_RE = re.compile(r"\$\{?PORT\b|%PORT%|process\.env\.PORT")

# (a) database TLS verification disabled. RDS enforces TLS (rds.force_ssl) but these settings skip
# certificate checks (MITM-able) or turn TLS off; tighten to verify-full + RDS CA bundle.
DB_TLS_OFF_PATTERNS = [
    ("rejectUnauthorized: false", re.compile(r"rejectUnauthorized\s*:\s*false")),
    ("sslmode=no-verify", re.compile(r"sslmode=no-verify", re.IGNORECASE)),
    ("sslmode=disable", re.compile(r"sslmode=disable", re.IGNORECASE)),
    ("ssl=false", re.compile(r"\bssl\s*[:=]\s*false\b")),
    ("PGSSLMODE=disable", re.compile(r"PGSSLMODE\s*[:=]\s*['\"]?disable")),
    ("sslmode=allow/prefer", re.compile(r"sslmode=(?:allow|prefer)\b", re.IGNORECASE)),
]
# (b) Twilio signature validation built from the incoming request URL. Behind CloudFront/ALB the
# task sees http://<alb-or-task-host>/..., not the public https URL Twilio signed.
TWILIO_VALIDATE_RE = re.compile(r"validateRequest\s*\(([^;]{0,400}?)\)\s*[;\n]", re.DOTALL)
TWILIO_REQ_URL_RE = re.compile(r"\b(?:req|request)\.(?:url|nextUrl|originalUrl)\b")
# (c) local filesystem writes (Railway volume / ephemeral disk -> S3 or EFS decision)
FS_WRITE_PATTERNS = [
    ("UPLOAD_DIR", re.compile(r"\b(?:UPLOAD|UPLOADS|DATA|STORAGE|MEDIA|FILES)_(?:DIR|PATH|ROOT)\b")),
    ("/data", re.compile(r"['\"]/data(?:/[^'\"]*)?['\"]")),
    ("/mnt", re.compile(r"['\"]/mnt(?:/[^'\"]*)?['\"]")),
    ("fs.writeFile", re.compile(r"\bfs(?:Promises|\.promises)?\.(?:writeFile|writeFileSync|appendFile|appendFileSync|copyFile|copyFileSync|rename|renameSync)\s*\(")),
    ("fs.createWriteStream", re.compile(r"\bfs\.createWriteStream\s*\(")),
    ("writeFile (fs/promises import)", re.compile(r"(?<![.\w])writeFile(?:Sync)?\s*\(")),
    ("open(..., 'w')", re.compile(r"\bopen\s*\([^)]*,\s*['\"][wa]b?\+?['\"]")),
    ("shutil.copyfileobj", re.compile(r"\bshutil\.(?:copyfileobj|copyfile|copy2?|move)\s*\(")),
    ("aiofiles.open", re.compile(r"\baiofiles\.open\s*\(")),
    ("Path(...).write_", re.compile(r"\.write_(?:text|bytes)\s*\(")),
    ("multer diskStorage", re.compile(r"\bdiskStorage\s*\(")),
    ("UploadFile.save / file.save", re.compile(r"\b(?:file|upload|f)\.save\s*\(\s*(?:os\.path\.join|['\"/])")),
]
FS_WRITE_IGNORE_LINE_RE = re.compile(r"/tmp\b|tmpdir|mkdtemp|os\.tmpdir|TMPDIR|\.cache|\.next|node_modules|__pycache__|migration/")
FS_WRITE_IGNORE_FILE_RE = re.compile(r"(^|/)(scripts?|tools?|bin|migrations?|seeds?|codegen|generators?|\.github|\.storybook)(/|$)|\.config\.[cm]?[jt]s$|(^|/)(next|vite|tailwind|postcss|drizzle|prisma|payload)\.config\.")
HEALTH_PATH_RE = re.compile(r"['\"](/(?:api/)?(?:health|healthz|_health|ready|readyz|live|livez|ping|status))['\"]")
HEALTH_FILE_RE = re.compile(r"(^|/)(app|pages)(/\(.*?\))?/(api/)?(health|healthz|_health|ready|readyz|livez)(/route)?\.(ts|js|tsx|jsx|mjs)$")

EDGE_RUNTIME_RE = re.compile(r"export\s+const\s+runtime\s*=\s*['\"]edge['\"]")
NODE_RUNTIME_RE = re.compile(r"export\s+const\s+runtime\s*=\s*['\"]nodejs['\"]")
REVALIDATE_TAG_RE = re.compile(r"\brevalidateTag\s*\(")
REVALIDATE_PATH_RE = re.compile(r"\brevalidatePath\s*\(")
ISR_RE = re.compile(r"export\s+const\s+revalidate\s*=\s*(\d+|false)")
DYNAMIC_RE = re.compile(r"export\s+const\s+dynamic\s*=\s*['\"]([a-z-]+)['\"]")
PREFERRED_REGION_RE = re.compile(r"export\s+const\s+preferredRegion\b")
NEXT_IMAGE_RE = re.compile(r"from\s+['\"]next/image['\"]")
USE_CACHE_RE = re.compile(r"['\"]use cache(?::\s*\w+)?['\"]")
UNSTABLE_CACHE_RE = re.compile(r"\bunstable_cache\b")
WAIT_UNTIL_RE = re.compile(r"\bwaitUntil\b")
AFTER_RE = re.compile(r"\bafter\s*\(")
VERCEL_HEADER_RE = re.compile(r"x-vercel-[a-z-]+", re.IGNORECASE)
IMPORT_RE = re.compile(r"(?:from\s+|require\(\s*|import\(\s*)['\"](@?[A-Za-z0-9._/-]+)['\"]")
PY_IMPORT_RE = re.compile(r"^\s*(?:from\s+([A-Za-z0-9_.]+)\s+import|import\s+([A-Za-z0-9_.]+))", re.MULTILINE)
PGBOUNCER_RE = re.compile(r"pgbouncer=true|\bpgbouncer\b|DATABASE_UNPOOLED_URL|directUrl\s*=|-pooler\.", re.IGNORECASE)
WEBHOOK_HINT_RE = re.compile(
    r"webhooks\.constructEvent|constructEventAsync|validateRequest\(|svix|Webhook\(|typeform|x-hub-signature|stripe-signature|x-twilio-signature|resend-signature|svix-signature", re.IGNORECASE)

VERCEL_PACKAGES = [
    "@vercel/blob", "@vercel/kv", "@vercel/postgres", "@vercel/edge-config", "@vercel/functions",
    "@vercel/analytics", "@vercel/speed-insights", "@vercel/og", "@vercel/flags", "@vercel/toolbar",
]
FRAMEWORK_DEPS = [
    ("next", "nextjs"), ("nuxt", "nuxt"), ("@remix-run/node", "remix"), ("@remix-run/react", "remix"),
    ("@react-router/node", "react-router-framework"), ("astro", "astro"), ("@sveltejs/kit", "sveltekit"),
    ("@nestjs/core", "nestjs"), ("fastify", "fastify"), ("express", "express"), ("hono", "hono"),
    ("koa", "koa"), ("@hapi/hapi", "hapi"), ("gatsby", "gatsby"), ("@angular/core", "angular"),
    ("vite", "vite"), ("react", "react"),
]
PY_FRAMEWORKS = [("django", "django"), ("fastapi", "fastapi"), ("flask", "flask"), ("starlette", "starlette"),
                 ("litestar", "litestar"), ("sanic", "sanic"), ("tornado", "tornado"), ("aiohttp", "aiohttp")]
PY_WORKERS = ["celery", "rq", "dramatiq", "arq", "huey"]
PY_SERVERS = ["uvicorn", "gunicorn", "hypercorn", "daphne", "waitress"]
AUTH_LIBS = ["better-auth", "next-auth", "@auth/core", "@auth/nextjs", "@clerk/nextjs", "@clerk/clerk-sdk-node",
             "lucia", "@lucia-auth/adapter-prisma", "@supabase/ssr", "@supabase/auth-helpers-nextjs", "passport",
             "@kinde-oss/kinde-auth-nextjs", "@workos-inc/node", "jose", "jsonwebtoken",
             "django-allauth", "authlib", "python-jose", "pyjwt", "fastapi-users", "flask-login"]
ORM_LIBS = ["prisma", "@prisma/client", "drizzle-orm", "drizzle-kit", "kysely", "typeorm", "sequelize", "mongoose",
            "knex", "mikro-orm", "@mikro-orm/core", "objection", "sqlalchemy", "sqlmodel", "tortoise-orm", "peewee",
            "alembic", "django", "activerecord", "gorm", "sqlx", "diesel", "sea-orm", "payload"]
DB_DRIVERS = ["pg", "postgres", "pg-promise", "@neondatabase/serverless", "@vercel/postgres", "@electric-sql/pglite",
              "mysql2", "mysql", "mongodb", "better-sqlite3", "sqlite3", "libsql", "@libsql/client",
              "psycopg", "psycopg2", "psycopg2-binary", "asyncpg", "pymongo", "motor", "pymysql", "mysqlclient",
              "pgx", "lib/pq", "tokio-postgres", "sqlx"]
QUEUE_CACHE = ["ioredis", "redis", "bullmq", "bull", "bee-queue", "@upstash/redis", "@upstash/qstash", "amqplib",
               "kafkajs", "@aws-sdk/client-sqs", "sqs-consumer", "pg-boss", "graphile-worker", "inngest", "trigger.dev",
               "@trigger.dev/sdk", "celery", "rq", "dramatiq", "arq", "redis-py", "kombu", "pika", "aiokafka", "memcached"]
WEBHOOK_SDKS = ["stripe", "twilio", "resend", "@typeform/api-client", "svix", "@sendgrid/mail", "postmark",
                "@slack/webhook", "@octokit/webhooks", "shopify-api-node", "@shopify/shopify-api", "paddle-sdk",
                "@paddle/paddle-node-sdk", "lemonsqueezy", "@lemonsqueezy/lemonsqueezy.js", "plaid", "mailgun.js"]
# In-process schedulers: the job fires inside every replica (N tasks -> N runs). Move to EventBridge
# Scheduler or add a distributed lock.
CRON_LIBS = ["node-cron", "croner", "cron", "@nestjs/schedule", "bree", "node-schedule", "toad-scheduler",
             "apscheduler", "django-celery-beat", "schedule", "rocketry"]
# Queue/worker libraries: a broker (Redis/Postgres/SQS) hands each job to ONE worker, so they scale
# horizontally; they become a separate ECS worker service, not a scheduler problem.
QUEUE_WORKER_LIBS = ["celery", "rq", "dramatiq", "arq", "huey", "bullmq", "bull", "bee-queue", "graphile-worker",
                     "pg-boss", "agenda", "sqs-consumer", "sidekiq", "kombu"]


# ---------------------------------------------------------------- helpers
def read_text(path: str) -> Optional[str]:
    try:
        if os.path.getsize(path) > MAX_FILE_BYTES:
            return None
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return f.read()
    except OSError:
        return None


def read_json(path: str) -> Optional[dict]:
    txt = read_text(path)
    if txt is None:
        return None
    try:
        return json.loads(txt)
    except ValueError:
        return None


def walk(repo: str):
    for root, dirs, files in os.walk(repo):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not d.startswith(".git"))
        for fn in sorted(files):
            yield os.path.join(root, fn)


def rel(repo: str, path: str) -> str:
    return os.path.relpath(path, repo).replace(os.sep, "/")


def is_scannable(fn: str) -> bool:
    base = os.path.basename(fn)
    if base in SPECIAL_NAMES or base.startswith("Dockerfile") or base.startswith(".env"):
        return True
    ext = os.path.splitext(base)[1].lower()
    return ext in CODE_EXT or ext in CONFIG_EXT


def find_first(repo: str, candidates: List[str]) -> Optional[str]:
    for c in candidates:
        if os.path.exists(os.path.join(repo, c)):
            return c
    return None


def parse_toml_simple(txt: str) -> Dict[str, Dict[str, str]]:
    """Tiny TOML reader: [table] / key = value (strings, numbers). Enough for railway.toml."""
    out: Dict[str, Dict[str, str]] = defaultdict(dict)
    table = ""
    for line in txt.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        m = re.match(r"^\[([^\]]+)\]$", line)
        if m:
            table = m.group(1).strip()
            continue
        m = re.match(r"^([A-Za-z0-9_.-]+)\s*=\s*(.+)$", line)
        if m:
            v = m.group(2).strip().strip('"').strip("'")
            out[table][m.group(1)] = v
    return out


def dep_names_from_package_json(pkg: dict) -> Dict[str, str]:
    deps: Dict[str, str] = {}
    for k in ("dependencies", "devDependencies", "peerDependencies", "optionalDependencies"):
        d = pkg.get(k) or {}
        if isinstance(d, dict):
            deps.update({str(a): str(b) for a, b in d.items()})
    return deps


def python_deps(repo: str) -> Tuple[Set[str], List[str]]:
    names: Set[str] = set()
    sources: List[str] = []
    for fn in ("requirements.txt", "requirements/base.txt", "requirements/prod.txt", "requirements-prod.txt", "Pipfile", "pyproject.toml"):
        p = os.path.join(repo, fn)
        if not os.path.exists(p):
            continue
        txt = read_text(p) or ""
        sources.append(fn)
        if fn.endswith(".txt"):
            for line in txt.splitlines():
                line = line.split("#", 1)[0].strip()
                if not line or line.startswith("-"):
                    continue
                m = re.match(r"^([A-Za-z0-9_.-]+)", line)
                if m:
                    names.add(m.group(1).lower().replace("_", "-"))
        else:
            for m in re.finditer(r"^\s*\"?([A-Za-z0-9_.-]+)\"?\s*(?:[=<>!~\[]|$)", txt, re.MULTILINE):
                n = m.group(1).lower().replace("_", "-")
                if n not in {"name", "version", "description", "readme", "requires-python", "python", "dependencies", "build-backend", "requires"}:
                    names.add(n)
            for m in re.finditer(r"[\"']([A-Za-z0-9_.-]+)(?:\[[^\]]*\])?\s*[=<>!~]", txt):
                names.add(m.group(1).lower().replace("_", "-"))
    return names, sources


# ---------------------------------------------------------------- main scan
def scan(repo: str, vercel_node: Optional[str] = None) -> dict:
    repo = os.path.abspath(repo)
    result: dict = {"repo": repo, "scanner": "scan_codebase.py", "flags": []}
    flags: List[dict] = result["flags"]

    def flag(sev: str, msg: str, **extra):
        f = {"severity": sev, "message": msg}
        f.update(extra)
        flags.append(f)

    # ---- package manager
    lock = {
        "pnpm-lock.yaml": "pnpm", "yarn.lock": "yarn", "package-lock.json": "npm", "bun.lockb": "bun", "bun.lock": "bun",
        "uv.lock": "uv", "poetry.lock": "poetry", "Pipfile.lock": "pipenv", "requirements.txt": "pip",
        "go.sum": "go-modules", "Cargo.lock": "cargo", "Gemfile.lock": "bundler", "composer.lock": "composer",
    }
    pms = [v for k, v in lock.items() if os.path.exists(os.path.join(repo, k))]
    pkg = read_json(os.path.join(repo, "package.json")) or {}
    pm_field = pkg.get("packageManager") if isinstance(pkg, dict) else None
    result["package_manager"] = {"detected": pms, "package_json_packageManager": pm_field,
                                 "workspaces": bool(pkg.get("workspaces")) or os.path.exists(os.path.join(repo, "pnpm-workspace.yaml"))}
    if "yarn" in pms and os.path.exists(os.path.join(repo, ".yarnrc.yml")):
        result["package_manager"]["yarn_berry"] = True

    # ---- node version
    node_versions: Dict[str, str] = {}
    for fn in (".nvmrc", ".node-version"):
        t = read_text(os.path.join(repo, fn))
        if t:
            node_versions[fn] = t.strip()
    if isinstance(pkg.get("engines"), dict) and pkg["engines"].get("node"):
        node_versions["package.json engines.node"] = str(pkg["engines"]["node"])
    if isinstance(pkg.get("volta"), dict) and pkg["volta"].get("node"):
        node_versions["package.json volta.node"] = str(pkg["volta"]["node"])
    tv = read_text(os.path.join(repo, ".tool-versions"))
    if tv:
        m = re.search(r"^nodejs\s+(\S+)", tv, re.MULTILINE)
        if m:
            node_versions[".tool-versions"] = m.group(1)
    result["node_version"] = node_versions

    # ---- deps + framework
    deps = dep_names_from_package_json(pkg) if isinstance(pkg, dict) else {}
    pydeps, pysources = python_deps(repo)
    gomod = read_text(os.path.join(repo, "go.mod")) or ""
    cargo = read_text(os.path.join(repo, "Cargo.toml")) or ""
    gemfile = read_text(os.path.join(repo, "Gemfile")) or ""
    frameworks: List[str] = []
    for dep, name in FRAMEWORK_DEPS:
        if dep in deps and name not in frameworks:
            frameworks.append(name)
    for dep, name in PY_FRAMEWORKS:
        if dep in pydeps:
            frameworks.append(name)
    if gomod:
        frameworks.append("go")
        for mod, name in (("gin-gonic/gin", "gin"), ("labstack/echo", "echo"), ("gofiber/fiber", "fiber"), ("go-chi/chi", "chi")):
            if mod in gomod:
                frameworks.append(name)
    if cargo:
        frameworks.append("rust")
        for crate in ("axum", "actix-web", "rocket", "warp"):
            if re.search(r"^\s*%s\s*=" % re.escape(crate), cargo, re.MULTILINE):
                frameworks.append(crate)
    if gemfile:
        if re.search(r"gem\s+['\"]rails['\"]", gemfile):
            frameworks.append("rails")
        elif re.search(r"gem\s+['\"]sinatra['\"]", gemfile):
            frameworks.append("sinatra")
        else:
            frameworks.append("ruby")
    primary = next((f for f in frameworks if f not in ("react", "vite")), frameworks[0] if frameworks else None)
    result["framework"] = {"primary": primary, "all": frameworks,
                           "python_workers": sorted(d for d in PY_WORKERS if d in pydeps),
                           "python_servers": sorted(d for d in PY_SERVERS if d in pydeps),
                           "python_dep_sources": pysources}
    result["dependencies"] = {
        "node_count": len(deps),
        "python_count": len(pydeps),
        "next_version": deps.get("next"),
        "payload": sorted(d for d in deps if d.startswith("@payloadcms/") or d == "payload"),
        "auth": sorted(d for d in AUTH_LIBS if d in deps or d in pydeps),
        "orm": sorted(d for d in ORM_LIBS if d in deps or d in pydeps),
        "db_drivers": sorted(d for d in DB_DRIVERS if d in deps or d in pydeps or (gomod and d in gomod) or (cargo and d in cargo)),
        "queue_cache": sorted(d for d in QUEUE_CACHE if d in deps or d in pydeps),
        "webhook_sdks": sorted(d for d in WEBHOOK_SDKS if d in deps or d in pydeps),
        "cron_libs": sorted(d for d in CRON_LIBS if d in deps or d in pydeps),
        "queue_workers": sorted(d for d in QUEUE_WORKER_LIBS if d in deps or d in pydeps or (gemfile and re.search(r"gem\s+['\"]%s['\"]" % re.escape(d), gemfile))),
        "vercel_packages": sorted(d for d in VERCEL_PACKAGES if d in deps),
        "aws_sdk": sorted(d for d in deps if d.startswith("@aws-sdk/")) + sorted(d for d in pydeps if d in ("boto3", "aiobotocore")),
        "sharp": deps.get("sharp"),
    }

    # ---- scripts / start commands
    scripts = pkg.get("scripts") if isinstance(pkg.get("scripts"), dict) else {}
    result["commands"] = {"package_json_scripts": {k: scripts[k] for k in ("dev", "build", "start", "test", "migrate", "db:migrate", "postinstall", "prebuild", "lint") if k in scripts}}
    procfile = read_text(os.path.join(repo, "Procfile"))
    if procfile:
        result["commands"]["procfile"] = {l.split(":", 1)[0].strip(): l.split(":", 1)[1].strip() for l in procfile.splitlines() if ":" in l and not l.startswith("#")}

    # ---- ports declared by start commands (filled in as sources are discovered below)
    port_sources: Dict[str, List[dict]] = defaultdict(list)   # port -> [{source, detail}]
    port_env_sources: List[str] = []                          # commands that use $PORT

    def ports_in_command(cmd: str, source: str):
        found = False
        for pat in COMMAND_PORT_PATTERNS:
            for m in pat.finditer(cmd):
                port_sources[m.group(1)].append({"source": source, "detail": cmd.strip()[:160]})
                found = True
        if PORT_ENV_IN_COMMAND_RE.search(cmd):
            port_env_sources.append(source)
        return found

    if "start" in scripts:
        ports_in_command(str(scripts["start"]), "package.json scripts.start")
        # Framework servers that read $PORT and default to 3000 without any literal in the command.
        for marker, label in (("react-router-serve", "react-router-serve"), ("remix-serve", "remix-serve"),
                              ("next start", "next start"), ("nuxt start", "nuxt"), ("astro preview", "astro"),
                              ("node build/server", "node build/server")):
            if marker in str(scripts["start"]):
                port_sources["3000"].append({"source": "package.json scripts.start", "detail": "%s listens on $PORT (default 3000)" % label})
                port_env_sources.append("package.json scripts.start (%s)" % label)
                break
    for k, v in (result["commands"].get("procfile") or {}).items():
        ports_in_command(str(v), "Procfile %s" % k)

    # ---- platform markers + railway/vercel config
    markers = {}
    for fn in ("railway.json", "railway.toml", ".railway/railway.ts", ".railway/railway.py", "nixpacks.toml", "railpack.json",
               "Procfile", "Dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml",
               "vercel.json", ".vercel/project.json", "fly.toml", "render.yaml", "app.yaml", "serverless.yml", "sst.config.ts",
               "open-next.config.ts", "amplify.yml", "netlify.toml", ".github/workflows"):
        if os.path.exists(os.path.join(repo, fn)):
            markers[fn] = True
    result["platform_markers"] = sorted(markers)

    railway_cfg: dict = {}
    rj = read_json(os.path.join(repo, "railway.json"))
    if rj:
        railway_cfg["railway.json"] = {"build": rj.get("build"), "deploy": rj.get("deploy"), "environments": sorted((rj.get("environments") or {}).keys())}
    rt = read_text(os.path.join(repo, "railway.toml"))
    if rt:
        railway_cfg["railway.toml"] = parse_toml_simple(rt)
    rts = read_text(os.path.join(repo, ".railway/railway.ts"))
    if rts:
        railway_cfg[".railway/railway.ts"] = {
            "services": re.findall(r"\bservice\(\s*['\"]([^'\"]+)['\"]", rts),
            "functions": re.findall(r"\bfn\(\s*['\"]([^'\"]+)['\"]", rts),
            "databases": re.findall(r"\b(postgres|redis|mysql|mongo)\(\s*['\"]([^'\"]+)['\"]", rts),
            "buckets": re.findall(r"\bbucket\(\s*['\"]([^'\"]+)['\"]", rts),
            "volumes": re.findall(r"\bvolume\(\s*['\"]([^'\"]+)['\"]", rts),
            "cron": re.findall(r"cronSchedule\s*:\s*['\"]([^'\"]+)['\"]", rts),
            "healthchecks": re.findall(r"healthcheck\s*:\s*['\"]([^'\"]+)['\"]", rts),
            "preserve_count": len(re.findall(r"preserve\(\)", rts)),
        }
    result["railway_config"] = railway_cfg
    for src, cfg in railway_cfg.items():
        dep = cfg.get("deploy") if isinstance(cfg, dict) else None
        if isinstance(dep, dict) and dep.get("startCommand"):
            ports_in_command(str(dep["startCommand"]), "%s deploy.startCommand" % src)

    vercel_cfg: dict = {}
    vj = read_json(os.path.join(repo, "vercel.json"))
    if vj:
        vercel_cfg = {k: vj.get(k) for k in ("crons", "functions", "regions", "framework", "buildCommand", "outputDirectory", "cleanUrls", "trailingSlash", "proxy") if k in vj}
        for k in ("rewrites", "redirects", "headers"):
            if k in vj:
                vercel_cfg[k + "_count"] = len(vj.get(k) or [])
    result["vercel_config"] = vercel_cfg

    # ---- Dockerfile(s), compose
    dockerfiles = {}
    for p in walk(repo):
        base = os.path.basename(p)
        if base == "Dockerfile" or base.startswith("Dockerfile."):
            txt = read_text(p) or ""
            froms = re.findall(r"^\s*FROM\s+(\S+)", txt, re.MULTILINE | re.IGNORECASE)
            expose = re.findall(r"^\s*EXPOSE\s+(.+)$", txt, re.MULTILINE | re.IGNORECASE)
            cmds = re.findall(r"^\s*(?:CMD|ENTRYPOINT)\s+(.+)$", txt, re.MULTILINE | re.IGNORECASE)
            for e in expose:
                for port in re.findall(r"(\d{2,5})", e):
                    port_sources[port].append({"source": "%s EXPOSE" % rel(repo, p), "detail": "EXPOSE %s" % e.strip()})
            for c in cmds:
                ports_in_command(c, "%s CMD/ENTRYPOINT" % rel(repo, p))
            dockerfiles[rel(repo, p)] = {
                "from": froms,
                "expose": expose,
                "cmd": cmds,
                "user": re.findall(r"^\s*USER\s+(\S+)", txt, re.MULTILINE | re.IGNORECASE),
                "healthcheck": bool(re.search(r"^\s*HEALTHCHECK\b", txt, re.MULTILINE | re.IGNORECASE)),
                "args": re.findall(r"^\s*ARG\s+([A-Za-z_][A-Za-z0-9_]*)", txt, re.MULTILINE),
                "railway_cache_mount": bool(re.search(r"--mount=type=cache,id=s/", txt)),
                "platform_pinned": re.findall(r"--platform=(\S+)", txt),
            }
            for f in froms:
                m = re.match(r"(?:.*/)?node:(\d+)", f)
                if m:
                    node_versions.setdefault("Dockerfile FROM", m.group(1))
    result["dockerfiles"] = dockerfiles
    compose_path = find_first(repo, ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"])
    if compose_path:
        txt = read_text(os.path.join(repo, compose_path)) or ""
        m = re.search(r"^services:\s*$(.*?)(?=^\S|\Z)", txt, re.MULTILINE | re.DOTALL)
        svc_names = re.findall(r"^  ([A-Za-z0-9_.-]+):\s*$", m.group(1), re.MULTILINE) if m else []
        result["compose"] = {"file": compose_path, "services": svc_names,
                             "images": re.findall(r"^\s*image:\s*(\S+)", txt, re.MULTILINE)}

    # ---- next.config
    next_cfg_file = find_first(repo, ["next.config.ts", "next.config.mjs", "next.config.js", "next.config.cjs"])
    nextjs: dict = {"config_file": next_cfg_file}
    if next_cfg_file:
        txt = read_text(os.path.join(repo, next_cfg_file)) or ""
        nextjs.update({
            "output_standalone": bool(re.search(r"output\s*:\s*['\"]standalone['\"]", txt)),
            "output_export": bool(re.search(r"output\s*:\s*['\"]export['\"]", txt)),
            "cacheHandler": bool(re.search(r"\bcacheHandler\b", txt)),
            "cacheHandlers_plural": bool(re.search(r"\bcacheHandlers\b", txt)),
            "cacheMaxMemorySize": bool(re.search(r"\bcacheMaxMemorySize\b", txt)),
            "images_remotePatterns": bool(re.search(r"\bremotePatterns\b", txt)),
            "images_domains_deprecated": bool(re.search(r"images\s*:\s*{[^}]*\bdomains\b", txt, re.DOTALL)),
            "images_unoptimized": bool(re.search(r"unoptimized\s*:\s*true", txt)),
            "rewrites": bool(re.search(r"\brewrites\b", txt)),
            "redirects": bool(re.search(r"\bredirects\b", txt)),
            "headers": bool(re.search(r"\bheaders\b", txt)),
            "basePath": bool(re.search(r"\bbasePath\b", txt)),
            "assetPrefix": bool(re.search(r"\bassetPrefix\b", txt)),
            "deploymentId": bool(re.search(r"\bdeploymentId\b", txt)),
            "serverExternalPackages": bool(re.search(r"serverExternalPackages|serverComponentsExternalPackages", txt)),
            "withPayload": bool(re.search(r"withPayload", txt)),
            "experimental": bool(re.search(r"\bexperimental\s*:", txt)),
        })
    nextjs["middleware_file"] = find_first(repo, ["middleware.ts", "middleware.js", "src/middleware.ts", "src/middleware.js"])
    nextjs["proxy_file"] = find_first(repo, ["proxy.ts", "proxy.js", "src/proxy.ts", "src/proxy.js"])
    nextjs["app_router"] = bool(find_first(repo, ["app", "src/app"]))
    nextjs["pages_router"] = bool(find_first(repo, ["pages", "src/pages"]))
    nextjs["payload_config"] = find_first(repo, ["payload.config.ts", "src/payload.config.ts", "payload.config.js", "src/payload.config.js"])
    result["nextjs"] = nextjs

    # ---- content scan
    env_refs: Dict[str, Set[str]] = defaultdict(set)
    env_example_names: Dict[str, List[str]] = {}
    hostnames: Dict[str, Dict[str, Set[str]]] = defaultdict(lambda: defaultdict(set))
    ports: Dict[str, Set[str]] = defaultdict(set)
    health_paths: Dict[str, Set[str]] = defaultdict(set)
    health_files: List[str] = []
    edge_files: List[str] = []
    node_runtime_files: List[str] = []
    revalidate_tag_files: List[str] = []
    revalidate_path_files: List[str] = []
    isr_files: Dict[str, str] = {}
    dynamic_files: Dict[str, str] = {}
    preferred_region_files: List[str] = []
    next_image_files: List[str] = []
    use_cache_files: List[str] = []
    unstable_cache_files: List[str] = []
    wait_until_files: List[str] = []
    vercel_header_files: Dict[str, Set[str]] = defaultdict(set)
    vercel_import_files: Dict[str, Set[str]] = defaultdict(set)
    webhook_routes: Dict[str, Set[str]] = defaultdict(set)
    pgbouncer_files: Dict[str, Set[str]] = defaultdict(set)
    db_tls_off: Dict[str, Set[str]] = defaultdict(set)        # file -> {pattern labels}
    twilio_req_url_files: List[str] = []
    fs_write_files: Dict[str, Set[str]] = defaultdict(set)    # file -> {pattern labels}
    gh_cron: List[dict] = []
    test_markers: Set[str] = set()
    code_files = 0

    for p in walk(repo):
        r = rel(repo, p)
        base = os.path.basename(p)
        if base in ("package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "Cargo.lock", "poetry.lock", "uv.lock", "composer.lock"):
            continue
        if not is_scannable(base):
            continue
        txt = read_text(p)
        if txt is None:
            continue
        ext = os.path.splitext(base)[1].lower()
        is_code = ext in CODE_EXT

        # .env* files: names only
        if base.startswith(".env"):
            names = sorted({m.group(1) for m in re.finditer(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=", txt, re.MULTILINE)})
            env_example_names[r] = names
            if base not in (".env.example", ".env.sample", ".env.template", ".env.dist", ".env.schema"):
                flag("warn", "%s is present in the working tree; make sure it is git-ignored and never copied into the Docker build context" % r, file=r)
            continue

        if is_code:
            code_files += 1
        if re.search(r"(^|/)(tests?|__tests__|spec|e2e|cypress)(/|$)", r) or re.search(r"\.(test|spec)\.[cm]?[jt]sx?$", r) or re.search(r"(^|/)(test_[^/]+|[^/]+_test)\.py$", r):
            test_markers.add(r.split("/")[0] if "/" in r else r)

        for pat in ENV_PATTERNS:
            for m in pat.finditer(txt):
                env_refs[m.group(1)].add(r)
        for label, pat in HOSTNAME_PATTERNS.items():
            for m in pat.finditer(txt):
                hostnames[label][m.group(0).lstrip(".")].add(r)
        for pat in PORT_PATTERNS:
            for m in pat.finditer(txt):
                ports[m.group(1)].add(r)
        for m in HEALTH_PATH_RE.finditer(txt):
            health_paths[m.group(1)].add(r)
        if HEALTH_FILE_RE.search(r):
            health_files.append(r)
        if r.startswith(".github/workflows/") and ext in (".yml", ".yaml"):
            for m in re.finditer(r"cron:\s*['\"]([^'\"]+)['\"]", txt):
                gh_cron.append({"file": r, "schedule": m.group(1)})
        if PGBOUNCER_RE.search(txt):
            for m in PGBOUNCER_RE.finditer(txt):
                pgbouncer_files[r].add(m.group(0))
        if is_code and ("webhook" in r.lower() or WEBHOOK_HINT_RE.search(txt)):
            webhook_routes[r] = {m.group(0) for m in WEBHOOK_HINT_RE.finditer(txt)}
        # (a) DB TLS verification disabled (code + config files; .env files were skipped above)
        for label, pat in DB_TLS_OFF_PATTERNS:
            if pat.search(txt):
                db_tls_off[r].add(label)
        # (b) Twilio validateRequest(token, signature, req.url, params)
        if is_code and "validateRequest" in txt:
            for m in TWILIO_VALIDATE_RE.finditer(txt):
                if TWILIO_REQ_URL_RE.search(m.group(1)):
                    twilio_req_url_files.append(r)
                    break
        # (c) local filesystem writes (skip tests, build tooling, scripts, config files)
        is_test = bool(re.search(r"(^|/)(tests?|__tests__|spec|e2e|cypress)(/|$)", r) or re.search(r"\.(test|spec)\.[cm]?[jt]sx?$", r) or re.search(r"(^|/)(test_[^/]+|[^/]+_test)\.py$", r))
        if is_code and not is_test and not FS_WRITE_IGNORE_FILE_RE.search(r):
            for label, pat in FS_WRITE_PATTERNS:
                for m in pat.finditer(txt):
                    line_start = txt.rfind("\n", 0, m.start()) + 1
                    line_end = txt.find("\n", m.end())
                    line = txt[line_start:line_end if line_end != -1 else len(txt)]
                    if FS_WRITE_IGNORE_LINE_RE.search(line):
                        continue
                    fs_write_files[r].add(label)
                    break

        if ext in (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts"):
            if EDGE_RUNTIME_RE.search(txt):
                edge_files.append(r)
            if NODE_RUNTIME_RE.search(txt):
                node_runtime_files.append(r)
            if REVALIDATE_TAG_RE.search(txt):
                revalidate_tag_files.append(r)
            if REVALIDATE_PATH_RE.search(txt):
                revalidate_path_files.append(r)
            m = ISR_RE.search(txt)
            if m:
                isr_files[r] = m.group(1)
            m = DYNAMIC_RE.search(txt)
            if m:
                dynamic_files[r] = m.group(1)
            if PREFERRED_REGION_RE.search(txt):
                preferred_region_files.append(r)
            if NEXT_IMAGE_RE.search(txt):
                next_image_files.append(r)
            if USE_CACHE_RE.search(txt):
                use_cache_files.append(r)
            if UNSTABLE_CACHE_RE.search(txt):
                unstable_cache_files.append(r)
            if WAIT_UNTIL_RE.search(txt):
                wait_until_files.append(r)
            for m in VERCEL_HEADER_RE.finditer(txt):
                vercel_header_files[m.group(0).lower()].add(r)
            for m in IMPORT_RE.finditer(txt):
                mod = m.group(1)
                for vp in VERCEL_PACKAGES:
                    if mod == vp or mod.startswith(vp + "/"):
                        vercel_import_files[vp].add(r)
        elif ext == ".py":
            for m in PY_IMPORT_RE.finditer(txt):
                mod = (m.group(1) or m.group(2) or "").split(".")[0]
                if mod in ("boto3", "celery", "redis", "psycopg", "psycopg2", "asyncpg"):
                    pass  # covered by dependency detection

    # Classification (names only). `class` drives where the value lives on AWS:
    #   secret           -> Secrets Manager JSON secret (put_secrets.sh); never plain task env
    #   public_buildtime -> Docker build args (inlined into the client bundle); never a runtime secret
    #   platform         -> injected by Vercel/Railway; does not exist on AWS, replace or drop
    #   config           -> plain task-definition environment (Terraform plain_env)
    # `category` is a finer hint used by other flags (datastore, storage, runtime, aws_sdk, general).
    SECRET_NAME_RE = re.compile(r"WEBHOOK_URL|HOOK_URL|_DSN$|^DSN$|_TOKEN|_KEY|_SECRET|PASSWORD|PASSWD|PRIVATE|CREDENTIAL|SIGNING|_API_KEY|^API_KEY")
    DATASTORE_URL_RE = re.compile(r"^(DATABASE|POSTGRES|POSTGRESQL|PG|DIRECT|REDIS|KV|UPSTASH|MONGO|MONGODB|MYSQL|AMQP|RABBITMQ|CLICKHOUSE|ELASTIC)[A-Z_]*(URL|URI|DSN|CONNECTION_STRING)$")
    PUBLIC_PREFIXES = ("NEXT_PUBLIC_", "VITE_", "REACT_APP_", "PUBLIC_", "NUXT_PUBLIC_", "EXPO_PUBLIC_", "GATSBY_", "SVELTEKIT_PUBLIC_", "NX_PUBLIC_")

    def env_class(name: str) -> str:
        if name.startswith(PUBLIC_PREFIXES):
            return "public_buildtime"
        if name.startswith(("VERCEL_", "RAILWAY_", "RAILPACK_", "NIXPACKS_")):
            return "platform"
        if SECRET_NAME_RE.search(name):
            return "secret"
        if DATASTORE_URL_RE.match(name):
            return "secret"  # connection strings embed credentials
        return "config"

    def env_category(name: str) -> str:
        if name.startswith("VERCEL_"):
            return "vercel_system"
        if name.startswith(("RAILWAY_", "RAILPACK_", "NIXPACKS_")):
            return "railway_system"
        if name in ("PORT", "HOSTNAME", "HOST", "NODE_ENV", "TZ", "NODE_OPTIONS", "PYTHONUNBUFFERED", "WEB_CONCURRENCY"):
            return "runtime_platform"
        if name.startswith("AWS_"):
            return "aws_sdk"
        if re.match(r"^(DATABASE_|POSTGRES|PG|DIRECT_URL|DATABASE_UNPOOLED|REDIS|KV_|UPSTASH|MONGO|MYSQL)", name):
            return "datastore"
        if name.startswith(("BLOB_", "S3_", "CDN_", "MEDIA_", "UPLOAD")):
            return "storage"
        return "general"

    env_sorted = sorted(env_refs)
    result["env_vars"] = {
        "count": len(env_sorted),
        "classes": {"secret": "Secrets Manager JSON secret (put_secrets.sh)", "public_buildtime": "Docker build arg (inlined at build)",
                    "config": "plain task environment (Terraform plain_env)", "platform": "platform-injected; replace or drop"},
        "references": [{"name": n, "files": len(env_refs[n]), "class": env_class(n), "category": env_category(n), "sample_file": sorted(env_refs[n])[0]} for n in env_sorted],
        "by_class": {},
        "by_category": {},
        "env_file_names": env_example_names,
    }
    byc: Dict[str, List[str]] = defaultdict(list)
    bycat: Dict[str, List[str]] = defaultdict(list)
    for n in env_sorted:
        byc[env_class(n)].append(n)
        bycat[env_category(n)].append(n)
    result["env_vars"]["by_class"] = dict(byc)
    result["env_vars"]["by_category"] = dict(bycat)
    declared = set()
    for names in env_example_names.values():
        declared.update(names)
    if declared:
        result["env_vars"]["referenced_but_not_in_env_example"] = sorted(n for n in env_sorted if n not in declared and env_class(n) != "platform" and env_category(n) not in ("runtime_platform", "aws_sdk"))
        result["env_vars"]["in_env_example_but_unreferenced"] = sorted(n for n in declared if n not in env_refs)
        # names declared only in .env files still need a home on AWS
        result["env_vars"]["env_file_classification"] = {c: sorted(n for n in declared if env_class(n) == c) for c in ("secret", "public_buildtime", "config", "platform")}

    result["hostnames"] = {label: {h: sorted(files) for h, files in sorted(hs.items())} for label, hs in hostnames.items()}
    result["ports"] = {port: sorted(files) for port, files in sorted(ports.items(), key=lambda kv: -len(kv[1]))}
    # Declared ports win over code literals: CMD/start command > EXPOSE > Procfile/package.json > code.
    def port_rank(port: str) -> Tuple[int, int]:
        srcs = [d["source"] for d in port_sources.get(port, [])]
        score = 0
        if any("CMD/ENTRYPOINT" in x or "startCommand" in x for x in srcs):
            score = 4
        elif any("EXPOSE" in x for x in srcs):
            score = 3
        elif any(x.startswith(("Procfile", "package.json")) for x in srcs):
            score = 2
        elif port in ports:
            score = 1
        return (score, len(srcs) + len(ports.get(port, ())))
    all_ports = sorted(set(port_sources) | set(ports), key=port_rank, reverse=True)
    result["port_detection"] = {
        "recommended": all_ports[0] if all_ports else None,
        "declared": {p_: port_sources[p_] for p_ in port_sources},
        "code_literals": result["ports"],
        "uses_PORT_env": sorted(set(port_env_sources)) or bool(env_refs.get("PORT")),
    }
    result["health"] = {"route_files": sorted(set(health_files)), "paths_referenced": {k: sorted(v) for k, v in health_paths.items()}}
    result["crons"] = {
        "vercel_json": (vj or {}).get("crons") if vj else None,
        "railway": [railway_cfg.get("railway.json", {}).get("deploy", {}) or {}][0].get("cronSchedule") if railway_cfg.get("railway.json") else None,
        "railway_toml": (railway_cfg.get("railway.toml", {}).get("deploy", {}) or {}).get("cronSchedule") if railway_cfg.get("railway.toml") else None,
        "railway_ts": railway_cfg.get(".railway/railway.ts", {}).get("cron") if railway_cfg.get(".railway/railway.ts") else None,
        "github_actions": gh_cron,
        "in_process_libs": result["dependencies"]["cron_libs"],
        "queue_worker_libs": result["dependencies"]["queue_workers"],
    }
    result["tests"] = {"present": bool(test_markers) or bool(scripts.get("test")) or any(d in deps for d in ("jest", "vitest", "@playwright/test", "cypress", "mocha")) or "pytest" in pydeps,
                       "runners": sorted(d for d in ("jest", "vitest", "@playwright/test", "cypress", "mocha", "ava", "pytest", "unittest") if d in deps or d in pydeps),
                       "test_script": scripts.get("test"), "locations": sorted(test_markers)[:20]}
    result["nextjs"].update({
        "edge_runtime_files": sorted(set(edge_files)),
        "nodejs_runtime_files": sorted(set(node_runtime_files)),
        "revalidateTag_files": sorted(set(revalidate_tag_files)),
        "revalidatePath_files": sorted(set(revalidate_path_files)),
        "isr_revalidate_files": isr_files,
        "dynamic_files": dynamic_files,
        "preferredRegion_files": sorted(set(preferred_region_files)),
        "next_image_files": sorted(set(next_image_files)),
        "use_cache_files": sorted(set(use_cache_files)),
        "unstable_cache_files": sorted(set(unstable_cache_files)),
        "waitUntil_files": sorted(set(wait_until_files)),
        "x_vercel_headers": {k: sorted(v) for k, v in vercel_header_files.items()},
    })
    result["vercel_imports"] = {k: sorted(v) for k, v in vercel_import_files.items()}
    result["webhooks"] = {r: sorted(h) for r, h in sorted(webhook_routes.items())}
    result["pooling_hints"] = {r: sorted(h) for r, h in sorted(pgbouncer_files.items())}
    result["db_tls_verification_disabled"] = {r: sorted(h) for r, h in sorted(db_tls_off.items())}
    result["twilio_validate_request_req_url"] = sorted(set(twilio_req_url_files))
    result["local_fs_writes"] = {r: sorted(h) for r, h in sorted(fs_write_files.items())}
    result["stats"] = {"code_files_scanned": code_files}

    # ---- Payload
    payload = result["dependencies"]["payload"]
    result["payload"] = {
        "in_use": bool(payload),
        "db_adapter": next((d for d in payload if d.startswith("@payloadcms/db-")), None),
        "storage_adapters": [d for d in payload if d.startswith("@payloadcms/storage-") or d == "@payloadcms/plugin-cloud-storage"],
        "config_file": nextjs.get("payload_config"),
        "version": deps.get("payload") or next((deps[d] for d in payload), None),
    }

    # ---------------------------------------------------------------- migration flags
    is_next = primary == "nextjs"
    if is_next:
        if nextjs.get("output_standalone"):
            flag("ok", "next.config already has `output: 'standalone'`: Dockerfile.nextjs runner stage applies as-is", file=nextjs.get("config_file"))
        else:
            flag("action", "next.config: `output: 'standalone'` is MISSING; set it so the Docker image ships only .next/standalone (+ static/public copied in)", file=nextjs.get("config_file"))
        if nextjs.get("output_export"):
            flag("info", "next.config has `output: 'export'` (static site): host on S3 + CloudFront instead of Fargate")
        if edge_files:
            flag("action", "%d file(s) declare `export const runtime = 'edge'`: edge runtime routes must move to nodejs (remove the export) before self-hosting" % len(edge_files), files=sorted(set(edge_files)))
        if nextjs.get("middleware_file") and not nextjs.get("proxy_file"):
            flag("info", "middleware.ts found (Next 16 renames it to proxy.ts, Node runtime). It runs inside the standalone server; verify it does not use edge-only APIs", file=nextjs["middleware_file"])
        if preferred_region_files:
            flag("info", "`export const preferredRegion` is Vercel-only; remove it", files=sorted(set(preferred_region_files)))
        if revalidate_tag_files or revalidate_path_files or isr_files or use_cache_files or unstable_cache_files:
            if not nextjs.get("cacheHandler"):
                flag("action", "ISR / revalidateTag / revalidatePath / use cache detected but no `cacheHandler` in next.config: with >1 Fargate task the cache is per-container. Add a shared cache handler (Redis/Valkey or S3) and set `cacheMaxMemorySize: 0`, or force dynamic rendering. revalidateTag only clears the server cache: CloudFront must be invalidated separately")
            else:
                flag("info", "cacheHandler configured: verify it stores entries in shared storage reachable from all tasks (ElastiCache/S3) and implements refreshTags()")
        if next_image_files and not nextjs.get("images_remotePatterns") and not nextjs.get("images_unoptimized"):
            flag("info", "next/image used: add the new media CDN host to images.remotePatterns (and keep the old Blob host during overlap)")
        if nextjs.get("images_domains_deprecated"):
            flag("info", "next.config images.domains is deprecated: migrate to images.remotePatterns")
        if wait_until_files:
            flag("action", "waitUntil() usage found (Vercel-only via @vercel/functions): replace with `after()` from next/server and set ECS stopTimeout >= 30s", files=sorted(set(wait_until_files)))
        if vercel_header_files:
            flag("action", "x-vercel-* request headers are read in code: map to CloudFront-Viewer-* headers (origin request policy) or ALB X-Forwarded-For", headers=sorted(vercel_header_files))
        if not nextjs.get("deploymentId"):
            flag("info", "no `deploymentId` in next.config: set it (e.g. git SHA) to avoid client/server version skew during rolling ECS deploys")
    pub = byc.get("public_buildtime", [])
    if pub:
        flag("action", "%d NEXT_PUBLIC_*/VITE_*/REACT_APP_*/PUBLIC_* vars are build-time: pass them as Docker build args (ARG/ENV in the builder stage, DOCKER_BUILD_ARGS in the workflow), not runtime task env" % len(pub), vars=pub)
    if bycat.get("vercel_system"):
        flag("action", "VERCEL_* system vars referenced: they do not exist on AWS; provide APP_URL/GIT_SHA/APP_ENV yourself", vars=bycat["vercel_system"])
    if bycat.get("railway_system"):
        flag("action", "RAILWAY_* injected vars referenced: provide equivalents in the task definition (PORT, service DNS via Service Connect/Cloud Map, task metadata endpoint)", vars=bycat["railway_system"])
    # (a) DB TLS
    if db_tls_off:
        labels = sorted({l for ls in db_tls_off.values() for l in ls})
        flag("action", "TLS verification toward the database is disabled or weakened in %d file(s) (%s): tighten to sslmode=verify-full with the RDS CA bundle (RDS_CA_BUNDLE_PATH=/app/global-bundle.pem is baked into the Docker templates; pg: ssl: { ca: readFileSync(...) }, psycopg: sslrootcert=...). RDS enforces TLS but a no-verify client accepts any certificate" % (len(db_tls_off), ", ".join(labels)), files=sorted(db_tls_off)[:10])
    # (b) Twilio
    if twilio_req_url_files:
        flag("action", "Twilio validateRequest() is called with req.url / request.url / nextUrl: behind CloudFront + ALB the task sees http://<internal-host>/..., not the public https URL Twilio signed, so every webhook fails validation after cutover. Build the URL from a configured public base (e.g. APP_URL + pathname) or trust X-Forwarded-Proto/Host from the ALB only", files=sorted(set(twilio_req_url_files)))
    # (c) local filesystem writes
    if fs_write_files:
        labels = sorted({l for ls in fs_write_files.values() for l in ls})
        flag("action", "writes files to local disk in %d file(s) (%s): Fargate ephemeral storage is per-task and lost on every deploy. Railway volume -> S3 (SDK/presigned URLs, preferred; copy existing data with railway_volume_to_s3.sh) or EFS (POSIX mount into the task; needs NFS + access point) decision required" % (len(fs_write_files), ", ".join(labels)), files=sorted(fs_write_files)[:10])
    if not health_files and not health_paths:
        flag("action", "no health endpoint found: add one (e.g. app/api/health/route.ts returning 200) for the ALB target group and ECS container health check")
    else:
        flag("ok", "health endpoint candidates: %s" % ", ".join(sorted(set(health_files)) or sorted(health_paths)))
    # Vercel storage
    vi = result["vercel_imports"]
    vpk = result["dependencies"]["vercel_packages"]
    if "@vercel/blob" in vpk or "@vercel/blob" in vi or "@payloadcms/storage-vercel-blob" in payload:
        flag("action", "Vercel Blob in use: plan S3 copy with blob_to_s3.ts, switch to @aws-sdk/client-s3 (or @payloadcms/storage-s3), rewrite stored *.blob.vercel-storage.com URLs")
    if "@vercel/kv" in vpk or "@vercel/kv" in vi or any(n.startswith("KV_") for n in env_sorted):
        flag("action", "Vercel KV / Upstash referenced: move to ElastiCache Valkey (ioredis) or keep Upstash from AWS (latency/egress)")
    if "@vercel/postgres" in vpk or "@vercel/postgres" in vi:
        flag("action", "@vercel/postgres in use: replace with pg / postgres.js against RDS")
    if "@vercel/edge-config" in vpk or "@vercel/edge-config" in vi:
        flag("action", "@vercel/edge-config (Global Config) in use: export with getAll() and move to SSM Parameter Store / AppConfig / a cached DynamoDB table")
    if "@vercel/functions" in vpk or "@vercel/functions" in vi:
        flag("action", "@vercel/functions in use (geolocation/ipAddress/waitUntil): replace with CloudFront viewer headers and next/server after()")
    for pkgname in ("@vercel/analytics", "@vercel/speed-insights"):
        if pkgname in vpk or pkgname in vi:
            flag("info", "%s is Vercel-proprietary: remove or swap for CloudWatch RUM / PostHog / Plausible" % pkgname)
    # Payload
    if result["payload"]["in_use"]:
        if result["payload"]["db_adapter"] == "@payloadcms/db-vercel-postgres":
            flag("action", "Payload uses @payloadcms/db-vercel-postgres: swap for @payloadcms/db-postgres (node-postgres pool) pointing at RDS")
        if "@payloadcms/storage-vercel-blob" in payload:
            flag("action", "Payload uses @payloadcms/storage-vercel-blob: swap for @payloadcms/storage-s3 with generateFileURL -> CloudFront and no static credentials (task role)")
        flag("info", "Payload: the build needs a reachable DATABASE_URL or the 'build without DB' pattern; PAYLOAD_SECRET must be re-sourced if it was a Vercel Secret")
    # pooling
    if pgbouncer_files:
        flag("action", "PgBouncer-style URL or ?pgbouncer=true / directUrl / unpooled URL found: on AWS choose RDS Proxy (transaction pinning semantics) or a PgBouncer sidecar, and give migrations the direct endpoint", files=sorted(pgbouncer_files))
    if "@neondatabase/serverless" in deps:
        flag("action", "@neondatabase/serverless driver in use: RDS has no HTTP/WebSocket endpoint; switch to pg / postgres.js")
    # queues / workers
    if result["dependencies"]["queue_cache"]:
        flag("info", "queue/cache clients present (%s): provision ElastiCache Valkey (TLS, rediss://) and a worker ECS service without a load balancer" % ", ".join(result["dependencies"]["queue_cache"]))
    if result["dependencies"]["queue_workers"]:
        flag("action", "queue/worker libraries (%s): these are broker-backed workers, NOT in-process schedulers. Run the worker as its own ECS service (no ALB, enable_worker + worker_command in Terraform, container health command) against ElastiCache Valkey / RDS; scale desired_count independently of the web service" % ", ".join(result["dependencies"]["queue_workers"]))
    # crons
    cr = result["crons"]
    if cr["vercel_json"]:
        flag("action", "%d Vercel cron(s) in vercel.json: recreate as EventBridge rule -> API Destination (Authorization: Bearer CRON_SECRET) or Scheduler -> ECS RunTask; UTC, 6-field cron syntax" % len(cr["vercel_json"]))
    if cr["railway"] or cr["railway_toml"] or cr["railway_ts"]:
        flag("action", "Railway cron service detected: recreate as EventBridge Scheduler -> ECS RunTask; add an overlap guard (Railway skipped overlapping runs, EventBridge does not)")
    if cr["in_process_libs"]:
        flag("info", "in-process scheduler libs (%s): with >1 task the job runs on every replica; move to EventBridge Scheduler -> RunTask or add a distributed lock" % ", ".join(cr["in_process_libs"]))
    # webhooks
    if result["dependencies"]["webhook_sdks"] or webhook_routes:
        flag("action", "third-party webhook SDKs/routes found (%s): update endpoint URLs at each provider after cutover and re-source signing secrets; ensure ALB idle timeout and WAF body rules do not break raw-body signature checks" % ", ".join(result["dependencies"]["webhook_sdks"] or sorted(webhook_routes)[:5]))
    # hostnames
    for label, hs in result["hostnames"].items():
        nfiles = len({f for files in hs.values() for f in files})
        flag("action", "hard-coded %s hostname(s) in %d file(s): %s" % (label, nfiles, ", ".join(sorted(hs))[:200]), files=sorted({f for files in hs.values() for f in files})[:10])
    # ports
    pd = result["port_detection"]
    if pd["recommended"]:
        srcs = pd["declared"].get(pd["recommended"], [])
        where = ", ".join(sorted({d["source"] for d in srcs})) or "code literal"
        extra = ""
        others = [p_ for p_ in list(pd["declared"]) + list(pd["code_literals"]) if p_ != pd["recommended"]]
        if others:
            extra = "; other ports seen: %s" % ", ".join(sorted(set(others)))
        flag("info", "container port looks like %s (from %s%s): set container_port=%s in Terraform, PORT=%s in the task env, and the same port on the target group / health check" % (pd["recommended"], where, extra, pd["recommended"], pd["recommended"]))
    elif is_next:
        flag("info", "no port declared: Next.js standalone listens on PORT (default 3000); Dockerfile.nextjs sets PORT=3000, so container_port=3000 in Terraform")
    else:
        flag("info", "no port declared or defaulted anywhere: confirm which port the app listens on (Railway injected PORT) and set container_port + PORT explicitly")
    if pd["uses_PORT_env"]:
        flag("info", "the start command / code reads $PORT: ECS does not inject it; set PORT in the task definition environment (Dockerfile templates default it)")
    # dockerfile
    if dockerfiles:
        for f, d in dockerfiles.items():
            if d.get("railway_cache_mount"):
                flag("action", "%s uses Railway-specific BuildKit cache ids (--mount=type=cache,id=s/...): strip the id= so CodeBuild/GitHub Actions can build it" % f)
            if not d.get("user"):
                flag("info", "%s runs as root (no USER): add a non-root user for Fargate" % f)
            if any(a in d.get("args", []) for a in pub):
                flag("ok", "%s already declares ARG for public build-time vars" % f)
    else:
        has_vercel = "vercel.json" in markers or ".vercel/project.json" in markers or os.path.isdir(os.path.join(repo, ".vercel"))
        has_railway = any(m in markers for m in ("railway.json", "railway.toml", ".railway/railway.ts", ".railway/railway.py", "nixpacks.toml", "railpack.json"))
        tpl = {"nextjs": "Dockerfile.nextjs", "django": "Dockerfile.python", "fastapi": "Dockerfile.python", "flask": "Dockerfile.python",
               "starlette": "Dockerfile.python", "litestar": "Dockerfile.python"}.get(primary or "", "Dockerfile.node" if pkg else "Dockerfile.python" if pydeps else "a template")
        if has_vercel and not has_railway:
            flag("action", "no Dockerfile: Vercel built this (vercel.json / .vercel present); a Dockerfile is required for ECS Fargate. Start from assets/docker/%s (standalone output, build args for NEXT_PUBLIC_*, tools stage for migrations)" % tpl)
        elif has_railway:
            flag("action", "no Dockerfile: Railway built this with Railpack/Nixpacks (railway config present); synthesize a Dockerfile from assets/docker/%s and mirror the Railway build/start commands (and preDeployCommand -> migration task)" % tpl)
        else:
            flag("action", "no Dockerfile found: ECS Fargate needs one; start from assets/docker/%s and copy the build/start commands from the current platform settings" % tpl)
    if not result["tests"]["present"]:
        flag("info", "no tests detected: rely on smoke tests + the cutover checklist")
    secretish = byc.get("secret", [])
    if secretish:
        flag("info", "%d secret-class env vars referenced (incl. webhook URLs and datastore connection strings) -> one Secrets Manager JSON secret per env, secret_keys in Terraform, values via put_secrets.sh; %d config-class vars -> plain_env" % (len(secretish), len(byc.get("config", []))), vars=secretish[:20])
    # node version
    if node_versions:
        majors = set()
        for v in node_versions.values():
            m = re.search(r"(\d+)", str(v))
            if m:
                majors.add(m.group(1))
        if len(majors) > 1:
            flag("warn", "node version declared inconsistently: %s" % ", ".join("%s=%s" % kv for kv in node_versions.items()))
        if vercel_node:
            vm = re.search(r"(\d+)", str(vercel_node))
            if vm:
                mismatched = {k: v for k, v in node_versions.items() if (re.search(r"(\d+)", str(v)) or vm).group(1) != vm.group(1)}
                if mismatched:
                    flag("warn", "Vercel builds/runs Node %s but %s: align .nvmrc / engines.node and the Dockerfile NODE_VERSION with the version that is known to work (%s.x) before the first ECS build" % (vm.group(1), ", ".join("%s=%s" % kv for kv in mismatched.items()), vm.group(1)))
                else:
                    flag("ok", "Vercel Node %s matches every repo pin; use node:%s-bookworm-slim in the Dockerfile" % (vm.group(1), vm.group(1)))
    elif pkg:
        if vercel_node:
            vm = re.search(r"(\d+)", str(vercel_node))
            flag("warn", "no node version pinned (.nvmrc / engines.node): Vercel runs Node %s; pin that major and use it in the Dockerfile" % (vm.group(1) if vm else vercel_node))
        else:
            flag("warn", "no node version pinned (.nvmrc / engines.node): pin one and use the same major in the Dockerfile")
    result["vercel_node_version"] = vercel_node
    return result


# ---------------------------------------------------------------- markdown
def to_markdown(r: dict) -> str:
    L: List[str] = []
    a = L.append
    a("# Codebase scan: %s" % r["repo"])
    a("")
    a("Generated by scan_codebase.py. No environment variable values are included.")
    a("")
    a("## Migration flags")
    a("")
    order = {"action": 0, "warn": 1, "info": 2, "ok": 3}
    for f in sorted(r["flags"], key=lambda x: order.get(x["severity"], 9)):
        extra = ""
        for k in ("files", "vars", "headers", "file"):
            if k in f and f[k]:
                v = f[k] if isinstance(f[k], list) else [f[k]]
                extra = "  \n  `%s`" % "`, `".join(v[:8]) + (" ..." if len(v) > 8 else "")
        a("- **%s**: %s%s" % (f["severity"].upper(), f["message"], extra))
    a("")
    a("## Stack")
    a("")
    fw = r["framework"]
    a("| item | value |")
    a("|---|---|")
    a("| framework | %s (all: %s) |" % (fw["primary"], ", ".join(fw["all"]) or "-"))
    a("| next version | %s |" % (r["dependencies"].get("next_version") or "-"))
    a("| package manager | %s %s |" % (", ".join(r["package_manager"]["detected"]) or "-", ("(packageManager=%s)" % r["package_manager"]["package_json_packageManager"]) if r["package_manager"]["package_json_packageManager"] else ""))
    a("| node version | %s |" % (", ".join("%s: %s" % kv for kv in r["node_version"].items()) or "not pinned"))
    a("| monorepo/workspaces | %s |" % r["package_manager"]["workspaces"])
    a("| python servers / workers | %s / %s |" % (", ".join(fw["python_servers"]) or "-", ", ".join(fw["python_workers"]) or "-"))
    d = r["dependencies"]
    for k in ("payload", "auth", "orm", "db_drivers", "queue_cache", "queue_workers", "webhook_sdks", "cron_libs", "vercel_packages", "aws_sdk"):
        label = {"queue_workers": "queue/worker libs (separate ECS worker service)", "cron_libs": "in-process schedulers"}.get(k, k)
        a("| %s | %s |" % (label, ", ".join(d[k]) or "-"))
    a("| sharp | %s |" % (d.get("sharp") or "-"))
    a("")
    a("## Commands")
    a("")
    for k, v in r["commands"].get("package_json_scripts", {}).items():
        a("- package.json `%s`: `%s`" % (k, v))
    for k, v in r["commands"].get("procfile", {}).items():
        a("- Procfile `%s`: `%s`" % (k, v))
    for f, dd in r.get("dockerfiles", {}).items():
        a("- %s: FROM %s; EXPOSE %s; CMD %s; USER %s; HEALTHCHECK %s" % (f, ", ".join(dd["from"]) or "-", ", ".join(dd["expose"]) or "-", "; ".join(dd["cmd"]) or "-", ", ".join(dd["user"]) or "root", dd["healthcheck"]))
    if r.get("compose"):
        a("- %s services: %s" % (r["compose"]["file"], ", ".join(r["compose"]["services"]) or "-"))
    a("")
    a("## Platform markers")
    a("")
    a(", ".join("`%s`" % m for m in r["platform_markers"]) or "_none_")
    if r.get("railway_config"):
        a("")
        a("```json")
        a(json.dumps(r["railway_config"], indent=2)[:3000])
        a("```")
    if r.get("vercel_config"):
        a("")
        a("vercel.json: `%s`" % json.dumps(r["vercel_config"])[:1500])
    a("")
    if r["framework"]["primary"] == "nextjs" or r["nextjs"].get("config_file"):
        a("## Next.js")
        a("")
        n = r["nextjs"]
        for k in ("config_file", "output_standalone", "cacheHandler", "cacheMaxMemorySize", "images_remotePatterns", "rewrites", "redirects", "headers", "basePath", "deploymentId", "withPayload", "middleware_file", "proxy_file", "app_router", "pages_router"):
            a("- %s: %s" % (k, n.get(k)))
        for k in ("edge_runtime_files", "nodejs_runtime_files", "revalidateTag_files", "revalidatePath_files", "preferredRegion_files", "next_image_files", "use_cache_files", "unstable_cache_files", "waitUntil_files"):
            v = n.get(k) or []
            a("- %s (%d): %s" % (k, len(v), ", ".join("`%s`" % x for x in v[:10]) + (" ..." if len(v) > 10 else "")))
        if n.get("isr_revalidate_files"):
            a("- isr_revalidate_files: %s" % ", ".join("`%s`=%s" % kv for kv in list(n["isr_revalidate_files"].items())[:10]))
        if n.get("dynamic_files"):
            a("- dynamic_files: %s" % ", ".join("`%s`=%s" % kv for kv in list(n["dynamic_files"].items())[:10]))
        if r.get("vercel_imports"):
            a("- vercel imports: %s" % "; ".join("%s (%d files)" % (k, len(v)) for k, v in r["vercel_imports"].items()))
        a("")
    if r["payload"]["in_use"]:
        a("## Payload CMS")
        a("")
        a("- version: %s  db adapter: %s  storage: %s  config: %s" % (r["payload"]["version"], r["payload"]["db_adapter"], ", ".join(r["payload"]["storage_adapters"]) or "-", r["payload"]["config_file"]))
        a("")
    a("## Environment variable classification")
    a("")
    a("Where each class lives on AWS (names only; values never appear in this report):")
    a("")
    a("| class | destination | count | names |")
    a("|---|---|---|---|")
    ev = r["env_vars"]
    for c in ("secret", "public_buildtime", "config", "platform"):
        names = ev["by_class"].get(c, [])
        a("| %s | %s | %d | %s |" % (c, ev["classes"][c], len(names), ", ".join("`%s`" % n for n in names) or "-"))
    efc = ev.get("env_file_classification")
    if efc:
        a("")
        a("Names declared in `.env*` files (whether or not referenced in code):")
        a("")
        a("| class | count | names |")
        a("|---|---|---|")
        for c in ("secret", "public_buildtime", "config", "platform"):
            a("| %s | %d | %s |" % (c, len(efc.get(c, [])), ", ".join("`%s`" % n for n in efc.get(c, [])) or "-"))
    a("")
    a("## Environment variables referenced in code (%d)" % r["env_vars"]["count"])
    a("")
    a("| name | class | category | files |")
    a("|---|---|---|---|")
    for e in r["env_vars"]["references"]:
        a("| `%s` | %s | %s | %d |" % (e["name"], e["class"], e.get("category", "-"), e["files"]))
    a("")
    if r["env_vars"].get("env_file_names"):
        for f, names in r["env_vars"]["env_file_names"].items():
            a("- `%s` declares %d names" % (f, len(names)))
        if r["env_vars"].get("referenced_but_not_in_env_example"):
            a("- referenced in code but missing from .env files: %s" % ", ".join("`%s`" % x for x in r["env_vars"]["referenced_but_not_in_env_example"]))
        if r["env_vars"].get("in_env_example_but_unreferenced"):
            a("- in .env files but never referenced (may be read by a framework/SDK implicitly): %s" % ", ".join("`%s`" % x for x in r["env_vars"]["in_env_example_but_unreferenced"]))
    a("")
    a("## Hard-coded platform hostnames")
    a("")
    if r["hostnames"]:
        for label, hs in r["hostnames"].items():
            for h, files in hs.items():
                a("- `%s` in %s" % (h, ", ".join("`%s`" % f for f in files[:6]) + (" ..." if len(files) > 6 else "")))
    else:
        a("_none_")
    a("")
    a("## Ports, health, crons, webhooks")
    a("")
    pd = r.get("port_detection") or {}
    a("- recommended container port: %s" % (pd.get("recommended") or "unknown"))
    for port, srcs in (pd.get("declared") or {}).items():
        a("  - %s declared by: %s" % (port, "; ".join("%s (`%s`)" % (d["source"], d["detail"]) for d in srcs[:4])))
    a("- port literals in code: %s" % (", ".join("%s (%d files)" % (p, len(f)) for p, f in r["ports"].items()) or "none"))
    a("- reads $PORT: %s" % (pd.get("uses_PORT_env") or False))
    a("- health route files: %s" % (", ".join("`%s`" % f for f in r["health"]["route_files"]) or "none"))
    a("- health paths referenced: %s" % (", ".join("`%s`" % p for p in r["health"]["paths_referenced"]) or "none"))
    c = r["crons"]
    a("- crons: vercel.json=%s railway=%s railway.toml=%s railway.ts=%s github_actions=%s libs=%s" % (
        json.dumps(c["vercel_json"]) if c["vercel_json"] else "-", c["railway"] or "-", c["railway_toml"] or "-", c["railway_ts"] or "-",
        ", ".join("%s@%s" % (g["file"], g["schedule"]) for g in c["github_actions"]) or "-", ", ".join(c["in_process_libs"]) or "-"))
    a("- webhook routes/files: %s" % (", ".join("`%s`" % f for f in list(r["webhooks"])[:10]) or "none"))
    a("- pooling hints: %s" % (", ".join("`%s`" % f for f in list(r["pooling_hints"])[:10]) or "none"))
    a("- queue/worker libs: %s" % (", ".join(c.get("queue_worker_libs") or []) or "none"))
    a("- tests: present=%s runners=%s" % (r["tests"]["present"], ", ".join(r["tests"]["runners"]) or "-"))
    a("")
    a("## Security and storage findings")
    a("")
    tls = r.get("db_tls_verification_disabled") or {}
    a("- DB TLS verification disabled/weakened: %s" % ("; ".join("`%s` (%s)" % (f, ", ".join(l)) for f, l in list(tls.items())[:10]) or "none found"))
    a("- Twilio validateRequest(req.url): %s" % (", ".join("`%s`" % f for f in r.get("twilio_validate_request_req_url") or []) or "none found"))
    fsw = r.get("local_fs_writes") or {}
    a("- local filesystem writes (volume -> S3/EFS decision): %s" % ("; ".join("`%s` (%s)" % (f, ", ".join(l)) for f, l in list(fsw.items())[:10]) or "none found"))
    if r.get("vercel_node_version"):
        a("- Vercel node version (from --vercel-node): %s" % r["vercel_node_version"])
    a("")
    a("_%d code files scanned._" % r["stats"]["code_files_scanned"])
    a("")
    return "\n".join(L)


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description="Static codebase inventory for Railway/Vercel -> AWS migration (stdlib only).")
    ap.add_argument("repo", help="path to the application repository")
    ap.add_argument("--out", default="migration/inventory/codebase.json", help="JSON output path")
    ap.add_argument("--md", default="migration/inventory/CODEBASE.md", help="Markdown report path")
    ap.add_argument("--json-only", action="store_true", help="write only the JSON file (no Markdown)")
    ap.add_argument("--stdout", action="store_true", help="also print the Markdown report (or JSON with --json-only) to stdout")
    ap.add_argument("--vercel-node", default=None, metavar="VER|FILE",
                    help="Node version Vercel builds with (e.g. 24 or 24.x), or a path to the Vercel inventory SUMMARY.md / project JSON to read it from; compared with .nvmrc / engines.node")
    args = ap.parse_args(argv)

    if not os.path.isdir(args.repo):
        print("error: %s is not a directory" % args.repo, file=sys.stderr)
        return 2
    vercel_node = args.vercel_node
    if vercel_node and os.path.isfile(vercel_node):
        txt = read_text(vercel_node) or ""
        m = re.search(r"\bNode(?:\.js)?(?:\s*version)?\s*[:=]?\s*v?(\d+(?:\.x|\.\d+)*)", txt, re.IGNORECASE) or re.search(r"\"nodeVersion\"\s*:\s*\"(\d+(?:\.x)?)\"", txt)
        if not m:
            print("error: could not find a Node version in %s (pass the version directly, e.g. --vercel-node 24)" % vercel_node, file=sys.stderr)
            return 2
        vercel_node = m.group(1)
    elif vercel_node and not re.search(r"\d", vercel_node):
        print("error: --vercel-node expects a version like 24 / 24.x or an existing inventory file (got %r)" % vercel_node, file=sys.stderr)
        return 2
    result = scan(args.repo, vercel_node=vercel_node)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, sort_keys=False)
        f.write("\n")
    print("wrote %s (%d env var names, %d flags)" % (args.out, result["env_vars"]["count"], len(result["flags"])))
    if not args.json_only:
        md = to_markdown(result)
        os.makedirs(os.path.dirname(os.path.abspath(args.md)) or ".", exist_ok=True)
        with open(args.md, "w", encoding="utf-8") as f:
            f.write(md)
        print("wrote %s" % args.md)
        if args.stdout:
            print(md)
    elif args.stdout:
        print(json.dumps(result, indent=2))
    n_action = sum(1 for f in result["flags"] if f["severity"] == "action")
    print("framework=%s flags: %d action, %d total" % (result["framework"]["primary"], n_action, len(result["flags"])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
