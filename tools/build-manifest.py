#!/usr/bin/env python3
"""
Genera manifest.json y sincroniza files/ para el pack PBM Mods.

Uso:
  python tools/build-manifest.py --pack "C:\\ruta\\PBM Mods 1.21.1" --repo . --version 1.1.0
"""
import argparse
import datetime
import hashlib
import json
import os
import shutil
import time
import urllib.error
import urllib.parse
import urllib.request

RAW_BASE = "https://raw.githubusercontent.com/pedritobm/pbm-mods-pack/main"
MODRINTH_API = "https://api.modrinth.com/v2/version_file/"
USER_AGENT = "PBM-Modpack-Builder/1.0 (pedritobm)"

EXCLUDE_DIRS = {"juxtui", "voicechat", "xaero"}
EXCLUDE_FILES = {
    "iris.properties", "sodium-options.json", "sodium-extra-options.json",
    "lumevale-camera.json",
    "last-world-panorama.json", "xaerohud.txt", "xaeropatreon.txt",
    "pbms_mods.json.bak_softvision", "usernamecache.json", "last_played.json",
}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def url_path(path):
    return urllib.parse.quote(path.replace("\\", "/"), safe="/+")


def modrinth_url(path):
    try:
        req = urllib.request.Request(
            MODRINTH_API + sha1(path), headers={"User-Agent": USER_AGENT}
        )
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        return data["files"][0]["url"]
    except Exception:
        return None


def reset_dir(path):
    if os.path.isdir(path):
        shutil.rmtree(path)
    os.makedirs(path, exist_ok=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pack", required=True)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--version", required=True)
    args = ap.parse_args()

    pack = os.path.abspath(args.pack)
    repo = os.path.abspath(args.repo)
    files_dir = os.path.join(repo, "files")
    mc = os.path.join(pack, ".minecraft")

    cfg_dst = os.path.join(files_dir, ".minecraft", "config")
    rp_dst = os.path.join(files_dir, ".minecraft", "resourcepacks")
    md_dst = os.path.join(files_dir, ".minecraft", "mods")
    for d in (cfg_dst, rp_dst, md_dst):
        reset_dir(d)

    entries = []

    # ---- configs por defecto (add-if-missing)
    cfg_src = os.path.join(mc, "config")
    for root, dirs, names in os.walk(cfg_src):
        rel_root = os.path.relpath(root, cfg_src)
        top = rel_root.split(os.sep)[0]
        if top in EXCLUDE_DIRS:
            dirs[:] = []
            continue
        for name in names:
            if name in EXCLUDE_FILES:
                continue
            src = os.path.join(root, name)
            rel = os.path.join(rel_root, name) if rel_root != "." else name
            dst = os.path.join(cfg_dst, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)
            manifest_rel = ".minecraft/config/" + rel.replace("\\", "/")
            entries.append({
                "path": manifest_rel,
                "mode": ("sync" if name == "watut-client.toml" else "add-if-missing"),
                "sha256": sha256(dst),
                "size": os.path.getsize(dst),
                "url": f"{RAW_BASE}/files/{url_path('.minecraft/config/' + rel)}",
            })

    # ---- resourcepacks por defecto (add-if-missing)
    rp_src = os.path.join(mc, "resourcepacks")
    if os.path.isdir(rp_src):
        for name in sorted(os.listdir(rp_src)):
            src = os.path.join(rp_src, name)
            if not os.path.isfile(src):
                continue
            dst = os.path.join(rp_dst, name)
            shutil.copy2(src, dst)
            entries.append({
                "path": f".minecraft/resourcepacks/{name}",
                "mode": "add-if-missing",
                "sha256": sha256(dst),
                "size": os.path.getsize(dst),
                "url": f"{RAW_BASE}/files/{url_path('.minecraft/resourcepacks/' + name)}",
            })

    # ---- skins de CustomSkinLoader (LocalSkin)
    csl_src = os.path.join(mc, "CustomSkinLoader")
    if os.path.isdir(csl_src):
        for root, dirs, names in os.walk(csl_src):
            for name in names:
                if not name.endswith((".png", ".json")):
                    continue
                src = os.path.join(root, name)
                rel = os.path.relpath(src, csl_src).replace("\\", "/")
                dst = os.path.join(files_dir, ".minecraft", "CustomSkinLoader", rel)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(src, dst)
                entries.append({
                    "path": ".minecraft/CustomSkinLoader/" + rel,
                    "mode": "sync" if rel.startswith("LocalSkin/") else "add-if-missing",
                    "sha256": sha256(dst),
                    "size": os.path.getsize(dst),
                    "url": f"{RAW_BASE}/files/{url_path('.minecraft/CustomSkinLoader/' + rel)}",
                })

    # ---- mods (sync)
    mods_src = os.path.join(mc, "mods")
    for name in sorted(os.listdir(mods_src)):
        if not name.endswith(".jar"):
            continue
        src = os.path.join(mods_src, name)
        if not os.path.isfile(src):
            continue
        url = modrinth_url(src)
        if not url:
            dst = os.path.join(md_dst, name)
            shutil.copy2(src, dst)
            url = f"{RAW_BASE}/files/{url_path('.minecraft/mods/' + name)}"
        entries.append({
            "path": f".minecraft/mods/{name}",
            "mode": "sync",
            "sha256": sha256(src),
            "size": os.path.getsize(src),
            "url": url,
        })
        time.sleep(0.05)

    entries.sort(key=lambda e: e["path"])
    manifest = {
        "pack": "PBM Mods",
        "version": args.version,
        "minecraft": "1.21.1",
        "loader": "fabric",
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "syncRoots": [".minecraft/mods"],
        "files": entries,
    }
    out = os.path.join(repo, "manifest.json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2, ensure_ascii=False)

    mods = sum(1 for e in entries if e["path"].startswith(".minecraft/mods/"))
    configs = sum(1 for e in entries if e["path"].startswith(".minecraft/config/"))
    packs = sum(1 for e in entries if e["path"].startswith(".minecraft/resourcepacks/"))
    print(f"manifest: {out}")
    print(f"version: {args.version} | mods: {mods} | configs: {configs} | packs: {packs}")


if __name__ == "__main__":
    main()
