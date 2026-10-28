# Pod autoscaling on OKE: near scale-to-zero

Research on reducing OKE costs by keeping one warm, minimal pod per service instead of scaling to zero.

- Report (English): [report-en.md](report-en.md)
- Relatório (português): [report-pt-BR.md](report-pt-BR.md)
- Example manifests: [examples/](examples/)
- Local validation lab: [lab/run-lab.sh](lab/run-lab.sh) (kind + Kubernetes 1.36.4; needs podman or docker)
- Cost model: `python3 lab/cost-model.py`

`.tools/` holds the kind, kubectl and helm binaries downloaded by the lab script. It is safe to delete; the script downloads them again.
