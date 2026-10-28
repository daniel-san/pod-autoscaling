# Pod autoscaling on OKE: near scale-to-zero

Research on reducing OKE costs by keeping one warm, minimal pod per service instead of scaling to zero, plus where true zero is fine (non-production, queue workers, internal tools). Revision 2 adds Node.js, PHP and Go guidance, unpredictable traffic, and a comparison of OKE cluster variants.

- Report (English): [report-en.md](report-en.md)
- Relatório (português): [report-pt-BR.md](report-pt-BR.md)
- Example manifests: [examples/](examples/)
- Local validation lab (kind + Kubernetes 1.36.4; needs podman or docker):
  - [lab/run-lab.sh](lab/run-lab.sh): creates the cluster and checks in-place resize, VPA, startup boost, the shrinker and KEDA (about 10 minutes)
  - [lab/run-runtime-lab.sh](lab/run-runtime-lab.sh): runtime behaviour (Node.js, PHP-FPM, Go), scale-to-zero tools and placeholders (about 15 minutes; `--long` adds 6 minutes of idle-memory probes)
  - `./lab/run-lab.sh --delete` removes the cluster
- Cost model: `python3 lab/cost-model.py`

`.tools/` holds the kind, kubectl and helm binaries downloaded by the lab script. It is safe to delete; the script downloads them again.
