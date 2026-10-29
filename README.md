# Pod autoscaling on OKE: near scale-to-zero

Research on reducing OKE costs by keeping one warm, minimal pod per service instead of scaling to zero, plus where true zero is fine (non-production, queue workers, internal tools). Revision 2 adds Node.js, PHP and Go guidance, unpredictable traffic, and a comparison of OKE cluster variants.

- Report (English): [report-en.md](report-en.md)
- Relatório (português): [report-pt-BR.md](report-pt-BR.md)
- PDFs, light and dark versions of each report: [pdf/](pdf/)
  - `report-en-light.pdf`, `report-en-dark.pdf`, `report-pt-BR-light.pdf`, `report-pt-BR-dark.pdf`
  - Rebuild after editing a report: `python3 -m venv .tools/pdf-venv && .tools/pdf-venv/bin/pip install -r pdf/requirements.txt` (once), then `.tools/pdf-venv/bin/python pdf/build.py`
- Example manifests: [examples/](examples/)
- Local validation lab (kind + Kubernetes 1.36.4; needs Linux on x86_64, podman or docker, curl and python3):
  - [lab/run-lab.sh](lab/run-lab.sh): creates the cluster and checks in-place resize, VPA, startup boost, the shrinker and KEDA (about 10 minutes, 30 checks)
  - [lab/run-runtime-lab.sh](lab/run-runtime-lab.sh): runtime behaviour (Node.js, PHP-FPM, Go), scale-to-zero tools and placeholders (about 15 minutes, 42 checks; `--long` adds 6 minutes and 2 checks of idle-memory probes)
  - `./lab/run-lab.sh --delete` removes the cluster
- Cost model: `python3 lab/cost-model.py`

`.tools/` holds the kind, kubectl and helm binaries downloaded by the lab script, and the Python environment used to build the PDFs. It is safe to delete; both can be recreated with the commands above.

## Expected output of the lab scripts

Run `run-lab.sh` first; `run-runtime-lab.sh` needs the cluster it creates. To keep a copy of the output, run them as `./lab/run-lab.sh 2>&1 | tee lab.log`.

### How to read it

Each step starts with a `==>` header, prints what it measured, then one line per check:

```
==> 2. Shrink requests in place (limits untouched) -> expect restarts=0
spec={"limits":{"cpu":"1","memory":"512Mi"},"requests":{"cpu":"25m","memory":"64Mi"}}
actual={"limits":{"cpu":"1","memory":"512Mi"},"requests":{"cpu":"25m","memory":"64Mi"}}
restarts=0 qos=Burstable
  PASS  requests applied in place (CPU/memory): 25m/64Mi
  PASS  limits unchanged (CPU/memory): 1/512Mi
  PASS  container restarts: 0
```

- `spec` is what was asked for, `actual` is what Kubernetes applied, and `restarts=0` means the container was not restarted.
- `PASS` lines show the value that was checked. A `FAIL` line shows the expected and the actual value. A `SKIP` line names a check the machine cannot run and why.
- The run ends with a summary. A good run looks like this, and the script then exits with code 0:

  ```
  ==> Summary
  30 checks: 30 passed, 0 failed
  ```

  If any check fails, the summary lists each failure with its step, and the exit code is 1.
- If a command fails outside a check (no network, cluster missing), the script stops and prints `STOPPED during "<step>"`, with the error just above it.
- Some steps include an error message on purpose. In step 3 of `run-lab.sh`, `… Pod QOS Class may not change as a result of resizing` is the expected result; the PASS line below it confirms it.

### Silent waits

These are normal, not hangs:

| Script | Where | How long |
|---|---|---|
| `run-lab.sh` | Cluster creation and add-ons (first run) | 3–6 min |
| `run-lab.sh` | Step 5 (VPA) | 1–3 min |
| `run-lab.sh` | Steps 6 and 7 | about 1 min each |
| `run-runtime-lab.sh` | Add-ons; steps 4, 5 and 6 | 1–4 min each |
| `run-runtime-lab.sh` | Step 7 (three cold requests, each waits for the app to reach 0) | 2–4 min |
| `run-runtime-lab.sh --long` | Step 11 | about 6 min |

### Values that differ between machines

These change from run to run and machine to machine. The checks allow for that:

- Pod names, timestamps and `AGE` columns.
- `NumCPU` in step 1 of `run-runtime-lab.sh` is the machine's core count. The placeholder's CPU amount in step 9 also depends on it.
- The CPU request VPA picks in step 5 of `run-lab.sh` (587m and 627m in our runs; any value above 100m passes).
- Timings: worker start (2–10 s), cold requests (about 1–2 s), queue drain, return to zero (about 3 min).
- Memory figures within a few MiB, and the Node.js patch version.
- On machines with fewer than 3 CPU cores, the Go GOMAXPROCS checks expect the core count instead of 2 and 3. Step 9 of `run-runtime-lab.sh` needs 2.5 free CPU cores on the worker node; with fewer, it is skipped, not failed.

### Harmless noise

- From kind: progress lines with emoji, `using podman due to KIND_EXPERIMENTAL_PROVIDER`, `enabling experimental podman provider` (podman only), `Have a question, bug, or feature request?`.
- From KEDA: `Warning: PollingInterval is configured but is not relevant for scaling…`.
- From kubectl on reruns: `Warning: resource … is missing the kubectl.kubernetes.io/last-applied-configuration annotation…`.
- From the Go image build in step 5 of `run-runtime-lab.sh` (first run only): `go: creating new go.mod…`, `go mod tidy`, and with podman `Copying blob sha256:…` and `Writing manifest to image destination`.
- In step 8 of `run-runtime-lab.sh`, during São Paulo office hours: `inside the uptime window now: forcing downtime for the test`.
- In step 8 of `run-lab.sh`, the HPA table may show `<unknown>` under TARGETS if metrics are not ready yet. The checks do not depend on it.
- On a rerun, the shrinker in step 7 of `run-lab.sh` also lists the Node.js, PHP and Go demo pods left by `run-runtime-lab.sh`.

### If something fails

- Rerun the script; both are safe to rerun on the same cluster. Timing-sensitive checks can fail once on a heavily loaded machine.
- If it fails again, start from a fresh cluster: `./lab/run-lab.sh --delete`, then run both scripts again.
- When asking for help, send the whole log (the `tee` file), not only the summary.
