"""Prepare the offline USB setup files before building the Windows client."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "third_party/android"


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_bundle(folder, phone=None):
    folder = Path(folder).resolve()
    document = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    assert {p["id"] for p in document["packages"]} == {"dexlink", "shizuku", "nightzuku"}
    files = {p["file"]: p["sha256"] for p in document["packages"]} | document["adb"]
    for name, expected in files.items():
        path = (folder / name).resolve()
        assert path.is_relative_to(folder) and digest(path) == expected, name
    for name in ("Shizuku-LICENSE.txt", "Nightzuku-LICENSE.txt"):
        assert (folder / "licenses" / name).is_file()
    assert (folder / "THIRD_PARTY_NOTICES.md").is_file()
    if phone is not None:
        assert digest(folder / "apks/DexLink-phone.apk") == digest(phone), "Bundled DexLink APK is stale"
    return document


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path)
    parser.add_argument("--phone", type=Path, default=ROOT / "app_phone/build/app/outputs/apk/release/app-release.apk")
    parser.add_argument("--shizuku", type=Path)
    parser.add_argument("--nightzuku", type=Path)
    args = parser.parse_args()
    sdk = args.sdk or Path(os.environ.get("ANDROID_HOME", "") or
                          Path(os.environ["LOCALAPPDATA"]) / "Android/sdk")
    build_tools = sorted((sdk / "build-tools").iterdir(), key=lambda p: [int(v) for v in re.findall(r"\d+", p.name)])[-1]
    aapt = build_tools / "aapt.exe"
    apksigner = build_tools / "lib/apksigner.jar"
    VENDOR.mkdir(parents=True, exist_ok=True)
    specifications = [
        ("dexlink", "DexLink 手机端", "io.dexlink.dex_phone", args.phone, "DexLink-phone.apk", None),
        ("shizuku", "Shizuku", "moe.shizuku.privileged.api", args.shizuku or VENDOR / "Shizuku.apk", "Shizuku.apk",
         "268b5590e868fb08bae7e0ac413564cd1ff88f5ccff74af9dbd0dc918e30db30"),
        ("nightzuku", "Nightzuku", "kerneldroid.nightzuku", args.nightzuku or VENDOR / "Nightzuku.apk", "Nightzuku.apk",
         "979d6f3eb2c27974ea35deb11a464c053c390511e575cf9a941be47308b60563"),
    ]
    document = {"format": 1, "packages": [], "adb": {}}
    bundle = ROOT / "app_pc/bundled"
    for id_, label, package, source, name, certificate in specifications:
        info = subprocess.check_output([str(aapt), "dump", "badging", str(source)], text=True, encoding="utf-8")
        header = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", info)
        assert header and header[1] == package, f"Unexpected package in {source}"
        signature = subprocess.check_output(["java", "-jar", str(apksigner), "verify", "--print-certs", str(source)],
                                            text=True, encoding="utf-8", stderr=subprocess.PIPE)
        if certificate:
            assert f"certificate SHA-256 digest: {certificate}" in signature, f"Unexpected signer: {source}"
            target = VENDOR / name
            if source.resolve() != target.resolve():
                shutil.copy2(source, target)
        target = bundle / "apks" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        document["packages"].append({
            "id": id_, "label": label, "package": package,
            "versionCode": int(header[2]), "version": header[3],
            "minSdk": int(re.search(r"sdkVersion:'(\d+)'", info)[1]),
            "file": f"apks/{name}", "sha256": digest(target),
        })
    for name in ("adb.exe", "AdbWinApi.dll", "AdbWinUsbApi.dll", "NOTICE.txt"):
        target = bundle / "adb" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(sdk / "platform-tools" / name, target)
        document["adb"][f"adb/{name}"] = digest(target)
    for name in ("Shizuku-LICENSE.txt", "Nightzuku-LICENSE.txt"):
        target = bundle / "licenses" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(VENDOR / name, target)
    shutil.copy2(VENDOR / "THIRD_PARTY_NOTICES.md", bundle / "THIRD_PARTY_NOTICES.md")
    (bundle / "manifest.json").write_text(json.dumps(document, ensure_ascii=False, indent=2), encoding="utf-8")
    verify_bundle(bundle, args.phone)
    print("Offline USB setup bundle prepared and verified:")
    for item in document["packages"]:
        print(f"{item['id']} {item['version']} {item['sha256']}")


if __name__ == "__main__":
    main()
