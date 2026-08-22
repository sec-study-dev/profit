#!/usr/bin/env python3
"""Fetch verified contract source code from Etherscan V2 (multi-chain) for the
   84 ETH + 57 BSC corpus and write per-protocol source trees + metadata.

   Layout produced per protocol:
       out_root/<slug>/
           metadata.json            protocol slug/name/category/chain/address/tvl/etc
           sources/                 flat or nested .sol files as returned by API
           compiler.json            raw ABI/compiler settings blob for reproducibility
"""
import csv
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

APIKEY = open(Path(__file__).parent / ".apikey").read().strip()
BASE   = "https://api.etherscan.io/v2/api"
RATE_S = 0.25   # 4 req/sec, well under the 5/s free-tier cap

def api_get(chainid: int, address: str) -> dict:
    q = urllib.parse.urlencode({
        "chainid": chainid,
        "module":  "contract",
        "action":  "getsourcecode",
        "address": address,
        "apikey":  APIKEY,
    })
    url = f"{BASE}?{q}"
    with urllib.request.urlopen(url, timeout=30) as r:
        raw = r.read()
    return json.loads(raw)

def parse_sources(src_blob: str, single_file_name: str) -> dict:
    """Etherscan returns SourceCode as either a plain string (single-file) or
       a double-brace JSON blob `{{ ... standard-json-input ... }}` for
       multi-file. Return {filename: content}."""
    if not src_blob:
        return {}
    b = src_blob.strip()
    if b.startswith("{{") and b.endswith("}}"):
        try:
            obj = json.loads(b[1:-1])
        except Exception:
            return {single_file_name: b}
        files = {}
        for path, meta in (obj.get("sources") or {}).items():
            files[path] = meta.get("content", "")
        return files
    if b.startswith("{") and b.endswith("}"):
        # Sometimes standard-json is single-brace already
        try:
            obj = json.loads(b)
            if isinstance(obj, dict) and "sources" in obj:
                return {p: m.get("content","") for p,m in obj["sources"].items()}
        except Exception:
            pass
    return {single_file_name: b}

def safe_write(path: Path, data: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data, encoding="utf-8")

def fetch_corpus(protocols_json: Path, chainid: int, out_root: Path, manifest_rows: list):
    protos = json.loads(protocols_json.read_text())
    for i, p in enumerate(protos, 1):
        slug     = p["slug"]
        name     = p["name"]
        category = p["category"]
        address  = p["address"]
        pdir     = out_root / slug
        pdir.mkdir(parents=True, exist_ok=True)
        print(f"[{i:>3}/{len(protos)}] chain={chainid} {slug} ({address}) ", end="", flush=True)
        try:
            resp = api_get(chainid, address)
        except Exception as e:
            print(f"HTTP FAIL: {e}")
            manifest_rows.append([chainid, slug, name, category, address, "http_fail", 0, str(e)])
            time.sleep(RATE_S)
            continue

        result = (resp.get("result") or [{}])[0]
        src    = result.get("SourceCode") or ""
        if not src:
            print(f"NOT VERIFIED (msg={resp.get('message')})")
            manifest_rows.append([chainid, slug, name, category, address, "unverified", 0, str(resp.get("message"))])
            time.sleep(RATE_S)
            continue

        cname   = result.get("ContractName") or slug
        files   = parse_sources(src, single_file_name=f"{cname}.sol")
        for fpath, content in files.items():
            # sanitize path
            safe = re.sub(r"[^A-Za-z0-9_./\-]", "_", fpath).lstrip("/")
            safe_write(pdir / "sources" / safe, content)
        (pdir / "compiler.json").write_text(json.dumps({
            "ContractName":       result.get("ContractName"),
            "CompilerVersion":    result.get("CompilerVersion"),
            "OptimizationUsed":   result.get("OptimizationUsed"),
            "Runs":               result.get("Runs"),
            "EVMVersion":         result.get("EVMVersion"),
            "LicenseType":        result.get("LicenseType"),
            "Proxy":              result.get("Proxy"),
            "Implementation":     result.get("Implementation"),
            "Library":            result.get("Library"),
            "ConstructorArguments": result.get("ConstructorArguments"),
        }, indent=2))
        (pdir / "abi.json").write_text(result.get("ABI") or "[]")
        (pdir / "metadata.json").write_text(json.dumps({
            "slug":           slug,
            "name":           name,
            "category":       category,
            "chain_id":       chainid,
            "chain":          "ethereum" if chainid==1 else ("bsc" if chainid==56 else str(chainid)),
            "address":        address,
            "contract_name":  result.get("ContractName"),
            "compiler":       result.get("CompilerVersion"),
            "verified":       True,
            "source_files":   len(files),
            "explorer_url":   (f"https://etherscan.io/address/{address}" if chainid==1
                                else f"https://bscscan.com/address/{address}"),
            "fetched_at":     time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }, indent=2))
        print(f"OK  files={len(files)}  cname={cname}")
        manifest_rows.append([chainid, slug, name, category, address, "verified", len(files), cname])
        time.sleep(RATE_S)

def main():
    here     = Path(__file__).parent
    eth_json = here / "eth_protocols.json"
    bsc_json = here / "bsc_protocols.json"
    eth_out  = here / "ethereum-defi-corpus"
    bsc_out  = here / "bsc-defi-corpus"
    manifest = []
    fetch_corpus(eth_json, 1,  eth_out, manifest)
    fetch_corpus(bsc_json, 56, bsc_out, manifest)
    # write manifests
    for root, chain in [(eth_out,1),(bsc_out,56)]:
        with open(root / "MANIFEST.csv","w",newline="") as f:
            w = csv.writer(f)
            w.writerow(["chain_id","slug","name","category","address","status","source_files","contract_or_error"])
            for row in manifest:
                if row[0]==chain:
                    w.writerow(row)
    # combined
    with open(here / "MANIFEST_ALL.csv","w",newline="") as f:
        w = csv.writer(f)
        w.writerow(["chain_id","slug","name","category","address","status","source_files","contract_or_error"])
        w.writerows(manifest)
    verified = sum(1 for r in manifest if r[5]=="verified")
    print(f"\nDONE. total={len(manifest)}  verified={verified}  unverified/fail={len(manifest)-verified}")

if __name__ == "__main__":
    main()
