#!/usr/bin/env python3
"""Check the actual Release bundle before handing it to Xcode/App Store Connect."""
import argparse
import datetime
import json
import pathlib
import plistlib
import subprocess
import sys


BUNDLE_ID = "art.malette.imic"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load(path):
    with path.open("rb") as stream:
        return plistlib.load(stream)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--team", required=True)
    parser.add_argument("--require-distribution", action="store_true")
    args = parser.parse_args()
    app = args.app
    info = load(app / "Info.plist")
    require(info.get("CFBundleIdentifier") == BUNDLE_ID, "Bundle ID 不一致")
    require(info.get("CFBundleShortVersionString") == args.version, "版本不一致")
    require(info.get("CFBundleVersion") == args.build, "Build 不一致")
    require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"], "必须是真机 iOS 产物")
    require(info.get("MinimumOSVersion") == "17.0", "最低版本应为 iOS 17.0")
    require(info.get("UIDeviceFamily") == [1], "目标设备应为 iPhone")
    for key in ("NSMicrophoneUsageDescription", "NSLocalNetworkUsageDescription",
                "NSSpeechRecognitionUsageDescription", "NSBluetoothAlwaysUsageDescription"):
        require(bool(info.get(key)), f"缺少权限说明：{key}")
    require(info.get("NSBonjourServices") == ["_imic._tcp"], "Bonjour 服务声明不一致")
    privacy = load(app / "PrivacyInfo.xcprivacy")
    require(privacy.get("NSPrivacyTracking") is False, "不得启用跟踪")
    reasons = {item["NSPrivacyAccessedAPIType"]: item["NSPrivacyAccessedAPITypeReasons"]
               for item in privacy.get("NSPrivacyAccessedAPITypes", [])}
    for category, reason in (("UserDefaults", "CA92.1"), ("SystemBootTime", "35F9.1"),
                            ("FileTimestamp", "C617.1")):
        require(reason in reasons.get("NSPrivacyAccessedAPICategory" + category, []),
                f"缺少隐私用途：{category}/{reason}")
    executable = app / info["CFBundleExecutable"]
    binary = executable.read_bytes()
    for flag in (b"--debug-", b"--ui-preview=", b"--waveform-replay=", b"--show-result"):
        require(flag not in binary, f"Release 包含调试入口：{flag.decode()}")
    build_info = subprocess.check_output(["xcrun", "vtool", "-show-build", str(executable)], text=True)
    platforms = [line.split()[1] for line in build_info.splitlines()
                 if line.strip().startswith("platform ")]
    require(platforms == ["IOS"], "Mach-O 平台必须为 IOS")
    require((app / "Assets.car").exists(), "缺少资产目录")
    require(bool(info.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon")), "缺少 App 图标")
    require((app / "LICENSE").exists(), "缺少许可证")
    require((app / "THIRD_PARTY_NOTICES.md").exists(), "缺少第三方说明")
    require((app / "licenses" / "PHOSPHOR-LICENSE.txt").exists(), "缺少图标许可证")
    signature = subprocess.run(["codesign", "-dvv", str(app)], capture_output=True, text=True)
    profile_path = app / "embedded.mobileprovision"
    profile = None
    if profile_path.exists():
        profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(profile_path)]))
        require(args.team in profile.get("TeamIdentifier", []), "描述文件团队不一致")
    if signature.returncode == 0:
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        require(f"TeamIdentifier={args.team}" in signature.stderr, "签名团队不一致")
    if args.require_distribution:
        require(signature.returncode == 0, "分发 IPA 未签名")
        require(profile is not None, "缺少分发描述文件")
        require("Authority=Apple Distribution:" in signature.stderr, "必须使用 Apple Distribution 签名")
        entitlements = profile.get("Entitlements", {})
        require(entitlements.get("get-task-allow") is False, "分发包不能允许调试")
        require(entitlements.get("beta-reports-active") is True, "不是 App Store/TestFlight 描述文件")
        require(not profile.get("ProvisionedDevices"), "不能使用开发或 Ad Hoc 描述文件")
        require(not profile.get("ProvisionsAllDevices"), "不能使用企业描述文件")
        require(profile["ExpirationDate"] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
                "描述文件已过期")
        signed = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)],
                                capture_output=True, check=True)
        embedded = plistlib.loads(signed.stdout)
        require(embedded.get("get-task-allow", False) is False, "签名权利允许调试")
        require(embedded.get("application-identifier") == entitlements.get("application-identifier"),
                "签名权利与描述文件不一致")
    report = {"version": args.version, "build": args.build, "bundleID": info["CFBundleIdentifier"],
              "team": args.team, "signed": signature.returncode == 0,
              "distributionVerified": args.require_distribution,
              "privacyManifest": "passed", "releaseDebugEntrypoints": "absent", "platform": "IOS"}
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        print(f"TestFlight 校验失败：{error}", file=sys.stderr)
        sys.exit(1)
