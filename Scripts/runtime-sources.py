"""Package exact GPL/LGPL dependency sources for the separate USB executable."""
from concurrent.futures import ThreadPoolExecutor
import importlib.metadata
import json
from pathlib import Path
import tarfile
import urllib.request

root = Path('build-usb-source')
root.mkdir(exist_ok=True)
items = []
for dist in importlib.metadata.distributions():
    license = dist.metadata.get('License-Expression') or dist.metadata.get('License') or ''
    if 'GPL' in license or 'GENERAL PUBLIC LICENSE' in license:
        items.append((dist.metadata['Name'], dist.version))

def download(item):
    name, version = item
    with urllib.request.urlopen(f'https://pypi.org/pypi/{name}/{version}/json') as response:
        metadata = json.load(response)
    source = next(f for f in metadata['urls'] if f['packagetype'] == 'sdist')
    destination = root / source['filename']
    urllib.request.urlretrieve(source['url'], destination)
    import hashlib
    if hashlib.sha256(destination.read_bytes()).hexdigest() != source['digests']['sha256']:
        raise ValueError('Dependency source hash mismatch')
    return destination

with ThreadPoolExecutor(max_workers=4) as workers:
    sources = list(workers.map(download, items))
with tarfile.open(root / 'GPL-dependency-sources.tar.gz', 'w:gz') as archive:
    for source in sources: archive.add(source, arcname=source.name)
print(f'Packaged {len(sources)} exact GPL/LGPL source distributions.')
