#!/usr/bin/env python3
"""Check the requests the idle shrinker (examples/05) left on the runtime example pods.

Used by lab/run-runtime-lab.sh step 5. Reads `kubectl get deploy,pod -o json` on stdin
and prints one line per container:
    ok  <container>: <what was found>
    bad <container>: expected <x>; got <y>

usage: shrink_check.py idle|active
  idle   - CPU request equals the pod's idle-shrink annotation, memory request is below
           the Deployment template (the shrinker may keep more memory than the annotation
           asks for if the container uses more), and no restarts.
  active - CPU and memory requests equal the Deployment template, and no restarts.
"""
import json
import sys

ANNOTATION = "idle-shrink.example.com/requests"
UNITS = {"Ki": 1 / 1024, "Mi": 1, "Gi": 1024, "k": 1e3 / 2**20, "M": 1e6 / 2**20, "G": 1e9 / 2**20}


def mib(quantity: str) -> float:
    for unit, factor in UNITS.items():
        if quantity.endswith(unit):
            return float(quantity[: -len(unit)]) * factor
    return float(quantity or 0) / 2**20


def main() -> int:
    mode = sys.argv[1]
    # stdin holds one or more `kubectl get -o json` documents (Deployments, then Pods).
    text, decoder, items, pos = sys.stdin.read(), json.JSONDecoder(), [], 0
    while pos < len(text.strip()):
        while text[pos].isspace():
            pos += 1
        doc, pos = decoder.raw_decode(text, pos)
        items += doc.get("items", [doc])
    deploys = {d["metadata"]["name"]: d for d in items if d["kind"] == "Deployment"}
    pods = [p for p in items
            if p["kind"] == "Pod" and p["status"].get("phase") == "Running"
            and not p["metadata"].get("deletionTimestamp")]
    if not pods:
        print("bad no running runtime example pods found")
        return 0
    for pod in sorted(pods, key=lambda p: p["metadata"]["labels"]["app"]):
        app = pod["metadata"]["labels"]["app"]
        template = {c["name"]: c["resources"]["requests"]
                    for c in deploys[app]["spec"]["template"]["spec"]["containers"]}
        idle = json.loads(pod["metadata"]["annotations"][ANNOTATION])
        statuses = {s["name"]: s for s in pod["status"]["containerStatuses"]}
        for name in template:  # pod spec order
            st = statuses[name]
            got = st.get("resources", {}).get("requests", {})
            got_cpu, got_mem, restarts = got.get("cpu", "?"), got.get("memory", "0"), st["restartCount"]
            tmpl = template[name]
            if mode == "idle":
                ok = got_cpu == idle[name]["cpu"] and mib(got_mem) < mib(tmpl["memory"])
                want = "CPU {}, memory below {}".format(idle[name]["cpu"], tmpl["memory"])
            else:
                ok = got_cpu == tmpl["cpu"] and mib(got_mem) == mib(tmpl["memory"])
                want = "CPU {}, memory {}".format(tmpl["cpu"], tmpl["memory"])
            ok = ok and restarts == 0
            label = "{}/{} requests".format(app, name)
            found = "{}/{}, restarts {}".format(got_cpu, got_mem, restarts)
            if ok:
                print("ok {}: {}".format(label, found))
            else:
                print("bad {}: expected {}, restarts 0; got {}".format(label, want, found))
    return 0


if __name__ == "__main__":
    sys.exit(main())
