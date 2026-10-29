#!/usr/bin/env python3
"""Generate automatic or offline/manual App Store Connect export options."""
import argparse
import datetime
import hashlib
import pathlib
import plistlib
import re
import subprocess
import sys
import uuid


BUNDLE_ID = "art.malette.imic"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--team", required=True)
    parser.add_argument("--destination", choices=("export", "upload"), required=True)
    parser.add_argument("--profile", type=pathlib.Path)
    args = parser.parse_args()
    options = plistlib.loads(args.template.read_bytes())
    options.update(teamID=args.team, destination=args.destination)
    if args.profile:
        data = args.profile.read_bytes()
        decoded = subprocess.check_output(["security", "cms", "-D", "-i", str(args.profile)])
        profile = plistlib.loads(decoded)
        entitlement = profile.get("Entitlements", {})
        if args.team not in profile.get("TeamIdentifier", []):
            raise ValueError("描述文件团队不匹配")
        if not entitlement.get("application-identifier", "").endswith("." + BUNDLE_ID):
            raise ValueError("描述文件不属于 iMic 的显式 Bundle ID")
        if (entitlement.get("get-task-allow") is not False
                or entitlement.get("beta-reports-active") is not True
                or profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices")):
            raise ValueError("需要 App Store Connect 分发描述文件，不能使用开发、Ad Hoc 或企业描述文件")
        now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
        if profile["ExpirationDate"] <= now:
            raise ValueError("描述文件已过期")
        profile_uuid = str(uuid.UUID(profile["UUID"])).upper()
        permitted = {hashlib.sha1(cert).hexdigest().upper() for cert in profile["DeveloperCertificates"]}
        identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
        signing_hash = None
        for line in identities.splitlines():
            match = re.search(r'([0-9A-F]{40}) "Apple Distribution: .*\(' + re.escape(args.team) + r'\)"', line)
            if match and match[1] in permitted:
                signing_hash = match[1]
                break
        if signing_hash is None:
            raise ValueError("描述文件未包含本机可用且带私钥的 Apple Distribution 证书")
        # A provisioning profile contains public certificate material, not the private key.
        directory = pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
        directory.mkdir(parents=True, exist_ok=True)
        installed = directory / (profile_uuid + ".mobileprovision")
        if installed.exists() and installed.read_bytes() != data:
            raise ValueError("同 UUID 的描述文件已存在且内容不同，请先在 Xcode 核实")
        installed.write_bytes(data)
        options.update(signingStyle="manual", signingCertificate=signing_hash,
                       provisioningProfiles={BUNDLE_ID: profile_uuid})
        print(f"使用已校验的 App Store 描述文件：{profile_uuid}（团队 {args.team}）")
    args.output.write_bytes(plistlib.dumps(options))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        print(f"生成分发配置失败：{error}", file=sys.stderr)
        sys.exit(1)
