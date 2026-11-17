"""Package existing Android and Windows release builds without local logs."""
from pathlib import Path
import argparse
import hashlib
import shutil
import zipfile

from prepare_usb_bundle import verify_bundle

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phone", type=Path, default=ROOT / "app_phone/build/app/outputs/flutter-apk/app-release.apk")
    parser.add_argument("--windows", type=Path, default=ROOT / "app_pc/build/windows/x64/runner/Release")
    parser.add_argument("--output", type=Path, default=ROOT / "release-assets")
    args = parser.parse_args()
    phone, windows, output = args.phone.resolve(), args.windows.resolve(), args.output.resolve()
    if not phone.is_file() or not (windows / "dex_pc.exe").is_file():
        parser.error("Build Android and Windows release targets first.")
    verify_bundle(windows / "support", phone)
    output.mkdir(parents=True, exist_ok=True)
    apk = output / "DexLink-phone.apk"
    archive = output / "DexLink-win64.zip"
    checksums = output / "SHA256SUMS.txt"
    if any(path.exists() for path in (apk, archive, checksums)):
        parser.error("Output already contains release files; choose a new --output directory.")

    files = [windows / "dex_pc.exe", windows / "native_assets.json"]
    files += sorted(windows.glob("*.dll"))
    for directory in ("data", "support"):
        files += sorted(path for path in (windows / directory).rglob("*") if path.is_file())
    unwanted = {".log", ".err", ".out", ".pid", ".h264", ".rgba", ".mjpg"}
    files = [path for path in files if path.is_file() and path.suffix.lower() not in unwanted]

    shutil.copy2(phone, apk)
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as package:
        for source in files:
            package.write(source, "DexLink-win64/" + source.relative_to(windows).as_posix())
        for name in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md"):
            package.write(ROOT / name, "DexLink-win64/" + name)
            shutil.copy2(ROOT / name, output / name)
        for source in sorted((ROOT / "third_party/android").glob("*.txt")):
            shutil.copy2(source, output / source.name)
        shutil.copy2(ROOT / "third_party/android/THIRD_PARTY_NOTICES.md", output / "OFFLINE_COMPONENT_NOTICES.md")

    with zipfile.ZipFile(archive) as package:
        assert package.testzip() is None, "Archive integrity check failed"
        for source in files:
            assert package.read("DexLink-win64/" + source.relative_to(windows).as_posix()) == source.read_bytes()
    with zipfile.ZipFile(apk) as package:
        assert package.testzip() is None, "APK integrity check failed"

    names = sorted(path for path in output.iterdir() if path.is_file())
    lines = [f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}" for path in names]
    checksums.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Packaged {len(files)} Windows runtime files in {output}")
    print(checksums.read_text(encoding="utf-8"))


if __name__ == "__main__":
    main()
