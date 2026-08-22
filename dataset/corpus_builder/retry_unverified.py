#!/usr/bin/env python3
"""For each entry marked 'unverified', re-query Etherscan V2 to inspect the raw
response. If the entry is an EIP-1967 proxy with a resolvable Implementation
address, refetch source at that implementation and rewrite the protocol dir.
Otherwise leave the entry marked unverified so we can hand-substitute."""
import csv
import json
import re
import time
import urllib.parse
import urllib.request
from pathlib import Path

APIKEY = open(Path(__file__).parent / ".apikey").read().strip()
BASE   = "https://api.etherscan.io/v2/api"
RATE_S = 0.30

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
        return json.loads(r.read())

def parse_sources(src_blob, default_name):
    if not src_blob:
        return {}
    b = src_blob.strip()
    if b.startswith("{{") and b.endswith("}}"):
        try:
            obj = json.loads(b[1:-1])
        except Exception:
            return {default_name: b}
        return {p: m.get("content","") for p,m in (obj.get("sources") or {}).items()}
    if b.startswith("{") and b.endswith("}"):
        try:
            obj = json.loads(b)
            if isinstance(obj, dict) and "sources" in obj:
                return {p: m.get("content","") for p,m in obj["sources"].items()}
        except Exception:
            pass
    return {default_name: b}

def write_protocol(pdir: Path, slug, name, category, chainid, address, result, files):
    (pdir / "sources").mkdir(parents=True, exist_ok=True)
    # wipe existing sources
    for old in (pdir / "sources").glob("**/*"):
        if old.is_file(): old.unlink()
    for fpath, content in files.items():
        safe = re.sub(r"[^A-Za-z0-9_./\-]", "_", fpath).lstrip("/")
        out = pdir / "sources" / safe
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(content, encoding="utf-8")
    (pdir / "compiler.json").write_text(json.dumps({
        "ContractName": result.get("ContractName"),
        "CompilerVersion": result.get("CompilerVersion"),
        "OptimizationUsed": result.get("OptimizationUsed"),
        "Runs": result.get("Runs"),
        "EVMVersion": result.get("EVMVersion"),
        "LicenseType": result.get("LicenseType"),
        "Proxy": result.get("Proxy"),
        "Implementation": result.get("Implementation"),
        "ConstructorArguments": result.get("ConstructorArguments"),
    }, indent=2))
    (pdir / "abi.json").write_text(result.get("ABI") or "[]")
    (pdir / "metadata.json").write_text(json.dumps({
        "slug": slug, "name": name, "category": category,
        "chain_id": chainid, "chain": "ethereum" if chainid==1 else "bsc",
        "address": address, "contract_name": result.get("ContractName"),
        "compiler": result.get("CompilerVersion"),
        "verified": True, "source_files": len(files),
        "explorer_url": (f"https://etherscan.io/address/{address}" if chainid==1
                        else f"https://bscscan.com/address/{address}"),
        "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }, indent=2))

def main():
    here = Path(__file__).parent
    manifest = list(csv.reader(open(here / "MANIFEST_ALL.csv")))
    header, rows = manifest[0], manifest[1:]
    updated_rows = []
    for r in rows:
        chain, slug, name, category, address, status, nfiles, extra = r
        if status == "verified":
            updated_rows.append(r); continue
        chainid = int(chain)
        # Re-query for Proxy field
        try:
            resp = api_get(chainid, address)
        except Exception as e:
            print(f"HTTP FAIL: {slug} — {e}")
            updated_rows.append(r); time.sleep(RATE_S); continue
        result = (resp.get("result") or [{}])[0]
        proxy = result.get("Proxy")
        impl  = result.get("Implementation") or ""
        print(f"{slug:35} proxy={proxy!s:>3}  impl={impl}")
        if str(proxy) == "1" and impl and impl != address:
            time.sleep(RATE_S)
            try:
                iresp = api_get(chainid, impl)
            except Exception as e:
                print(f"  impl fetch fail: {e}")
                updated_rows.append(r); time.sleep(RATE_S); continue
            iresult = (iresp.get("result") or [{}])[0]
            isrc = iresult.get("SourceCode") or ""
            if isrc:
                cname = iresult.get("ContractName") or slug
                files = parse_sources(isrc, f"{cname}.sol")
                out_root = here / ("ethereum-defi-corpus" if chainid==1 else "bsc-defi-corpus")
                pdir = out_root / slug
                write_protocol(pdir, slug, name, category, chainid, address, iresult, files)
                print(f"  RECOVERED via impl {impl}: files={len(files)} cname={cname}")
                updated_rows.append([chain, slug, name, category, address, "verified_via_impl",
                                     len(files), f"impl={impl};cname={cname}"])
                time.sleep(RATE_S); continue
        updated_rows.append(r)
        time.sleep(RATE_S)

    # rewrite MANIFEST_ALL.csv and per-chain manifests
    with open(here / "MANIFEST_ALL.csv","w",newline="") as f:
        w = csv.writer(f); w.writerow(header); w.writerows(updated_rows)
    for chain_id, root_name in [(1,"ethereum-defi-corpus"),(56,"bsc-defi-corpus")]:
        with open(here / root_name / "MANIFEST.csv","w",newline="") as f:
            w = csv.writer(f); w.writerow(header)
            for r in updated_rows:
                if int(r[0]) == chain_id: w.writerow(r)

    ok_direct = sum(1 for r in updated_rows if r[5]=="verified")
    ok_impl   = sum(1 for r in updated_rows if r[5]=="verified_via_impl")
    left      = sum(1 for r in updated_rows if r[5] not in ("verified","verified_via_impl"))
    print(f"\ndirect_verified={ok_direct}  via_impl={ok_impl}  still_unverified={left}")

if __name__ == "__main__":
    main()
