#!/usr/bin/env python3
"""Per-user preferences only; never changes power or network state."""
import argparse
import json
import os
from pathlib import Path
import tempfile


def validate(data):
    if not isinstance(data, dict) or set(data) != {'version', 'platform', 'network'}:
        raise ValueError('Invalid configuration fields')
    if type(data['version']) is not int or data['version'] != 1 or data['platform'] != 'macos':
        raise ValueError('Unsupported configuration version or platform')
    net = data['network']
    if not isinstance(net, dict) or set(net) != {'mode', 'ssid'}:
        raise ValueError('Invalid network configuration')
    if net['mode'] == 'existing':
        if net['ssid'] is not None:
            raise ValueError('Existing network mode requires null SSID')
    elif net['mode'] == 'hotspot':
        ssid = net['ssid']
        if not isinstance(ssid, str) or not ssid.strip() or len(ssid.encode('utf-8')) > 32 or any(c in ssid for c in '\r\n\0'):
            raise ValueError('SSID must be 1–32 UTF-8 bytes without CR, LF or NUL')
    else:
        raise ValueError('Unsupported network mode')
    return data


def read(path):
    if path.is_symlink():
        raise ValueError('Configuration must not be a symbolic link')
    if not path.exists():
        return {'state': 'missing'}
    return validate(json.loads(path.read_text(encoding='utf-8')))


def save(path, mode, ssid):
    data = validate({'version': 1, 'platform': 'macos', 'network': {'mode': mode, 'ssid': ssid}})
    read(path)  # Never silently overwrite a corrupt or future-version config.
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(prefix='.config-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as out:
            json.dump(data, out, ensure_ascii=False, indent=2)
            out.write('\n')
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['read', 'save'])
    parser.add_argument('--mode', choices=['existing', 'hotspot'])
    parser.add_argument('--ssid')
    parser.add_argument('--path', type=Path, default=Path.home() / 'Library/Application Support/AwakeSkill/config.json')
    args = parser.parse_args()
    try:
        result = read(args.path) if args.action == 'read' else save(args.path, args.mode, args.ssid)
    except (ValueError, OSError) as exc:
        parser.exit(1, f'Configuration error: {exc}\n')
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
