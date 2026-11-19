#!/usr/bin/env python3
"""Build a relocatable, self-contained Apple Silicon disk image. No user data."""
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / ".local/distribution-downloads"
DISK = ROOT / "build/shareable/disk"
APP = DISK / "Диалог.app"
RESOURCES = APP / "Contents/Resources"
RUNTIME = RESOURCES / "Runtime"
LOCK = json.loads((ROOT / "scripts/distribution-runtime.json").read_text())
IGNORES = shutil.ignore_patterns("__pycache__", "*.pyc", ".DS_Store", ".git", ".pytest_cache")


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def download(spec):
    CACHE.mkdir(parents=True, exist_ok=True)
    target = CACHE / Path(urllib.parse.urlparse(spec["url"]).path).name
    if "sha256" in spec:
        algorithm, expected = "sha256", bytes.fromhex(spec["sha256"])
    else:
        algorithm, encoded = spec["integrity"].split("-", 1)
        expected = base64.b64decode(encoded)

    def valid():
        if not target.exists():
            return False
        digest = hashlib.new(algorithm)
        with target.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        return digest.digest() == expected

    if not valid():
        print("Downloading " + target.name, flush=True)
        temporary = target.with_suffix(target.suffix + ".partial")
        request = urllib.request.Request(spec["url"], headers={"User-Agent": "Dialog-Distribution-Builder"})
        with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as destination:
            shutil.copyfileobj(response, destination)
        temporary.replace(target)
        if not valid():
            target.unlink()
            raise RuntimeError("Checksum mismatch: " + target.name)
    return target


def copytree(source, destination):
    shutil.copytree(source, destination, symlinks=True, ignore=IGNORES, dirs_exist_ok=True)


def macho_files():
    magic = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
    for item in APP.rglob("*"):
        if not item.is_file() or item.is_symlink():
            continue
        with item.open("rb") as source:
            if source.read(4) in magic:
                yield item


def normalize_library_ids():
    """Wheel install names may contain upstream build paths, not dependencies."""
    binaries = list(macho_files())
    identities = {}
    for binary in binaries:
        lines = subprocess.check_output(["/usr/bin/otool", "-D", str(binary)], text=True).splitlines()
        if len(lines) > 1 and lines[1].startswith("/"):
            identities[lines[1].strip()] = binary
    for binary in binaries:
        changes = []
        own_ids = [name for name, target in identities.items() if target == binary]
        if own_ids:
            changes += ["-id", "@rpath/" + binary.name]
        linked = subprocess.check_output(["/usr/bin/otool", "-L", str(binary)], text=True)
        for line in linked.splitlines()[1:]:
            if not line.startswith(("\t", " ")):
                continue
            dependency = line.strip().split(" (", 1)[0]
            if dependency in identities and identities[dependency] != binary:
                relative = os.path.relpath(identities[dependency], binary.parent)
                changes += ["-change", dependency, "@loader_path/" + relative]
        if changes:
            run(["/usr/bin/install_name_tool", *changes, binary], capture_output=True)
            # A changed Mach-O needs a valid temporary signature before import.
            run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", binary], capture_output=True)


def check_runtime():
    python = RUNTIME / "python/bin/python3.11"
    checks = [
        "import sys, numpy, onnxruntime, torch, torchaudio, mlx.core, mlx_whisper, gigaam",
        "from pathlib import Path",
        "assert Path(sys.prefix).resolve() == Path(sys.executable).resolve().parent.parent",
        "print('Portable Python imports: OK')",
    ]
    env = {**os.environ, "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"}
    env.pop("PYTHONPATH", None); env.pop("PYTHONHOME", None)
    run([python, "-I", "-c", "; ".join(checks)], env=env)
    run([RUNTIME / "node/bin/node", "--version"])
    run([RUNTIME / "codex/bin/codex", "--version"])
    for item in APP.rglob("*"):
        if item.is_symlink() and not item.resolve().is_relative_to(APP.resolve()):
            raise RuntimeError("External symlink in app: " + str(item.relative_to(APP)))
    unsupported = []
    minimum = (14, 0)
    binaries = list(macho_files())
    for binary in binaries:
        linked = subprocess.check_output(["/usr/bin/otool", "-L", str(binary)], text=True)
        for line in linked.splitlines()[1:]:
            if not line.startswith(("\t", " ")):
                continue
            dependency = line.strip().split(" (", 1)[0]
            if dependency.startswith("/") and not dependency.startswith(("/usr/lib/", "/System/Library/")):
                unsupported.append([str(binary.relative_to(APP)), dependency])
        build = subprocess.run(["/usr/bin/xcrun", "vtool", "-show-build", str(binary)], capture_output=True, text=True).stdout
        for version in re.findall(r"\bminos\s+(\d+(?:\.\d+)+)", build):
            minimum = max(minimum, tuple(int(v) for v in version.split(".")[:2]))
    if unsupported:
        raise RuntimeError("External binary dependencies: " + json.dumps(unsupported))
    print("Checked %d native binaries; minimum macOS %s" % (len(binaries), ".".join(map(str, minimum))), flush=True)
    return binaries, minimum


