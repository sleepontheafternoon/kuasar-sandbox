"""Transport the already built preparation image to runtime-only E2E groups."""
import argparse
import gzip
import json
from pathlib import Path
import shutil
import subprocess

import artifacts


def create(workspace, archive):
    provenance = json.loads((workspace / 'provenance.json').read_text())
    environment = provenance['preparation_environment']
    artifacts.check_clean_environment(environment)
    artifacts.require(not archive.exists(), 'runtime archive output must be fresh')
    archive.parent.mkdir(parents=True, exist_ok=True)
    with subprocess.Popen(['docker', 'save', environment['image_id']], stdout=subprocess.PIPE) as process:
        with gzip.open(archive, 'wb', compresslevel=1) as output:
            shutil.copyfileobj(process.stdout, output)
        artifacts.require(process.wait() == 0, 'cannot export the selected runtime image')
    environment['archive_sha256'] = artifacts.digest(archive)
    (workspace / 'provenance.json').write_bytes(artifacts.canonical(provenance) + b'\n')


def load(archive, provenance):
    environment = provenance['preparation_environment']
    artifacts.check_clean_environment(environment)
    artifacts.require(archive.is_file() and not archive.is_symlink() and
                      artifacts.digest(archive) == environment.get('archive_sha256'), 'runtime image archive identity mismatch')
    subprocess.run(['docker', 'load', '--input', str(archive)], check=True)
    image = json.loads(subprocess.check_output(['docker', 'image', 'inspect', environment['image_id']], text=True))
    artifacts.require(len(image) == 1 and image[0]['Id'] == environment['image_id'] and
                      image[0]['Os'] == 'linux' and
                      image[0]['Architecture'] == {'x86_64': 'amd64', 'aarch64': 'arm64'}[provenance['arch']],
                      'transported runtime image/config/architecture mismatch')
    return environment['image_id']


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    args = parser.parse_args()
    create(args.workspace, args.archive)
