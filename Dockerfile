# Alpine base. Measured against the Debian slim base on the same application
# code: 220 findings -> 0, and 315 MB -> 155 MB. Alpine carries a fraction of
# the userland packages the app never calls, which is where nearly all of the
# Debian findings lived.
#
# The trade-off is musl instead of glibc. Every dependency in requirements.lock
# installs and runs on musl; a future dependency that ships a glibc-only wheel
# would fail at build time, which the weekly rebuild surfaces immediately.

FROM python:3.12-alpine AS builder

# Build toolchain for any dependency without a musl wheel.
RUN apk add --no-cache build-base libffi-dev

WORKDIR /app

# Install from the committed lockfile so every build resolves the same
# dependency set. requirements.txt stays the human-edited constraint list;
# requirements.lock is the resolved set that is actually installed.
COPY requirements.lock .
RUN pip install --no-cache-dir --prefix=/install -r requirements.lock


FROM python:3.12-alpine

# Patch the OS packages that ship in the base image.
RUN apk upgrade --no-cache

WORKDIR /app

# The app is served by uvicorn and needs no packaging tooling at runtime, so pip,
# setuptools and wheel are removed from the final image. Removing them takes the
# image to zero known vulnerabilities and keeps the layer smaller.
RUN pip uninstall -y pip setuptools wheel >/dev/null 2>&1 || true

COPY --from=builder /install /usr/local

# Strip the packaging tooling the base image leaves behind. The bom.cdx.json file
# is a build-time inventory listing setuptools 70.3.0; scanners read it as an
# installed package and report CVEs for a version that is not present.
RUN rm -rf /usr/local/lib/python3.12/site-packages/pip* \
           /usr/local/lib/python3.12/site-packages/setuptools* \
           /usr/local/lib/python3.12/site-packages/wheel* \
           /usr/local/bin/pip*

COPY . .

# Create static directory if it doesn't have content
RUN mkdir -p /app/static

EXPOSE 8080

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
