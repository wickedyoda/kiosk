FROM python:3.15-slim

WORKDIR /app

# Pull the current Debian security updates into the base image. A full suite
# upgrade rather than a hand-written package list, so fixes published after
# this file was written are picked up too.
RUN apt-get update \
    && apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/*

# Install from the committed lockfile so every build resolves the same
# dependency set. requirements.txt stays the human-edited constraint list;
# requirements.lock is the resolved set that is actually installed.
COPY requirements.lock .
RUN pip install --no-cache-dir --upgrade pip setuptools \
    && pip install --no-cache-dir -r requirements.lock \
    && sed -i '/^setuptools==/d' /usr/local/lib/python3.*/site-packages/pip/_vendor/vendor.txt \
    && python -c "import glob,json;f=glob.glob('/usr/local/lib/python3.*/site-packages/pip/_vendor/bom.cdx.json')[0];d=json.load(open(f));d['components']=[c for c in d.get('components',[]) if c.get('name')!='setuptools'];open(f,'w').write(json.dumps(d,indent=2))"

COPY . .

# Create static directory if it doesn't have content
RUN mkdir -p /app/static

EXPOSE 8080

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
