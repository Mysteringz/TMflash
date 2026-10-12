#!/usr/bin/env python3
"""Build a self-contained, universal TMflash disk image on a developer's Mac.

Only packaging needs Xcode, Python and gh. Recipients need none of them.
Firmware comes from the latest published TMsense release; esptool is pinned
to the official 4.x standalone binaries, matching the existing flash engine.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from release_manifest import write_manifest

ROOT = Path(__file__).resolve().parent.parent
TOOLS = {
    'arm64': ('arm64', 'b9a0b7cd9fc1c77e072682b046bf7373537dbd33aa05de628e866d6403cee64b'),
    'x86_64': ('amd64', '85aac2a521fa51539add368c84a3e4ada6695f84743303877b632286658ed44e'),
}
BOOT_SELECTOR_SHA256 = 'f94c5d786a7a8fab06ac5d10e33bf37711a6697636dc037559ea19cc410a17f0'


def run(*command, **kwargs):
    subprocess.run([str(part) for part in command], check=True, **kwargs)


def read_command(*command):
    return subprocess.check_output([str(part) for part in command], text=True).strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as data:
        for chunk in iter(lambda: data.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def get_release(cache):
    release = json.loads(read_command('gh', 'release', 'view', '-R', 'Mysteringz/TMsense', '--json', 'tagName,assets'))
    tag = release['tagName']
    if not re.fullmatch(r'v\d+\.\d+(?:\.\d+)?', tag):
        raise RuntimeError('the latest TMsense release has an unsupported tag')
    directory = cache / 'firmware' / tag
    directory.mkdir(parents=True, exist_ok=True)
    required = ['tmflash-manifest.json', 'bootloader.bin', 'partitions.bin', 'firmware.bin']
    assets = {asset['name']: asset for asset in release['assets']}
    for name in required:
        if name not in assets:
            raise RuntimeError('the latest TMsense release is missing ' + name)
        path = directory / name
        if not path.exists():
            run('gh', 'release', 'download', tag, '-R', 'Mysteringz/TMsense', '--dir', directory, '--pattern', name)
        if path.stat().st_size != assets[name]['size']:
            raise RuntimeError('cached release size differs from GitHub: ' + str(path))
    manifest = json.loads((directory / required[0]).read_text())
    if manifest.get('tag') != tag:
        raise RuntimeError('the release tag differs from its manifest')
    if {image['name'] for image in manifest['files']} != set(required[1:]) or len(manifest['files']) != 3:
        raise RuntimeError('the firmware manifest lists unexpected images')
    for image in manifest['files']:
        path = directory / image['name']
        if path.stat().st_size != image['size'] or sha256(path) != image['sha256']:
            raise RuntimeError('cached release failed SHA-256: ' + str(path))
    selector = directory / 'boot_app0.bin'
    if not selector.exists():
        with urllib.request.urlopen('https://raw.githubusercontent.com/espressif/arduino-esp32/2.0.17/tools/partitions/boot_app0.bin', timeout=60) as response:
            selector.write_bytes(response.read(8193))
    if selector.stat().st_size != 8192 or sha256(selector) != BOOT_SELECTOR_SHA256:
        raise RuntimeError('the standard Espressif boot selector failed SHA-256')
    return directory, manifest


def copy_tools(cache, resources):
    provenance = []
    for arch, (upstream_arch, expected_hash) in TOOLS.items():
        archive = cache / 'esptool' / ('esptool-v4.11.0-macos-' + upstream_arch + '.tar.gz')
        archive.parent.mkdir(parents=True, exist_ok=True)
        if not archive.exists():
            run('gh', 'release', 'download', 'v4.11.0', '-R', 'espressif/esptool', '--dir', archive.parent, '--pattern', archive.name)
        if sha256(archive) != expected_hash:
            raise RuntimeError('esptool download failed SHA-256: ' + str(archive))
        target = resources / 'Tools' / ('esptool-' + arch)
        target.mkdir(parents=True)
        with tarfile.open(archive) as package:
            prefix = 'esptool-macos-' + upstream_arch + '/'
            for name in ['esptool', 'LICENSE', 'README.md']:
                member = package.getmember(prefix + name)
                if not member.isfile():
                    raise RuntimeError('unexpected esptool archive member')
                with package.extractfile(member) as contents, (target / name).open('wb') as output:
                    shutil.copyfileobj(contents, output)
            (target / 'esptool').chmod(0o755)
        actual_arch = read_command('lipo', '-archs', target / 'esptool')
        if arch not in actual_arch.split():
            raise RuntimeError('the bundled esptool has the wrong architecture')
        provenance.append({'architecture': arch, 'version': '4.11.0', 'archive': archive.name, 'sha256': expected_hash,
                           'source': 'https://github.com/espressif/esptool/releases/tag/v4.11.0'})
    legal = resources / 'Licenses'
    legal.mkdir()
    source = cache / 'esptool' / 'esptool-4.11.0-source.tar.gz'
    if not source.exists():
        with urllib.request.urlopen('https://api.github.com/repos/espressif/esptool/tarball/v4.11.0', timeout=60) as response, source.open('wb') as output:
            shutil.copyfileobj(response, output)
    shutil.copyfile(source, legal / source.name)
    (legal / 'README.txt').write_text(
        'Espressif esptool 4.11.0 is bundled unmodified as a separate executable.\n'
        'Its GPL-2.0 license and upstream README are beside each executable;\n'
        'its corresponding source archive is included here.\n'
        'The standalone executables carry their Python runtime and dependencies.\n'
        'Upstream build and dependency information: https://github.com/espressif/esptool/tree/v4.11.0\n'
        'The standard boot selector comes from Espressif arduino-esp32 2.0.17:\n'
        'https://github.com/espressif/arduino-esp32/blob/2.0.17/tools/partitions/boot_app0.bin\n'
    )
    return provenance


def sign(path, identity, entitlements=None):
    command = ['codesign', '--force', '--sign', identity]
    if identity != '-':
        command += ['--options', 'runtime', '--timestamp']
        if entitlements:
            command += ['--entitlements', str(entitlements)]
    run(*command, path)


def notarize(path, profile):
    result = json.loads(read_command('xcrun', 'notarytool', 'submit', path, '--keychain-profile', profile, '--wait', '--output-format', 'json'))
    if result.get('status') != 'Accepted':
        raise RuntimeError('Apple rejected notarization; inspect notarytool log for submission ' + result.get('id', '?'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='DMG path (default: build/TMflash-<version>-universal.dmg)')
    parser.add_argument('--sign-identity', default='-', help='Developer ID Application identity; default is ad-hoc signing')
    parser.add_argument('--notary-profile', help='existing notarytool Keychain profile; requires Developer ID signing')
    args = parser.parse_args()
    if args.notary_profile and args.sign_identity == '-':
        parser.error('--notary-profile requires --sign-identity')
    os.chdir(ROOT)
    cache = ROOT / 'build' / 'portable-assets'
    firmware, manifest = get_release(cache)
    run(ROOT / 'scripts/build-app.sh', 'universal')
    with tempfile.TemporaryDirectory(prefix='tmflash-dmg-', dir='/private/tmp') as temporary:
        staging = Path(temporary) / 'image'
        staging.mkdir()
        app = staging / 'TMflash.app'
        run('ditto', '--norsrc', '--noextattr', ROOT / 'build/TMflash.app', app)
        resources = app / 'Contents/Resources'
        shutil.copytree(firmware, resources / 'Firmware')
        tools = copy_tools(cache, resources)
        plist_path = app / 'Contents/Info.plist'
        info = plistlib.loads(plist_path.read_bytes())
        info.pop('TMSenseDir', None)
        plist_path.write_bytes(plistlib.dumps(info))
        version = info['CFBundleShortVersionString']
        (resources / 'distribution.json').write_text(json.dumps({
            'appVersion': version, 'sourceCommit': read_command('git', 'rev-parse', 'HEAD'),
            'sourceModified': bool(read_command('git', 'status', '--porcelain')), 'firmware': manifest,
            'flashingTools': tools,
        }, indent=2) + '\n')
        run('xattr', '-cr', app)
        for arch in TOOLS:
            tool = resources / 'Tools' / ('esptool-' + arch) / 'esptool'
            sign(tool, args.sign_identity, ROOT / 'scripts/esptool-entitlements.plist')
            run('codesign', '--verify', '--strict', tool)
        sign(app / 'Contents/MacOS/tmflash-cli', args.sign_identity)
        sign(app, args.sign_identity)
        run('codesign', '--verify', '--deep', '--strict', app)
        for executable in ['TMflash', 'tmflash-cli']:
            archs = set(read_command('lipo', '-archs', app / 'Contents/MacOS' / executable).split())
            if archs != {'arm64', 'x86_64'}:
                raise RuntimeError(executable + ' is not universal')
        run(app / 'Contents/MacOS/tmflash-cli', 'firmware')
        native_arch = 'arm64' if read_command('uname', '-m') == 'arm64' else 'x86_64'
        run(resources / 'Tools' / ('esptool-' + native_arch) / 'esptool', 'version')
        if args.notary_profile:
            archive = Path(temporary) / 'TMflash-notarize.zip'
            run('ditto', '-c', '-k', '--keepParent', app, archive)
            notarize(archive, args.notary_profile)
            run('xcrun', 'stapler', 'staple', app)
        (staging / 'Applications').symlink_to('/Applications', target_is_directory=True)
        (staging / 'Install TMflash.txt').write_text(
            'TMflash ' + version + ' — black lightning logo\n\n'
            '1. Drag TMflash.app onto the Applications shortcut.\n'
            '2. Eject this disk image. Open TMflash from Applications.\n'
            '3. Plug in a Heltec WiFi LoRa 32 V3 and follow the setup steps.\n\n'
            'Requires macOS 14 or later, on an Intel or Apple Silicon Mac.\n'
            'Includes ' + manifest['version'] + ' and both native flashing tools.\n'
            'No Python, PlatformIO, Xcode, Homebrew or firmware source is needed.\n'
            'Flashing the included firmware works offline. Account sign-in and\n'
            'cloud adoption require an internet connection and account access.\n'
            'LoRa is settings-only; LoRa transmission is not implemented.\n'
            'Saved node settings and the boot counter are preserved.\n\n'
            + ('Apple Developer ID signed and notarized.\n' if args.notary_profile else
               'This build is not notarized. If macOS says the developer cannot\n'
               'be verified, try opening it once, then use System Settings >\n'
               'Privacy & Security > Open Anyway only if you trust its source.\n'
               'https://support.apple.com/en-us/102445\n')
        )
        output = (args.output or ROOT / 'build' / ('TMflash-' + version + '-universal.dmg')).resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        run('hdiutil', 'create', '-ov', '-volname', 'TMflash', '-srcfolder', staging, '-fs', 'HFS+', '-format', 'UDZO', output)
        if args.sign_identity != '-':
            sign(output, args.sign_identity)
        if args.notary_profile:
            notarize(output, args.notary_profile)
            run('xcrun', 'stapler', 'staple', output)
        run('hdiutil', 'verify', output)
        output.with_suffix('.dmg.sha256').write_text(sha256(output) + '  ' + output.name + '\n')
        write_manifest(output, version, read_command('git', 'rev-parse', 'HEAD'),
                       bool(read_command('git', 'status', '--porcelain')), info['LSMinimumSystemVersion'],
                       manifest['version'], bool(args.notary_profile))
        print('Created ' + str(output))
        print('Firmware: ' + manifest['version'] + '; macOS 14+; Intel and Apple Silicon')
        print('Notarized: ' + str(bool(args.notary_profile)))


if __name__ == '__main__':
    main()
