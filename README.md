# Pod autoscaling on OKE: near scale-to-zero

Research on reducing OKE costs by keeping one warm, minimal pod per service instead of scaling to zero, plus where true zero is fine (non-production, queue workers, internal tools). Revision 2 adds Node.js, PHP and Go guidance, unpredictable traffic, and a comparison of OKE cluster variants.

- Report (English): [report-en.md](report-en.md)
- Relatório (português): [report-pt-BR.md](report-pt-BR.md)
- PDFs, light and dark versions of each report: [pdf/](pdf/)
  - `report-en-light.pdf`, `report-en-dark.pdf`, `report-pt-BR-light.pdf`, `report-pt-BR-dark.pdf`
  - Rebuild after editing a report: `python3 -m venv .tools/pdf-venv && .tools/pdf-venv/bin/pip install -r pdf/requirements.txt` (once), then `.tools/pdf-venv/bin/python pdf/build.py`
- Example manifests: [examples/](examples/)
- Local validation lab (kind + Kubernetes 1.36.4; needs podman or docker):
  - [lab/run-lab.sh](lab/run-lab.sh): creates the cluster and checks in-place resize, VPA, startup boost, the shrinker and KEDA (about 10 minutes)
  - [lab/run-runtime-lab.sh](lab/run-runtime-lab.sh): runtime behaviour (Node.js, PHP-FPM, Go), scale-to-zero tools and placeholders (about 15 minutes; `--long` adds 6 minutes of idle-memory probes)
  - `./lab/run-lab.sh --delete` removes the cluster
- Cost model: `python3 lab/cost-model.py`

`.tools/` holds the kind, kubectl and helm binaries downloaded by the lab script, and the Python environment used to build the PDFs. It is safe to delete; both can be recreated with the commands above.
