#!/usr/bin/env python3
"""Package an unsigned archive and tracked source without local signing material."""
import argparse
import hashlib
import pathlib
import subprocess
import zipfile

FORBIDDEN_PARTS = {'.git', '.claude', 'build', '.build', 'DerivedData',
                   '_CodeSignature', 'Certificates', '__MACOSX'}
FORBIDDEN_SUFFIXES = {'.p12', '.pfx', '.pem', '.key', '.cer', '.crt',
                      '.mobileprovision', '.provisionprofile', '.certSigningRequest'}


def checked_data(path, relative):
    if path.is_symlink():
        raise ValueError(f'Refusing symlink: {relative}')
    if (FORBIDDEN_PARTS.intersection(relative.parts)
            or relative.suffix.lower() in {s.lower() for s in FORBIDDEN_SUFFIXES}
            or relative.name.startswith('.env')
            or ('sparkle' in relative.name.lower() and 'backup' in relative.name.lower())):
        raise ValueError(f'Refusing local/signing material: {relative}')
    data = path.read_bytes()
    if b'PRIVATE' + b' KEY-----' in data:
        raise ValueError(f'Refusing private key content: {relative}')
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=pathlib.Path, required=True)
    parser.add_argument('--archive', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    app = args.archive / 'Products/Applications/iMic.app'
    signature = subprocess.run(['codesign', '-d', str(app)], capture_output=True)
    if signature.returncode == 0 or (app / 'embedded.mobileprovision').exists():
        raise ValueError('Handoff requires an unsigned archive without a profile')
    # Only committed content: no untracked files, ignored credentials, or local patches.
    if subprocess.check_output(['git', '-C', str(args.root), 'status', '--porcelain', '--untracked-files=no']):
        raise ValueError('Commit tracked changes before packaging the handoff')
    paths = subprocess.check_output(['git', '-C', str(args.root), 'ls-files', '-z']).decode().split('\0')
    entries = {}
    modes = {}
    for name in filter(None, paths):
        relative = pathlib.Path(name)
        entries['Source/' + name] = checked_data(args.root / relative, relative)
        modes['Source/' + name] = (args.root / relative).stat().st_mode
    for path in sorted(args.archive.rglob('*')):
        if path.is_file() or path.is_symlink():
            relative = path.relative_to(args.archive)
            name = 'iOS/iMic.xcarchive/' + relative.as_posix()
            entries[name] = checked_data(path, relative)
            modes[name] = path.stat().st_mode
    # Match every tracked build input to the actual isolated archive source snapshot.
    # Generated icons/project are reproduced by archive-unsigned, so compare code,
    # project settings and source resources before claiming a matching revision.
    with zipfile.ZipFile(args.archive.parent / 'source.zip') as snapshot:
        for item in snapshot.infolist():
            relative = pathlib.PurePosixPath(item.filename)
            if len(relative.parts) < 2 or '__MACOSX' in relative.parts or item.is_dir():
                continue
            name = pathlib.PurePosixPath(*relative.parts[1:]).as_posix()
            if name.startswith('ios/iMic.xcodeproj/') or name.startswith('ios/iMic/Assets.xcassets/AppIcon.appiconset/'):
                continue
            if 'Source/' + name in entries and snapshot.read(item) != entries['Source/' + name]:
                raise ValueError(f'Archive source differs from committed source: {name}')
    entries['SOURCE-REVISION.txt'] = subprocess.check_output(['git', '-C', str(args.root), 'rev-parse', 'HEAD'])
    entries['README.txt'] = (
        'Unsigned iMic TestFlight handoff. No signing or upload has been performed.\n'
        'See Source/docs/TESTFLIGHT-HANDOFF.md for team setup and instructions.\n'
        'cd Source\n'
        'IMIC_TESTFLIGHT_DIR=../iOS ./scripts/testflight.sh check\n'
        'IMIC_TESTFLIGHT_DIR=../iOS IMIC_PROFILE_PATH=/absolute/new.mobileprovision ./scripts/testflight.sh export\n'
        'IMIC_TESTFLIGHT_DIR=../iOS IMIC_PROFILE_PATH=/absolute/new.mobileprovision ./scripts/testflight.sh upload\n'
    ).encode()
    manifest = ''.join(f'{hashlib.sha256(data).hexdigest()}  {name}\n' for name, data in sorted(entries.items()))
    entries['MANIFEST.sha256'] = manifest.encode()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, 'x', compression=zipfile.ZIP_DEFLATED) as package:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo(name)
            info.compress_type = zipfile.ZIP_DEFLATED
            executable = modes.get(name, 0) & 0o111
            info.external_attr = (0o100755 if executable else 0o100644) << 16
            package.writestr(info, data)
    listing = args.output.with_suffix('.contents.txt')
    listing.write_text('\n'.join(sorted(entries)) + '\n')
    digest = hashlib.sha256(args.output.read_bytes()).hexdigest()
    args.output.with_suffix('.sha256').write_text(f'{digest}  {args.output.name}\n')
    print(f'{args.output}\nSize: {args.output.stat().st_size} bytes\nSHA-256: {digest}\nContents: {listing}')


if __name__ == '__main__':
    main()
