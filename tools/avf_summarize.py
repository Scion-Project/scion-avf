#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Turn a results directory into summary.json + summary.md.

    avf_summarize.py probe DIR   answers for spike 1 from DIR/<tag>-result.json
    avf_summarize.py bench DIR   native / AVF / TCG comparison from the console logs

Pure standard library; safe to rerun on a results directory at any time.
"""
import glob
import json
import os
import re
import statistics
import sys

VIRTIO = {
    1: "net", 2: "blk", 3: "console", 4: "rng", 5: "balloon", 6: "iomem", 7: "rpmsg",
    8: "scsi", 9: "9p", 10: "wlan", 13: "balloon-mem", 16: "gpu", 17: "clock",
    18: "input", 19: "vsock", 20: "crypto", 22: "pstore", 23: "iommu", 24: "mem",
    25: "sound", 26: "fs", 27: "pmem", 29: "i2c", 34: "bluetooth", 35: "gpio",
}


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def parse_cpu_list(s):
    """'0-3,5' -> 5"""
    n = 0
    for part in (s or "").split(","):
        part = part.strip()
        if not part:
            continue
        a, _, b = part.partition("-")
        try:
            n += (int(b) - int(a) + 1) if b else 1
        except ValueError:
            return None
    return n or None


def decode_virtio(s):
    out = []
    for tok in (s or "").split():
        try:
            v = int(tok, 16)
        except ValueError:
            continue
        out.append(f"{VIRTIO.get(v, 'id%d' % v)}({v})")
    return out


def midr_name(midr):
    """Part number -> core name for the Arm cores a Tensor SoC is likely to show."""
    try:
        v = int(midr, 16)
    except (TypeError, ValueError):
        return None
    impl, part = (v >> 24) & 0xFF, (v >> 4) & 0xFFF
    if impl != 0x41:
        return f"implementer 0x{impl:02x} part 0x{part:03x}"
    names = {0xD05: "Cortex-A55", 0xD46: "Cortex-A510", 0xD80: "Cortex-A520", 0xD4D: "Cortex-A715",
             0xD81: "Cortex-A720", 0xD8A: "Cortex-A725 (id guess)", 0xD47: "Cortex-A710",
             0xD41: "Cortex-A78", 0xD44: "Cortex-X1", 0xD4E: "Cortex-X3", 0xD82: "Cortex-X4",
             0xD83: "Cortex-X925 (id guess)", 0xD08: "Cortex-A72", 0xD0B: "Cortex-A76"}
    return names.get(part, f"Arm part 0x{part:03x}")


# ---------------------------------------------------------------------------
# probe
# ---------------------------------------------------------------------------

def summarize_probe(d):
    runs = {}
    for p in sorted(glob.glob(os.path.join(d, "*-result.json"))):
        r = load_json(p)
        if r:
            runs[os.path.basename(p)[: -len("-result.json")]] = r
    if not runs:
        sys.exit(f"no *-result.json in {d}")

    def order(tag):
        m = re.fullmatch(r"mem-(\d+)", tag)
        return (3, int(m.group(1))) if m else ({"base": (0, 0), "cpus-host": (1, 0), "kernel-16k": (2, 0)}.get(tag, (4, 0)))
    runs = {k: runs[k] for k in sorted(runs, key=order)}
    base = runs.get("base") or next(iter(runs.values()))
    host = base.get("host", {})
    ans = {
        "verdict": base.get("verdict"),
        "verdict_detail": base.get("detail"),
        "vm_supported": host.get("virtualization_framework"),
        "hypervisor_props": {k[5:]: v for k, v in host.items() if k.startswith("prop.")},
        "capabilities": {"raw": base.get("capabilities"),
                         "protected": bool((base.get("capabilities") or 0) & 1) if base.get("capabilities", -1) >= 0 else None,
                         "non_protected": bool((base.get("capabilities") or 0) & 2) if base.get("capabilities", -1) >= 0 else None},
        "host_page_size": host.get("page_size"),
        "host_cpus": host.get("cpus"),
        "host_ram_mib": host.get("ram_mib"),
    }

    g = base.get("guest", {})
    ans["guest"] = {
        "kernel": g.get("kernel_release"),
        "page_size": int(g["page_size"]) if g.get("page_size", "").isdigit() else None,
        "vcpus_default": parse_cpu_list(g.get("cpus_online")),
        "mem_total_kb": int(g["mem_total_kb"]) if g.get("mem_total_kb", "").isdigit() else None,
        "midr_el1": g.get("midr_el1"),
        "core": midr_name(g.get("midr_el1")),
        "virtio": decode_virtio(g.get("virtio_ids")),
        "pci": g.get("pci_ids", "").split(),
        "hypervisor_type": g.get("hypervisor_type"),
    }
    t = base.get("timings_ms", {})
    ans["boot_ms"] = {"create": t.get("create"), "run_returned": t.get("run_returned"),
                      "first_console_byte": t.get("first_console_byte"),
                      "done_marker": t.get("done_marker"),
                      "guest_uptime_at_init_s": (g.get("uptime_s") or "").split(" ")[0] or None}

    if "cpus-host" in runs:
        gh = runs["cpus-host"].get("guest", {})
        ans["vcpus_match_host"] = {"verdict": runs["cpus-host"].get("verdict"),
                                   "vcpus": parse_cpu_list(gh.get("cpus_online"))}
    if "kernel-16k" in runs:
        r = runs["kernel-16k"]
        gk = r.get("guest", {})
        ans["kernel_16k"] = {"verdict": r.get("verdict"), "detail": r.get("detail"),
                             "guest_page_size": int(gk["page_size"]) if gk.get("page_size", "").isdigit() else None,
                             "first_console_byte_ms": r.get("timings_ms", {}).get("first_console_byte")}
    sweep = []
    for tag, r in runs.items():
        m = re.fullmatch(r"mem-(\d+)", tag)
        if m:
            gm = r.get("guest", {}).get("mem_total_kb", "")
            sweep.append({"requested_mib": int(m.group(1)), "verdict": r.get("verdict"), "detail": r.get("detail"),
                          "guest_mem_total_mib": round(int(gm) / 1024) if gm.isdigit() else None,
                          "first_console_byte_ms": r.get("timings_ms", {}).get("first_console_byte")})
    sweep.sort(key=lambda x: x["requested_mib"])
    if sweep:
        ok = [s["requested_mib"] for s in sweep if s["verdict"] == "OK"]
        ans["max_guest_ram_mib_tested_ok"] = max(ok) if ok else None
        ans["ram_sweep"] = sweep
    if "protected" in runs:
        ans["protected_vm"] = {"verdict": runs["protected"].get("verdict"), "detail": runs["protected"].get("detail")}

    out = {"schema": 1, "kind": "probe-summary", "device": {k: host.get(k) for k in
           ("model", "soc", "android", "security_patch", "fingerprint", "kernel")},
           "answers": ans, "runs": {k: {"verdict": v.get("verdict"), "detail": v.get("detail")} for k, v in runs.items()}}
    with open(os.path.join(d, "summary.json"), "w") as f:
        json.dump(out, f, indent=2)

    L = ["# AVF probe summary", ""]
    dv = out["device"]
    L.append(f"Device: {dv.get('model')} ({dv.get('soc')}), Android {dv.get('android')}, patch {dv.get('security_patch')}, host kernel {dv.get('kernel')}")
    L.append(f"Host: page size {ans['host_page_size']}, {ans['host_cpus']} CPUs, {ans['host_ram_mib']} MiB RAM")
    L.append("")
    L.append(f"**Base verdict: {ans['verdict']}** {('(' + ans['verdict_detail'] + ')') if ans['verdict_detail'] else ''}")
    L.append("")
    L.append("| run | verdict | detail |")
    L.append("|---|---|---|")
    for k, v in out["runs"].items():
        L.append(f"| {k} | {v['verdict']} | {(v['detail'] or '').replace('|', '/')[:100]} |")
    L.append("")
    gi = ans["guest"]
    L.append("## What a sideloaded custom VM got")
    L.append("")
    L.append(f"- guest kernel: `{gi['kernel']}`, page size **{gi['page_size']}**, core: {gi['core']} (MIDR {gi['midr_el1']})")
    L.append(f"- vCPUs: default **{gi['vcpus_default']}**" + (f", match-host **{ans['vcpus_match_host']['vcpus']}** ({ans['vcpus_match_host']['verdict']})" if 'vcpus_match_host' in ans else ""))
    if "max_guest_ram_mib_tested_ok" in ans:
        bad = [x for x in sweep if x["verdict"] != "OK"]
        L.append(f"- guest RAM: largest size that booted **{ans['max_guest_ram_mib_tested_ok']} MiB** of {', '.join(str(s['requested_mib']) for s in sweep)} tried"
                 + (f"; first refused: {bad[0]['requested_mib']} MiB ({bad[0]['verdict']}: {bad[0]['detail']})" if bad else "; none refused (raise --mem-sweep to find the ceiling)"))
    else:
        L.append(f"- guest RAM: MemTotal {gi['mem_total_kb']} kB at the default size (run with `--full` for the ceiling)")
    if "kernel_16k" in ans:
        k = ans["kernel_16k"]
        L.append(f"- 16 KiB-page guest kernel: **{k['verdict']}** (guest page size {k['guest_page_size']}) {k['detail'] or ''}")
    L.append(f"- virtio devices seen by the guest: {', '.join(gi['virtio']) or 'none'}; PCI ids: {' '.join(gi['pci']) or 'none'}")
    b = ans["boot_ms"]
    L.append(f"- boot: create {b['create']} ms, run() returned {b['run_returned']} ms, first console byte {b['first_console_byte']} ms, guest finished {b['done_marker']} ms (guest uptime at init {b['guest_uptime_at_init_s']} s)")
    if "protected_vm" in ans:
        L.append(f"- protected VM with our kernel: {ans['protected_vm']['verdict']} {ans['protected_vm']['detail'] or ''}")
    L.append(f"- hypervisor props: {json.dumps(ans['hypervisor_props'])}")
    L.append("")
    with open(os.path.join(d, "summary.md"), "w") as f:
        f.write("\n".join(L))
    print("\n".join(L))


# ---------------------------------------------------------------------------
# bench
# ---------------------------------------------------------------------------

BENCH_RE = re.compile(r"^BENCH name=(\S+) unit=(\S+) rep=(\d+) ops=(\d+) ns=(\d+) check=(\S+)\s*$")


def parse_bench(text):
    kv, wl, done = {}, {}, False
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("AVFKV "):
            k, _, v = line[6:].partition("=")
            kv[k] = v
        elif line.startswith("BENCH "):
            m = BENCH_RE.match(line)
            if m:
                name, unit, _rep, ops, ns, chk = m.groups()
                w = wl.setdefault(name, {"unit": unit, "ops": int(ops), "ns": [], "check": set()})
                w["ns"].append(int(ns))
                w["check"].add(chk)
        elif "=== AVFBENCH DONE ===" in line:
            done = True
    for w in wl.values():
        w["check"] = sorted(w["check"])
        w["best_ns_per_op"] = min(w["ns"]) / w["ops"]
        w["median_ns_per_op"] = statistics.median(w["ns"]) / w["ops"]
    return {"kv": kv, "workloads": wl, "complete": done}


# columns in display order: (key, file candidates, label)
BENCH_SOURCES = [
    ("native", ["native.txt"], "phone native"),
    ("avf", ["avf-console.txt"], "AVF/pKVM 4K"),
    ("avf16k", ["avf16k-console.txt"], "AVF/pKVM 16K"),
    ("tcg", ["tcg.txt"], "QEMU TCG"),
]


def fmt(x, digits=3):
    if x is None:
        return "n/a"
    if x >= 100:
        return f"{x:,.0f}"
    return f"{x:.{digits}g}"


def summarize_bench(d):
    res = {}
    for key, files, label in BENCH_SOURCES:
        for fn in files:
            p = os.path.join(d, fn)
            if os.path.isfile(p) and os.path.getsize(p):
                with open(p, errors="replace") as f:
                    r = parse_bench(f.read())
                if r["workloads"]:
                    r["label"] = label
                    res[key] = r
                break
    if not res:
        sys.exit(f"no benchmark output found in {d} (looked for native.txt, avf-console.txt, tcg.txt)")

    names = [n for n in ("int", "mem", "chase", "sys", "pf")
             if any(n in r["workloads"] for r in res.values())]
    rows, md = {}, []
    md += ["# AVF bench summary", ""]
    md += ["Best-of-reps time per operation (lower is better). `ops` are iterations (int), bytes (mem), loads (chase), syscalls (sys), pages (pf).", ""]
    hdr = ["workload", "unit"] + [f"{r['label']} ns/op" for r in res.values()]
    ratio_pairs = [("avf", "native", "AVF/native"), ("tcg", "avf", "TCG/AVF"), ("tcg", "native", "TCG/native")]
    ratio_pairs = [p for p in ratio_pairs if p[0] in res and p[1] in res]
    hdr += [p[2] for p in ratio_pairs] + ["checks"]
    md.append("| " + " | ".join(hdr) + " |")
    md.append("|" + "---|" * len(hdr))
    for n in names:
        row = {"unit": next(r["workloads"][n]["unit"] for r in res.values() if n in r["workloads"])}
        cells = [n, row["unit"]]
        for key, r in res.items():
            w = r["workloads"].get(n)
            row[key] = w["best_ns_per_op"] if w else None
            cells.append(fmt(row[key]))
        for a, b, lab in ratio_pairs:
            row[lab] = row[a] / row[b] if row.get(a) and row.get(b) else None
            cells.append(f"{row[lab]:.2f}x" if row[lab] else "n/a")
        # same work => same checksum, but only comparable at equal scale
        sets = {key: tuple(r["workloads"][n]["check"]) for key, r in res.items() if n in r["workloads"]}
        scales = {key: r["kv"].get("scale") for key, r in res.items()}
        if len(set(scales.values())) > 1:
            chk = "scales differ"
        else:
            chk = "match" if len(set(sets.values())) == 1 else "MISMATCH"
        row["checks"] = chk
        cells.append(chk)
        rows[n] = row
        md.append("| " + " | ".join(cells) + " |")
    md.append("")
    md.append("## Environment")
    md.append("")
    for key, r in res.items():
        kv = r["kv"]
        md.append(f"- **{r['label']}**: kernel `{kv.get('kernel_release', '?')}`, page size {kv.get('page_size', '?')}, "
                  f"CPUs online {kv.get('cpus_online', '?')}, core {midr_name(kv.get('midr_el1')) or kv.get('midr_el1', '?')}, "
                  f"scale {kv.get('scale', '?')}%, reps {kv.get('reps', '?')}, "
                  f"{'complete' if r['complete'] else 'INCOMPLETE'}")
    md.append("")
    out = {"schema": 1, "kind": "bench-summary", "rows": rows,
           "environment": {k: {"label": r["label"], "kv": r["kv"], "complete": r["complete"]} for k, r in res.items()}}
    with open(os.path.join(d, "summary.json"), "w") as f:
        json.dump(out, f, indent=2)
    with open(os.path.join(d, "summary.md"), "w") as f:
        f.write("\n".join(md))
    print("\n".join(md))


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("probe", "bench"):
        sys.exit(__doc__)
    (summarize_probe if sys.argv[1] == "probe" else summarize_bench)(sys.argv[2])


if __name__ == "__main__":
    main()