def main():
    if os.uname().machine != "arm64":
        raise RuntimeError("This package targets Apple Silicon")
    print("Building native application", flush=True)
    run(["zsh", ROOT / "scripts/build-mac.sh"])
    specs = [LOCK["node"], LOCK["codex"]] + LOCK["mlx"]
    with ThreadPoolExecutor(max_workers=4) as pool:
        archives = list(pool.map(download, specs))
    if DISK.exists():
        shutil.rmtree(DISK)
    DISK.mkdir(parents=True)
    copytree(ROOT / "build/Диалог.app", APP)
    (RESOURCES / "project-root.txt").unlink(missing_ok=True)
    service = RESOURCES / "Service"
    for folder in ["server", "speech", "public", "node_modules"]:
        copytree(ROOT / folder, service / folder)
    for name in ["package.json", "package-lock.json"]:
        shutil.copy2(ROOT / name, service / name)
    # Whitelist runtime code only: never copy .local, preferences, conversations,
    # imported materials, model caches or any Codex authentication directory.
    (RESOURCES / "Models").mkdir()
    shutil.copy2(ROOT / ".local/models/silero_vad.onnx", RESOURCES / "Models/silero_vad.onnx")

    print("Embedding Node and the official Codex CLI", flush=True)
    with tempfile.TemporaryDirectory(prefix="dialog-runtimes-") as temporary:
        extracted = Path(temporary)
        for archive in archives[:2]:
            run(["/usr/bin/tar", "-xf", archive, "-C", extracted])
        node_source = next(extracted.glob("node-*-darwin-arm64"))
        node_bin = RUNTIME / "node/bin"
        node_bin.mkdir(parents=True)
        shutil.copy2(node_source / "bin/node", node_bin / "node")
        shutil.copy2(node_source / "LICENSE", RUNTIME / "node/LICENSE")
        vendor = extracted / "package/vendor/aarch64-apple-darwin"
        if not vendor.is_dir():
            raise RuntimeError("Unexpected Codex package layout")
        copytree(vendor, RUNTIME / "codex/vendor")
        codex_bin = RUNTIME / "codex/bin"
        codex_bin.mkdir()
        launcher = codex_bin / "codex"
        launcher.write_text('#!/bin/sh\nset -eu\nbase=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)\nexec "$base/vendor/bin/codex" "$@"\n')
        launcher.chmod(0o755)
        for name in ["LICENSE", "NOTICE"]:
            url = "https://raw.githubusercontent.com/openai/codex/main/" + name
            with urllib.request.urlopen(url, timeout=40) as response:
                (RUNTIME / "codex" / name).write_bytes(response.read())

    print("Embedding relocatable Python and speech engines", flush=True)
    python_base = Path(subprocess.check_output([str(ROOT / ".venv/bin/python"), "-c", "import sys; print(sys.base_prefix)"], text=True).strip())
    copytree(python_base, RUNTIME / "python")
    site = RUNTIME / "python/lib/python3.11/site-packages"
    copytree(ROOT / ".venv/lib/python3.11/site-packages", site)
    for name in ["_virtualenv.pth", "_virtualenv.py"]:
        (site / name).unlink(missing_ok=True)
    for metadata in site.glob("*.dist-info/direct_url.json"):
        metadata.unlink()
    # Use the same MLX version with its macOS 14 wheels instead of the build
    # machine's macOS 26 Metal binaries.
    for name in ["mlx", "mlx-0.32.4.dist-info", "mlx_metal-0.32.4.dist-info"]:
        target = site / name
        if target.is_dir():
            shutil.rmtree(target)
    for archive in archives[2:]:
        with zipfile.ZipFile(archive) as wheel:
            wheel.extractall(site)

    normalize_library_ids()
    binaries, minimum = check_runtime()
    with (APP / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    info["LSMinimumSystemVersion"] = ".".join(map(str, minimum))
    with (APP / "Contents/Info.plist").open("wb") as destination:
        plistlib.dump(info, destination)
    (RESOURCES / "distribution-runtime.json").write_text(json.dumps(LOCK, indent=2) + "\n")
    identity = os.environ.get("DIALOG_CODESIGN_IDENTITY")
    if not identity:
        identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
        match = next((re.search(r"\b([A-F0-9]{40})\b", line) for line in identities.splitlines() if "Apple Development:" in line), None)
        identity = match.group(1) if match else "-"
    print("Signing bundled executables", flush=True)
    for binary in binaries:
        run(["/usr/bin/codesign", "--force", "--sign", identity, "--timestamp=none", binary], capture_output=True)
    run(["/usr/bin/codesign", "--force", "--deep", "--sign", identity, "--timestamp=none", APP], capture_output=True)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", APP])

    (DISK / "Applications").symlink_to("/Applications")
    (DISK / "Сначала прочитай.txt").write_text("""ДИАЛОГ ДЛЯ MAC

Mac с Apple Silicon (M1 и новее), macOS MINIMUM и новее.

1. Перетащи «Диалог.app» в Applications (Программы).
2. Открой приложение из Applications.
3. В Настройки → Codex и звук нажми «Войти» и войди в свой ChatGPT
   с доступом к Codex. API-ключ не нужен.
4. Разреши микрофон и запись экрана/системного аудио в настройках macOS.
   Изображение экрана не записывается. Для одиночной клавиши ответа
   в фоне приложение отдельно предложит разрешение мониторинга ввода.
5. При первой загрузке распознавания нужен интернет. Модели скачиваются
   на твой Mac; загрузка может занять несколько минут и несколько ГБ.
6. Добавь свои материалы, настрой манеру ответа, выбери микрофон
   и нажми «Слушать». Второй микрофон для звонка не требуется.

Node, Python, Codex CLI и четыре движка распознавания уже внутри.
Homebrew, Xcode и установка зависимостей через Терминал не нужны.
Материалы, история, инструкции и учётная запись автора сюда не включены.

Это тестовая сборка без нотариализации Apple. Если macOS блокирует
первое открытие: Системные настройки → Конфиденциальность и безопасность
→ «Всё равно открыть» для «Диалог». Подтверди открытие приложения.
Инструкция Apple: https://support.apple.com/102445

Личные данные хранятся в ~/Library/Application Support/Dialog.
Подписка и лимиты Codex — у каждого пользователя свои.
""".replace("MINIMUM", info["LSMinimumSystemVersion"]), encoding="utf-8")
    output = ROOT / "output" / ("Диалог-%s-Apple-Silicon.dmg" % info["CFBundleShortVersionString"])
    output.parent.mkdir(exist_ok=True)
    print("Compressing disk image", flush=True)
    run(["/usr/bin/hdiutil", "create", "-ov", "-volname", "Диалог", "-fs", "HFS+", "-format", "UDZO", "-srcfolder", DISK, output])
    digest = hashlib.sha256()
    with output.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    manifest = {"file": output.name, "bytes": output.stat().st_size, "sha256": digest.hexdigest(), "architecture": "arm64", "minimumMacOS": info["LSMinimumSystemVersion"], "notarized": False, "includesUserData": False, "runtimes": LOCK}
    output.with_suffix(".json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print("READY: " + str(output), flush=True)


if __name__ == "__main__":
    main()
