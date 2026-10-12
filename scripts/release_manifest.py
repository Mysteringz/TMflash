"""The public manifest TMedge reads beside each published TMflash DMG."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re


def write_manifest(dmg, version, commit, modified, minimum_macos, firmware, notarized):
    dmg = Path(dmg)
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('a release needs an app version and full source commit')
    if dmg.name != 'TMflash-' + version + '-universal.dmg':
        raise ValueError('the DMG filename must identify the version and universal build')
    if not re.fullmatch(r'\d+\.\d+', minimum_macos) or not re.fullmatch(r'tmsense-\d+\.\d+(?:\.\d+)?', firmware):
        raise ValueError('a release needs its macOS requirement and included firmware version')
    size = dmg.stat().st_size
    if size < 512 or size > 128 * 1024 * 1024:
        raise ValueError('the DMG has an unsupported size')
    digest = hashlib.sha256()
    with dmg.open('rb') as contents:
        for chunk in iter(lambda: contents.read(1024 * 1024), b''):
            digest.update(chunk)
        contents.seek(-512, 2)
        if contents.read(4) != b'koly':
            raise ValueError('the file is not a UDIF disk image')
    manifest = {
        'format': 1, 'project': 'TMflash', 'version': version, 'tag': 'build-' + commit,
        'commit': commit, 'sourceModified': bool(modified), 'filename': dmg.name,
        'size': size, 'sha256': digest.hexdigest(), 'minimumMacOS': minimum_macos,
        'architectures': ['arm64', 'x86_64'], 'firmware': firmware,
        'notarized': bool(notarized), 'builtAt': datetime.now(timezone.utc).isoformat(),
    }
    (dmg.parent / 'tmflash-app.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest
