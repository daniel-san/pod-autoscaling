# Quase scale-to-zero no OKE: manter um pod aquecido e deixá-lo mínimo

Relatório de pesquisa, 27 de outubro de 2026. Versão em inglês: [report-en.md](report-en.md).

Escopo: como obter a maior parte da economia do scale-to-zero no Oracle Kubernetes Engine (OKE) sem pagar o custo do cold start (partida a frio). O relatório cobre o escalonamento vertical do pod que continua rodando, os recursos do OKE e do Kubernetes que já ajudam, e se reduzir CPU ou memória economiza mais.

Todos os manifestos citados estão em [`examples/`](examples/). As afirmações marcadas com **(lab)** foram verificadas em um cluster local Kubernetes 1.36.4 com [`lab/run-lab.sh`](lab/run-lab.sh). Os números de custo vêm de [`lab/cost-model.py`](lab/cost-model.py) e da tabela pública de preços da OCI.

Termos mantidos em inglês por serem os nomes usados no Kubernetes: *requests* (recursos reservados), *limits* (teto), *node* (nó de trabalho), *eviction* (despejo do pod pelo kubelet), *OOM kill* (processo morto por falta de memória).

---

## 1. Resumo

1. **A economia vem dos requests, não do uso.** Nos managed nodes do OKE você paga por nós inteiros. O scheduler posiciona os pods pelos *requests*, e o autoscaler de nós só remove um nó quando os requests permitem. Encolher um pod só economiza se requests menores resultarem em menos nós ou em nós mais baratos.
2. **Um pod aquecido com CPU reduzida captura cerca de 90% da economia do scale-to-zero.** No modelo de custo (30 serviços, 3 réplicas no horário comercial), o scale-to-zero de verdade à noite economiza 64%. Manter 1 réplica por serviço com o request de CPU reduzido para 50m economiza 58%. O pod aquecido custa cerca de US$ 1,40 por serviço por mês (E5 Flex, pay-as-you-go).
3. **Escalonamento vertical sem reinício já está pronto no OKE.** O in-place pod resize é GA desde o Kubernetes 1.35. O OKE suporta hoje 1.34.10, 1.35.2 e 1.36.4 (1.37.0 em preview). O VPA 1.6+ aplica recomendações sem recriar o pod (`InPlaceOrRecreate`), e o VPA 1.7+ traz um CPU Startup Boost em alpha.
4. **Corte CPU primeiro, memória com cuidado.**
   - No E5/E6 Flex, 1 vCPU custa o mesmo que 7,5 GB de RAM, então a CPU representa cerca de 78% do custo de um pod típico de 500m/1Gi.
   - CPU é compressível: um container sem CPU suficiente fica lento, ninguém o mata. Em repouso, o uso de CPU cai de fato para poucos millicores.
   - Memória não é compressível. Passar do *limit* de memória causa OOM kill do container. Usar mais que o *request* de memória coloca o pod no início da fila de eviction quando falta memória no nó.
   - Em repouso, o uso de memória quase não cai, a menos que a aplicação devolva memória ao sistema operacional.
   - Regra: reduza os requests de CPU agressivamente. Reduza os *requests* de memória só até o working set medido em repouso. Nunca reduza o *limit* de memória abaixo do uso atual.
5. **Stack recomendada:**
   - KEDA (ou HPA) com `minReplicas: 1` e alvo de CPU absoluta ou de taxa de requisições.
   - VPA em modo `Off` para medir, depois `InPlaceOrRecreate` com `RequestsOnly`, ou um encolhedor in-place por agenda para horários ociosos previsíveis.
   - Um CPU startup boost para manter o cold start curto.
   - Cluster Autoscaler (add-on do OKE) ou Karpenter Provider for OCI para transformar os requests liberados em menos nós. Nós burstable para pools de pouca CPU. Nós preemptible só para réplicas extras.
6. **Evite:**
   - Virtual nodes para pods pequenos aquecidos. A alocação arredonda para OCPUs e GBs inteiros, então um pod de 50m custa cerca de 10x mais lá.
   - HPA por *Utilization* de CPU junto com redução de requests. Utilization é uso dividido pelo request, então encolher o request dispara uma avalanche de scale-out.
   - Dois controladores alterando os recursos do mesmo pod.
   - Colocar a única réplica aquecida em capacidade preemptible.

---

## 2. Contexto e premissas

- **Versões do OKE (out/2026):** 1.34.10, 1.35.2, 1.36.4, além de 1.37.0 em preview ([release notes do OKE](https://docs.oracle.com/iaas/releasenotes/services/conteng/)). O in-place resize exige 1.33+ e é GA a partir da 1.35. O Kubernetes 1.35+ exige cgroup v2, fornecido pelas imagens OKE OL8 ([blog OKE 1.35](https://blogs.oracle.com/cloud-infrastructure/oke-welcomes-kubernetes-1-35)).
- **Tipo de cluster:** assumo clusters *enhanced* (US$ 0,10/h por cluster). Os add-ons gerenciados (Cluster Autoscaler, Metrics Server), virtual nodes, workload identity e self-managed nodes exigem esse tipo ([basic vs enhanced](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengcomparingenhancedwithbasicclusters_topic.htm)).
- **Preços:** API pública de preços da OCI, pay-as-you-go em USD, consultada em 27/10/2026. Descontos negociados mudam os valores absolutos, não as proporções.
- **Simplificação do modelo de custo:** o custo é atribuído aos recursos reservados (requests). Isso supõe nós bem empacotados e um autoscaler de nós que remove capacidade. A economia real é menor na proporção da sua ineficiência de empacotamento.
- **Lab:** kind v0.33 com Kubernetes 1.36.4 sobre containerd 2.3.4, VPA 1.8.1, KEDA 2.21.0, metrics-server 0.9.0. O OKE usa CRI-O em vez de containerd, e o lab não testa o provisionamento de nós da OCI, então só o comportamento no nível do pod foi verificado.

---

## 3. Como o dinheiro flui no OKE

Três camadas definem a conta. "Quase zero" significa trabalhar as três.

| Camada | O que muda | Ferramentas | Economiza quando |
|---|---|---|---|
| Réplicas (horizontal) | Número de pods | HPA, KEDA | Menos pods significa menos requests |
| Tamanho do pod (vertical) | Requests/limits por pod | In-place resize, VPA, startup boost, encolhedor | Requests menores |
| Capacidade (nós) | Número, shape e preço dos nós | Cluster Autoscaler, Karpenter (KPO), shapes flex/burstable/preemptible/Arm | Nós são removidos ou trocados por mais baratos |

As duas primeiras camadas só reduzem *requests*. É na terceira que requests viram dinheiro. Se nenhum nó sai, encolher pods não economiza nada.

---

## 4. O que o OKE e o Kubernetes já oferecem

| Recurso | Situação no OKE (out/2026) | Papel no "quase zero" | Observações |
|---|---|---|---|
| In-place pod resize | GA no OKE 1.35.2 / 1.36.4; beta e ligado por padrão no 1.34.10 | Encolher e aumentar pods em execução sem reinício | Só CPU e memória; a classe de QoS não pode mudar |
| Vertical Pod Autoscaler | Você instala (Helm chart ou script upstream). [Guia do OKE](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengusingverticalpodautoscaler.htm) | Medir e ajustar requests | Não funciona em virtual nodes. O guia do OKE ainda usa o VPA 0.8 e o modo `Auto`, que está deprecated; use o VPA 1.8.x |
| HPA | Nativo | Manter `minReplicas: 1`, escalar com a carga | Use `AverageValue`, não `Utilization`, quando os requests mudam |
| HPA scale to zero | Beta no K8s 1.37 ([blog](https://kubernetes.io/blog/2026/09/02/kubernetes-v1-37-hpa-scale-to-zero-beta/)) | Zero de verdade em não-produção | O OKE tem a 1.37 só em preview |
| Metrics Server | Add-on do OKE | Necessário para HPA e VPA | |
| Cluster Autoscaler | Add-on do OKE ou standalone ([docs](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengusingclusterautoscaler.htm)) | Remove nós quando os requests caem; pools podem ir a 0 | Um shape por node pool; mantenha um pool de sistema fora do controle dele |
| Karpenter Provider for OCI (KPO) | GA em abril/2026, v1.4.0 ([docs](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/conteng-kpo.htm), [blog do GA](https://blogs.oracle.com/cloud-infrastructure/smarter-kubernetes-autoscaling-with-karpenter)) | Consolida nós subutilizados, escolhe shapes, suporta burstable e preemptible | Suporta K8s 1.31 a 1.36 |
| Shapes flexíveis | Managed nodes e KPO | Escolher a proporção OCPU:memória que casa com seus requests | 1 a 64 GB por OCPU no E4/E5 |
| Instâncias burstable | KPO (`baselineOcpuUtilization`) e self-managed nodes | Pagar 12,5% ou 50% das OCPUs | Memória é cobrada inteira; o burst dura no máximo cerca de 1 h ([docs](https://docs.oracle.com/en-us/iaas/Content/Compute/References/burstable-instances.htm)) |
| Capacidade preemptible | Managed node pools e KPO | Nós 50% mais baratos | Pode ser retomada a qualquer momento, com aviso de cerca de 2 min; não pode ser burstable ([docs](https://docs.oracle.com/en-us/iaas/Content/Compute/Concepts/preemptible.htm)) |
| Ampere A1/A2 (Arm) | Managed nodes e KPO | CPU mais barata | Exige imagens multi-arch |
| Virtual nodes | Clusters enhanced | Capacidade serverless para picos | Não serve para pods pequenos (seção 8.4) |

Não encontrei campo para o baseline burstable na API de managed node pools do OKE: o `NodeShapeConfig` só expõe `ocpus` e `memoryInGBs`. Por isso, workers burstable vêm pelo KPO ou por self-managed nodes.

**Ferramentas open source relacionadas:**

| Ferramenta | Versão verificada | Uso |
|---|---|---|
| [KEDA](https://keda.sh) | 2.21.0 | Gatilhos por cron e eventos; permite `minReplicaCount: 1`. A Oracle mostra KEDA com Cluster Autoscaler no OKE [neste blog](https://blogs.oracle.com/cloud-infrastructure/optimizing-oke-costs-with-keda-and-cluster-autoscaling) |
| KEDA HTTP add-on | 0.16.0 (beta) | Segura as requisições enquanto o serviço sobe do zero. Só serve para não-produção, porque ainda espera o cold start |
| [kube-startup-cpu-boost](https://github.com/google/kube-startup-cpu-boost) | 0.21.3 | Boost temporário de CPU na inicialização via in-place resize |
| [Goldilocks](https://github.com/FairwindsOps/goldilocks) | 4.16.2 | Dashboard sobre as recomendações do VPA |
| [KRR](https://github.com/robusta-dev/krr) | 1.31.1 | Recomendações de requests a partir do histórico do Prometheus, sem VPA |
| [OpenCost](https://www.opencost.io/docs/configuration/oracle) | 1.121.3 | Custo por namespace e por workload; suporta preços da OCI |
| [GoKubeDownscaler](https://github.com/caas-team/GoKubeDownscaler) / kube-green | 1.4.2 / 0.7.1 | Scale-to-zero fora do expediente em não-produção |
| [Elastic CPU Pod Autoscaler (DoorDash)](https://github.com/doordash-oss/elastic-cpu-pod-autoscaler) | n/d | Autoscaling in-place rápido, só de CPU |

Produtos comerciais também implementam diretamente a ideia de "encolher a última réplica". Um exemplo é o [PodResourceProfile](https://docs.kedify.io/how-to/prp-shrink-pod-instead-of-scale-to-zero/) da Kedify, que redimensiona os requests in-place quando um ScaledObject do KEDA fica inativo. CAST AI, ScaleOps e outros também oferecem rightsizing in-place. Não os avaliei.

---

## 5. Escalonamento vertical no OKE

### 5.1 In-place pod resize: o mecanismo

Você altera `spec.containers[*].resources` pelo subresource `resize` do pod, e o kubelet aplica os novos valores ao cgroup do container em execução ([docs do Kubernetes](https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/)).

```bash
kubectl -n demo patch pod my-app-xxxx --subresource resize \
  -p '{"spec":{"containers":[{"name":"app","resources":{"requests":{"cpu":"25m","memory":"64Mi"}}}]}}'
```

| Valor | Efeito no cgroup v2 do Linux | Efeito de reduzir |
|---|---|---|
| Request de CPU | `cpu.weight` (fatia sob disputa) | Menos CPU só quando o nó está ocupado; o scheduler vê mais espaço livre |
| Limit de CPU | `cpu.max` (cota rígida) | Throttling acima do novo limit |
| Request de memória | Só agendamento e ordem de eviction (a menos que o feature gate `MemoryQoS` esteja ligado) | O scheduler vê mais espaço livre; o pod sobe na fila de eviction se uso > request |
| Limit de memória | `memory.max` | OOM kill se o uso passar dele |

Regras que importam para esse padrão:

- **A classe de QoS não pode mudar.** Um pod Guaranteed (requests = limits) só pode ser redimensionado mantendo requests iguais aos limits. Para baixar requests mantendo os limits, o pod precisa nascer Burstable ([`examples/01-app-deployment.yaml`](examples/01-app-deployment.yaml)).
- **`resizePolicy`** por recurso é `NotRequired` (padrão, sem reinício) ou `RestartContainer`.
- **Reduzir o limit de memória é best effort.** Se o uso atual estiver acima do novo limit, o kubelet mantém o resize "em andamento" e não o aplica.
- **Use strategic merge patch (padrão do kubectl) ou JSON patch.** `--type merge` substitui a lista inteira de containers, e o API server rejeita o pedido. **(lab)**
- **O template do Deployment não muda.** Pods novos (scale-out, reagendamento após drain de nó) nascem com o tamanho do template. Ferramentas de GitOps não veem drift.
- O RBAC da automação precisa de `get` e `patch` em `pods/resize`. **(lab)**
- O Kubernetes 1.36 traz em beta o in-place resize de recursos no nível do pod (`spec.resources`), útil para pods com vários containers ([blog](https://kubernetes.io/blog/2026/04/30/kubernetes-v1-36-inplace-pod-level-resources-beta/)).

**Resultados do lab (Kubernetes 1.36.4):**

| Teste | Resultado |
|---|---|
| Requests 500m/256Mi → 25m/64Mi, limits inalterados | Aplicado, `restartCount` 0. `cpu.weight` foi de 59 para 6; `cpu.max` e `memory.max` inalterados |
| Requests iguais aos limits (Burstable → Guaranteed) | Rejeitado: "Pod QOS Class may not change as a result of resizing" |
| Request de memória 64Mi em container usando ~200Mi | Aplicado, sem reinício |
| Limit de memória 400Mi → 128Mi em container usando ~200Mi | Não aplicado; condição `PodResizeInProgress`; o limit real continuou 400Mi |
| Limit de memória 400Mi → 300Mi (acima do uso) | Aplicado, sem reinício |
| Requests de volta para 500m/256Mi | Aplicado, sem reinício |

Outra observação do lab: depois de reduzir o request de memória, o `oom_score_adj` do container continuou com o valor calculado a partir do request original. Não conte com um request menor tornando o pod uma vítima mais provável do OOM killer do kernel. A ordem de eviction do kubelet, por outro lado, usa o request atual.

### 5.2 Vertical Pod Autoscaler

**Instalação no OKE** com o Helm chart oficial, em vez do script da época do VPA 0.8 que aparece no guia do OKE:

```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm upgrade --install vpa autoscaler/vertical-pod-autoscaler --version 0.15.0 -n kube-system
# Métricas: habilite antes o add-on "Kubernetes Metrics Server" do OKE.
```

**Modos de atualização no VPA 1.8** ([referência da API](https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/docs/api.md)):

| Modo | Comportamento | Quando usar |
|---|---|---|
| `Off` | Só recomenda | Sempre comece por aqui ([`02`](examples/02-vpa-recommend-only.yaml)) |
| `Initial` | Define requests só na criação do pod | Em conjunto com outro controlador que redimensiona depois |
| `Recreate` | Faz eviction dos pods para aplicar mudanças | Legado; `Auto` está deprecated e significa o mesmo |
| `InPlaceOrRecreate` | Redimensiona in-place e só faz eviction se falhar | Escolha padrão (GA desde o VPA 1.6) ([`03`](examples/03-vpa-inplace.yaml)) |
| `InPlace` | Redimensiona in-place, nunca faz eviction | Alpha (VPA 1.7, `--feature-gates=InPlace=true`) |

Política recomendada para este caso (de [`examples/03-vpa-inplace.yaml`](examples/03-vpa-inplace.yaml)):

```yaml
spec:
  updatePolicy:
    updateMode: "InPlaceOrRecreate"
    minReplicas: 1                     # permite atualizar workloads com uma réplica
  resourcePolicy:
    containerPolicies:
      - containerName: app
        controlledValues: RequestsOnly # mantém os limits como escritos
        minAllowed: { cpu: 25m, memory: 128Mi }
        maxAllowed: { cpu: "2", memory: 2Gi }
```

`RequestsOnly` mantém o limit de memória como teto fixo de segurança. Também mantém o limit de CPU, que a JVM e outros runtimes leem na inicialização para dimensionar seus pools de threads.

**No que o VPA é bom e no que não é.** O recommender mantém um histograma de uso de 8 dias com decaimento exponencial ([flags](https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/docs/flags.md)):

- O alvo de CPU é o percentil 90 do uso.
- O alvo de memória é o percentil 90 dos *picos* diários.
- Margem de segurança de 15% sobre os dois.
- Pisos de 25m de CPU e 250 MB de memória por pod.

Ou seja, o VPA dimensiona o pod para o dia de pico. Ele não encolhe o pod à noite. Use o VPA como ferramenta de rightsizing e um mecanismo separado (5.4) para os períodos ociosos.

**Resultados do lab:**
- Com o workload "hamster" do upstream (request de 100m, consome cerca de 500m), o `InPlaceOrRecreate` subiu o request para 587m em cerca de dois minutos, no mesmo pod e sem reinícios.
- O VPA também subiu o request de memória de 50Mi para 250Mi por causa do piso padrão de 250 MB. Para pods muito pequenos, reduza `--pod-recommendation-min-memory-mb` no recommender.

### 5.3 CPU startup boost: regime pequeno, inicialização rápida

Um request de CPU pequeno atrasa a inicialização quando o nó está ocupado, e um limit de CPU baixo atrasa sempre. Runtimes com JIT sofrem mais. O startup boost dá mais CPU ao pod até ele ficar Ready e depois o encolhe in-place. Assim um request mínimo em regime convive com um cold start curto, e o scale-out a partir de 1 réplica também fica mais rápido.

| Opção | Situação | Exemplo |
|---|---|---|
| `startupBoost` do VPA | Alpha, VPA 1.7+, feature gate `CPUStartupBoost` no admission controller e no updater | [`04-vpa-startup-boost.yaml`](examples/04-vpa-startup-boost.yaml) |
| Operador kube-startup-cpu-boost | v0.21.3, independente do VPA | [`10-kube-startup-cpu-boost.yaml`](examples/10-kube-startup-cpu-boost.yaml) |

**Resultados do lab:**
- Boost do VPA com fator 4: o request de CPU foi de 500m para 999m na criação. O `RequestsOnly` limita o boost a logo abaixo do limit de 1 CPU para manter a classe de QoS. 30 s depois do Ready, o VPA redimensionou o pod in-place para a recomendação (25m), sem reinícios.
- O kube-startup-cpu-boost aplicou o boost na admissão e o reverteu 3 s depois, quando o pod ficou Ready.

Cuidados ([README do kube-startup-cpu-boost](https://github.com/google/kube-startup-cpu-boost)):

- Se o boost aumentar o *limit* de CPU, a JVM dimensiona seus pools para a CPU aumentada e os mantém depois da reversão. Use boosts modestos ou defina `-XX:ActiveProcessorCount`.
- Um request aumentado pode disparar um scale-up de nó que fica inútil um minuto depois. Mantenha alguma folga ou deixe o scale-down mais lento.

### 5.4 Encolher o pod aquecido nos períodos ociosos

Duas formas:

**a) Por agenda (horário comercial previsível).** [`examples/05-idle-shrinker-cronjob.yaml`](examples/05-idle-shrinker-cronjob.yaml) é uma implementação pequena e sem dependências:

- Às 20:00, de segunda a sexta, um CronJob reduz os requests dos pods que optaram pelo recurso para os valores da anotação `idle-shrink.example.com/requests`.
- Às 07:30, um segundo CronJob restaura os requests a partir do template do ReplicaSet dono do pod.
- Os limits nunca são alterados.
- Proteção de memória: o job nunca define um request de memória abaixo do uso atual + 15%. Se não houver métricas, ele não mexe na memória.

Lab: encolher e restaurar funcionaram sem reinícios. A proteção de memória subiu um alvo ocioso de 32Mi para 230Mi em um container usando 200Mi.

**b) Por evento (tráfego imprevisível).** Encolher quando o ScaledObject fica inativo e aumentar na ativação. Ainda não existe um controlador open source maduro para isso. O Kedify PodResourceProfile faz isso comercialmente, e o EPCAS da DoorDash cobre o caso só de CPU. Outra opção: manter o pod aquecido num tamanho "pequeno mas responsivo" (por exemplo, 100m de CPU) e deixar o HPA adicionar pods de tamanho cheio.

Não combine (a) com o VPA em modo `InPlaceOrRecreate`, `Recreate` ou `InPlace` no mesmo workload, porque o VPA desfaz a mudança. VPA em `Off` ou `Initial` não tem problema.

### 5.5 Regras de interação

| Combinação | Seguro? | Por quê |
|---|---|---|
| HPA/KEDA por `Utilization` de CPU + qualquer redução de requests | Não | Exemplo: request de 500m com alvo de 70% escala em 350m. Depois de encolher para 25m, escala em 17,5m |
| HPA/KEDA por `AverageValue` de CPU, taxa de requisições ou tamanho de fila + VPA/encolhedor | Sim | O sinal não depende dos requests ([`06`](examples/06-keda-cron-min-one.yaml), [`07`](examples/07-hpa-absolute-cpu.yaml)) |
| VPA (atualizando) + HPA na mesma métrica de CPU/memória | Não | Tanto o VPA upstream quanto o OKE desaconselham |
| VPA (atualizando) + encolhedor ocioso nos mesmos pods | Não | Dois escritores brigando |
| startupBoost do VPA + kube-startup-cpu-boost nos mesmos pods | Não | Escolha um |
| VPA (atualizando) + cron do KEDA com `minReplicaCount: 1` | Sim | Camadas diferentes |

---

## 6. CPU ou memória: qual redução economiza mais?

### 6.1 Preço por unidade

No Kubernetes, `1` CPU = 1 vCPU. Nos shapes x86, 1 OCPU = 2 vCPUs. No Ampere A1, 1 OCPU = 1 vCPU. No A2, 1 OCPU = 2 cores.

| Shape | USD por vCPU-hora | USD por GB-hora | GB de RAM que custam o mesmo que 1 vCPU |
|---|---|---|---|
| E4 Flex (AMD) | 0,0125 | 0,0015 | 8,3 |
| E5 Flex (AMD) | 0,0150 | 0,0020 | 7,5 |
| E6 Flex (AMD) | 0,0150 | 0,0020 | 7,5 |
| A1 Flex (Ampere) | 0,0100 | 0,0015 | 6,7 |
| A2 Flex (AmpereOne) | 0,0070 | 0,0020 | 3,5 |

Serviços típicos pedem de 1 a 4 GB por vCPU, bem abaixo desses pontos de equilíbrio. A CPU é a maior parte da conta, a menos que o pod peça mais de cerca de 7 GB por vCPU nos shapes AMD.

### 6.2 Para onde vai o dinheiro em um pod (E5 Flex, 24x7)

| Requests | CPU USD/mês | Memória USD/mês | Participação da CPU |
|---|---|---|---|
| 1000m / 2Gi | 10,95 | 3,14 | 78% |
| 500m / 1Gi | 5,47 | 1,57 | 78% |
| 250m / 1Gi | 2,74 | 1,57 | 64% |
| 50m / 1Gi | 0,55 | 1,57 | 26% |

Depois que a CPU é reduzida, a memória vira a maior parte do que sobra. E a memória só pode ser reduzida além disso mudando a aplicação (6.4).

### 6.3 O que acontece quando cada um fica baixo demais

**CPU baixa demais:**

- Abaixo do request, nada acontece. Sob disputa, o container recebe CPU proporcional ao request, e a CPU livre é compartilhada.
- No limit, o kernel faz throttling do container: a latência sobe e nada é morto.
- Risco indireto: uma liveness probe que estoura o timeout por causa do throttling reinicia o container. Use timeouts generosos e não faça trabalho pesado dentro das probes.

**Memória baixa demais.** Três mecanismos diferentes podem matar ou mover um pod ([node-pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)):

| Mecanismo | Gatilho | Resultado | Controlado por |
|---|---|---|---|
| OOM kill do container | Uso do container > **limit** de memória | O kernel mata o processo; o kubelet reinicia o container (cold start) | Limit de memória |
| Eviction pelo kubelet | Memória disponível do nó abaixo do limiar de eviction | O pod é apagado e recriado em outro lugar (cold start). Pods com uso acima do **request** saem primeiro, depois por prioridade, depois por quanto passam do request | Request de memória, PriorityClass |
| OOM do nó | O nó esgota a memória antes de o kubelet reagir | O kernel mata pelo `oom_score_adj`: BestEffort 1000, Burstable 2–999 (request menor = score maior), Guaranteed −997 | Classe de QoS, request |

Então a preocupação de que pods morrem com pouca memória está correta, e ela se divide em duas:

- **Limits decidem OOM kills.** Mantenha o limit de memória no pico + folga e nunca o reduza in-place abaixo do uso atual. O kubelet não aplica essa mudança **(lab)**, mas um pico de uso logo depois da verificação ainda é possível.
- **Requests decidem a ordem de eviction e o quanto o scheduler aperta os pods.** Um request de memória abaixo do uso real não libera RAM nenhuma. Ele só deixa o scheduler colocar mais pods no nó e transforma esse pod em uma das primeiras vítimas de eviction. Essa economia é falsa, a menos que o uso tenha caído de fato.

### 6.4 O comportamento em repouso é diferente

- **CPU:** um serviço ocioso usa poucos millicores. Baixar o request de 500m para 25–50m reflete a realidade, então a economia é real e de baixo risco.
- **Memória:** um serviço ocioso mantém a maior parte do working set (heap, caches, pools de conexão). O Kubernetes não consegue fazer o processo devolver memória. Isso precisa acontecer no runtime, por exemplo:
  - JVM: o tamanho do heap vem de `-Xmx` ou `MaxRAMPercentage` na inicialização, e a JVM não aumenta o heap depois de um aumento de limit in-place. O G1 devolve heap não usado em repouso com `-XX:G1PeriodicGCInterval`. ZGC e Shenandoah devolvem memória ociosa por padrão. Dimensione o heap pela necessidade real.
  - Go: defina `GOMEMLIMIT` perto do request alvo.
  - Node.js: limite `--max-old-space-size`.
  - .NET: o Server GC mantém heaps grandes. DATAS (ligado por padrão desde o .NET 9) ou `GCConserveMemory` os reduzem, e o Workstation GC é ainda menor.
- Por isso, o in-place resize de memória serve principalmente para os *requests* (agendamento), não para o consumo real do processo.

### 6.5 Comparação de cenários (30 serviços, E5 Flex)

Horário comercial: segunda a sexta, 08:00–20:00 (60 h/semana), com 3 réplicas × (500m, 1Gi). O resto da semana (108 h) varia:

| Estratégia fora do expediente | USD/mês | Economia vs sempre ligado |
|---|---|---|
| A. Sem mudança, 3 réplicas | 634 | 0% |
| B. 1 réplica, tamanho cheio | 362 | 43% |
| C. 1 réplica, request de CPU 50m, memória 1Gi | 267 | **58%** |
| D. 1 réplica, CPU 500m, request de memória 512Mi | 347 | 45% |
| E. 1 réplica, CPU 50m + memória 768Mi | 260 | 59% |
| F. 0 réplicas (scale-to-zero de verdade) | 226 | 64% |

Cortar a memória pela metade (D) acrescenta 2 pontos sobre B. Cortar a CPU (C) acrescenta 15. C chega a cerca de 90% da economia de F sem nenhum cold start.

### 6.6 Conclusão

1. **A CPU economiza mais e é mais segura de cortar.** Reduza os requests de CPU em repouso para 25–50m. Mantenha um limit de CPU nos serviços JVM (ele fixa a contagem de processadores que a JVM enxerga), ou defina `-XX:ActiveProcessorCount`. Para outros runtimes, o limit é opcional.
2. **Memória:** request = working set medido em repouso + 10–15%; limit = pico + folga. Reduções adicionais vêm de ajustes no runtime, não do Kubernetes.
3. **Depois de cortar a CPU, a memória domina o custo restante.** Escolha shapes com mais GB por OCPU (shapes flex permitem até 64 GB/OCPU) para não pagar CPU ociosa nos próprios nós.

---

## 7. Camada horizontal: nunca zero, raramente mais que o necessário

[`examples/06-keda-cron-min-one.yaml`](examples/06-keda-cron-min-one.yaml):

```yaml
spec:
  minReplicaCount: 1               # um pod aquecido, sem cold start para o primeiro usuário
  maxReplicaCount: 10
  triggers:
    - type: cron                   # pré-aquecer antes de os usuários chegarem
      metadata: { timezone: America/Sao_Paulo, start: "15 7 * * 1-5", end: "0 20 * * 1-5", desiredReplicas: "3" }
    - type: cpu
      metricType: AverageValue     # não Utilization: imune a mudanças de request
      metadata: { value: "400m" }
```

Lab: o KEDA criou um HPA com a métrica externa do cron e `cpu: AverageValue 400m`, como esperado.

Pontos práticos:

- **Pré-aquecer e restaurar.** Rode a restauração do horário comercial (5.4) e o scale-up do cron 15–30 minutos antes do tráfego chegar, para que a subida da manhã nunca espere um cold start.
- **Gatilhos por taxa de requisições** (scaler de Prometheus ou as métricas do KEDA HTTP add-on) acompanham a carga dos usuários melhor que a CPU.
- **Scale-out rápido a partir de 1** também precisa de capacidade de nó. Adicionar um nó no OKE leva minutos (imagens OKE reduzem o tempo de provisionamento em mais da metade em relação às imagens de plataforma). Para serviços sensíveis a latência, mantenha alguns pods "placeholder" de baixa prioridade: os pods reais os preemptam na hora, e o autoscaler adiciona um nó para os placeholders despejados em segundo plano.
- **Não-produção pode ir a zero de verdade.** Ninguém espera um cold start de madrugada. Use o padrão documentado pela Oracle de cron do KEDA (+ HTTP add-on para acordar com a primeira requisição) e um node pool com mínimo 0 ([blog da Oracle](https://blogs.oracle.com/cloud-infrastructure/optimizing-oke-costs-with-keda-and-cluster-autoscaling)), ou o GoKubeDownscaler.

---

## 8. Camada de nós: transformar requests menores em uma conta menor

### 8.1 Cluster Autoscaler (add-on do OKE)

Configuração: [`examples/09-oke-cluster-autoscaler-addon.json`](examples/09-oke-cluster-autoscaler-addon.json).

```bash
oci ce cluster install-addon --cluster-id <cluster-ocid> --addon-name ClusterAutoscaler \
  --from-json file://examples/09-oke-cluster-autoscaler-addon.json
```

Configurações que importam aqui ([argumentos do add-on](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/configuration-arguments-cluster-autoscaler.htm)):

| Chave | Padrão | Por que importa |
|---|---|---|
| `scaleDownUtilizationThreshold` | 0,5 | A "utilização" do nó é a soma dos **requests** / capacidade. É a redução dos requests que torna os nós removíveis. Com 0,6 os nós saem um pouco mais cedo |
| `scaleDownUnneededTime` | 10m | Quanto tempo o nó precisa ficar abaixo do limiar |
| `skipNodesWithLocalStorage` | true | Pods com `emptyDir` bloqueiam o scale-down. Coloque false se o conteúdo do emptyDir for descartável |
| `nodes` | | `min:max:pool-ocid`. Pools de aplicação em produção com mínimo ≥ 1, pools de não-produção com mínimo 0 |

Boa prática do OKE: mantenha um node pool fora do controle do autoscaler para os pods de sistema e para o próprio autoscaler ([boas práticas](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengbestpractices_topic-Autoscaler-best-practices.htm)). Problema conhecido: quando um pool sobe a partir de zero, o autoscaler superestima em 2x a CPU de shapes flex Arm, o que custa um ciclo extra de escalonamento ([kubernetes/autoscaler#9337](https://github.com/kubernetes/autoscaler/issues/9337)).

### 8.2 Karpenter Provider for OCI

[`examples/08-karpenter-oci-burstable-and-preemptible.yaml`](examples/08-karpenter-oci-burstable-and-preemptible.yaml) (validado contra os CRDs do KPO v1.4.0) define:

- um pool **low-cpu** em nós burstable E5/E4 Flex, com consolidação `WhenEmptyOrUnderutilized`;
- um disruption budget que bloqueia a consolidação das 07:00 às 19:00, de segunda a sexta (horário de São Paulo). Os schedules dos budgets do Karpenter não suportam fuso horário, então ficam escritos em UTC;
- um pool **preemptible** (`spot` no Karpenter, que o KPO mapeia para preemptible da OCI), que exige o taint `oci.oraclecloud.com/oke-is-preemptible`.

Comparado ao Cluster Autoscaler, o Karpenter consegue trocar um nó meio vazio por um menor e misturar shapes em uma única política. Isso importa quando os requests fora do expediente encolhem de forma desigual. Não deixe os dois autoscalers cuidarem dos mesmos pods ([guia de migração](https://blogs.oracle.com/cloud-infrastructure/migrating-to-karpenter-from-cluster-autoscaler)).

### 8.3 Consolidação significa cold starts

Remover um nó significa fazer eviction dos pods dele, e cada pod despejado paga um cold start. Mitigações:

- Rode 2 réplicas com um PodDisruptionBudget (`maxUnavailable: 1`) no horário comercial. A segunda réplica sai barata depois do corte de CPU.
- Permita consolidação só na janela da noite (budgets do Karpenter), logo depois do encolhimento, com tráfego baixo.
- Mantenha o cold start curto com startup boost (5.3).
- Para um serviço de réplica única que nunca pode ser movido, anote com `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` ou `karpenter.sh/do-not-disrupt: "true"`. Esse nó passa a ficar, então use com moderação.

### 8.4 Alavancas de preço de nó para o pod aquecido (50m / 1Gi, 24x7)

| Onde roda | USD/mês |
|---|---|
| E5 Flex, on-demand | 2,12 |
| E5 Flex burstable, baseline de 50% | 1,84 |
| E5 Flex burstable, baseline de 12,5% | 1,64 |
| A1 Flex (Arm), on-demand | 1,54 |
| Virtual node (Pod.Standard.E4.Flex) | 20,44 + US$ 0,015/h por virtual node |

- **Nós burstable** são overcommit de CPU com o preço já embutido pela OCI:
  - O Kubernetes vê todas as vCPUs, e você paga pelo baseline.
  - Se a CPU *média* do nó ficar abaixo do baseline, todo pod recebe o que pede. Se ficar acima, a OCI limita o nó inteiro e todos os pods ficam lentos.
  - Servem para não-produção e para serviços que passam a maior parte do tempo ociosos. O exemplo 08 também mostra a variante mais segura com `kubeReserved`, que esconde do scheduler a CPU acima do baseline.
  - Para um pod com CPU já reduzida o ganho é pequeno (a memória domina). O ganho é grande em pools onde os requests continuam altos e o uso é baixo.
- **Virtual nodes** não servem para pods pequenos. Requests precisam ser iguais aos limits, tamanhos abaixo de 1 core não são suportados, a alocação arredonda para OCPUs inteiras e GB inteiros mais 0,25 GB de overhead, e o VPA não funciona lá ([alocação de recursos](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengvirtualnodepodresourceallocation.htm), [comparação](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengcomparingvirtualwithmanagednodes_topic.htm)). São úteis como capacidade de pico stateless sobre os managed nodes ([blog da Oracle sobre cluster misto](https://blogs.oracle.com/cloud-infrastructure/mixed-oke-cluster-karpenter-and-virtual-nodes)).
- **Preemptible (−50%)** serve para a 2ª até a N-ésima réplica de serviços stateless, batch e CI. Nunca para a única réplica aquecida.
- **Arm (A1/A2)** tem a CPU mais barata, se suas imagens forem multi-arch.

---

## 9. Plano de adoção sugerido

| Fase | Ações | Critério de saída |
|---|---|---|
| 0. Medir (1–2 semanas) | Todo container com requests. Instalar Metrics Server (add-on), VPA em modo `Off` ([`02`](examples/02-vpa-recommend-only.yaml)), OpenCost ou Goldilocks | CPU/memória em repouso e no pico conhecidas por serviço; custo por namespace visível |
| 1. Rightsizing | Aplicar as recomendações do VPA, via GitOps ou `InPlaceOrRecreate` + `RequestsOnly` ([`03`](examples/03-vpa-inplace.yaml)). Mudar os HPAs para `AverageValue` ou taxa de requisições | Requests a ~20% do p90 de uso; sem OOM kills nem alertas de throttling |
| 2. Aquecido e mínimo fora do expediente | KEDA `minReplicaCount: 1` + pré-aquecimento por cron ([`06`](examples/06-keda-cron-min-one.yaml)); encolhedor ocioso ([`05`](examples/05-idle-shrinker-cronjob.yaml)) ou VPA, não os dois; startup boost ([`04`](examples/04-vpa-startup-boost.yaml) ou [`10`](examples/10-kube-startup-cpu-boost.yaml)). Não-produção a zero | Requests de CPU à noite ≥ 80% menores; latência da primeira requisição inalterada |
| 3. Capacidade | Ajustar o add-on do Cluster Autoscaler ([`09`](examples/09-oke-cluster-autoscaler-addon.json)) ou adotar o KPO com janelas de consolidação ([`08`](examples/08-karpenter-oci-burstable-and-preemptible.yaml)); pool burstable para serviços de pouca CPU; preemptible para réplicas extras; proporções flex com mais memória | O número de nós acompanha os requests em até ~30 min após o encolhimento |
| 4. Cold start | Medir o tempo de inicialização; melhorias no runtime (class-data sharing / cache AOT, imagens nativas, inicialização lazy) | Se o cold start ficar curto o bastante, reavaliar o zero de verdade para alguns serviços |

---

## 10. Riscos e ressalvas

| Risco | Mitigação |
|---|---|
| Request de memória abaixo do uso real → eviction precoce sob pressão de memória | Request ≥ working set em repouso + 10–15% (o encolhedor garante isso); PriorityClass para serviços críticos |
| Limit de memória reduzido abaixo do uso → OOM kill | Nunca reduzir limits in-place; VPA com `RequestsOnly` |
| Avalanche de scale-out do HPA depois de encolher requests | Só métricas `AverageValue` ou de taxa de requisições |
| Consolidação despeja o pod aquecido → cold start | 2 réplicas + PDB durante o dia; janelas de consolidação; startup boost |
| Nó burstable acima do baseline por muito tempo → todos os pods lentos | Só pools de pouca CPU; acompanhar a métrica `CpuUtilization` da OCI; ou usar a variante com `kubeReserved` |
| Recursos alpha (VPA `InPlace`, `CPUStartupBoost`) | Testar em não-produção; o caminho GA é `InPlaceOrRecreate` + kube-startup-cpu-boost |
| Pools de threads da JVM dimensionados para um limit de CPU aumentado | Boost só nos requests (`RequestsOnly`), fatores modestos ou `-XX:ActiveProcessorCount` |
| O lab usou containerd, o OKE usa CRI-O | Repetir os testes in-place em um cluster OKE de desenvolvimento antes de produção |

---

## 11. Perguntas em aberto para o time

As respostas mudariam algumas recomendações:

1. **Runtime e tempo de inicialização** (JVM/Spring, .NET, Node, Go?) e quanto dura um cold start hoje. Isso define quanto o startup boost e os ajustes de runtime ajudam, e se o zero de verdade se torna viável.
2. **Formato do tráfego:** horário comercial previsível (encolher por agenda basta) ou imprevisível (precisa encolher por evento)?
3. **Ambientes:** quanto do gasto é não-produção? Essa parte já pode ir a zero hoje.
4. **Configuração do cluster:** clusters enhanced ou basic, versão do Kubernetes, e qual autoscaler de nós (Cluster Autoscaler ou KPO)?
5. **Preço:** pay-as-you-go ou tarifa negociada? As proporções continuam as mesmas, a economia absoluta muda.

---

## Apêndice A. Arquivos

| Caminho | Conteúdo |
|---|---|
| `examples/01-app-deployment.yaml` | Workload com QoS Burstable pronto para in-place resize, PDB, labels de opt-in |
| `examples/02-vpa-recommend-only.yaml` | VPA em modo `Off` |
| `examples/03-vpa-inplace.yaml` | VPA `InPlaceOrRecreate`, `RequestsOnly`, mín/máx |
| `examples/04-vpa-startup-boost.yaml` | Igual ao 03 mais CPU Startup Boost (alpha) |
| `examples/05-idle-shrinker-cronjob.yaml` | RBAC + script + CronJobs para encolher in-place fora do expediente |
| `examples/06-keda-cron-min-one.yaml` | ScaledObject do KEDA: mínimo 1, pré-aquecimento por cron, CPU absoluta |
| `examples/07-hpa-absolute-cpu.yaml` | HPA simples com `AverageValue` |
| `examples/08-karpenter-oci-burstable-and-preemptible.yaml` | OCINodeClass/NodePool do KPO: pool burstable com janelas de consolidação, pool preemptible |
| `examples/09-oke-cluster-autoscaler-addon.json` | Configuração do add-on Cluster Autoscaler do OKE |
| `examples/10-kube-startup-cpu-boost.yaml` | Recurso StartupCPUBoost |
| `lab/run-lab.sh` | Reproduz todos os resultados **(lab)** no kind; `--delete` remove o cluster |
| `lab/cost-model.py` | Gera as tabelas de custo das seções 6 e 8 |

Os comentários dentro dos manifestos estão em inglês.

## Apêndice B. Fontes

- OKE: [versões suportadas](https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengaboutk8sversions.htm), [release notes](https://docs.oracle.com/iaas/releasenotes/services/conteng/), [Kubernetes 1.35 no OKE](https://blogs.oracle.com/cloud-infrastructure/oke-welcomes-kubernetes-1-35), [VPA no OKE](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengusingverticalpodautoscaler.htm), [Cluster Autoscaler](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengusingclusterautoscaler.htm), [argumentos do add-on CA](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/configuration-arguments-cluster-autoscaler.htm), [boas práticas de autoscaler](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengbestpractices_topic-Autoscaler-best-practices.htm), [KPO](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/conteng-kpo.htm), [GA do KPO](https://blogs.oracle.com/cloud-infrastructure/smarter-kubernetes-autoscaling-with-karpenter), [KEDA + CA no OKE](https://blogs.oracle.com/cloud-infrastructure/optimizing-oke-costs-with-keda-and-cluster-autoscaling), [recursos de virtual nodes](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengvirtualnodepodresourceallocation.htm), [virtual vs managed nodes](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengcomparingvirtualwithmanagednodes_topic.htm), [basic vs enhanced](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengcomparingenhancedwithbasicclusters_topic.htm), [nós preemptible](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengusingpreemptiblecapacity.htm).
- OCI Compute: [instâncias burstable](https://docs.oracle.com/en-us/iaas/Content/Compute/References/burstable-instances.htm), [cobrança burstable](https://blogs.oracle.com/cloud-infrastructure/run-your-low-cpu-workloads-more-cost-effectively-with-burstable-vms), [instâncias preemptible](https://docs.oracle.com/en-us/iaas/Content/Compute/Concepts/preemptible.htm), [definição de OCPU do Ampere A2](https://blogs.oracle.com/cloud-infrastructure/introducing-oci-ampere-a2-arm-cloud-compute), [API de preços](https://apexapps.oracle.com/pls/apex/cetools/api/v1/products/?currencyCode=USD).
- Kubernetes: [in-place resize](https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/), [blog do GA na 1.35](https://kubernetes.io/blog/2025/12/19/kubernetes-v1-35-in-place-pod-resize-ga/), [resize de recursos no nível do pod (beta 1.36)](https://kubernetes.io/blog/2026/04/30/kubernetes-v1-36-inplace-pod-level-resources-beta/), [HPA scale-to-zero beta](https://kubernetes.io/blog/2026/09/02/kubernetes-v1-37-hpa-scale-to-zero-beta/), [node-pressure eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/).
- VPA: [features](https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/docs/features.md), [flags](https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/docs/flags.md), [limitações conhecidas](https://github.com/kubernetes/autoscaler/blob/master/vertical-pod-autoscaler/docs/known-limitations.md), [AEP-7862 CPU startup boost](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler/enhancements/7862-cpu-startup-boost), [release do VPA 1.8.0](https://github.com/kubernetes/autoscaler/releases/tag/vertical-pod-autoscaler-1.8.0).
- Ferramentas: [KEDA](https://keda.sh), [KEDA HTTP add-on](https://github.com/kedacore/http-add-on), [kube-startup-cpu-boost](https://github.com/google/kube-startup-cpu-boost), [Kedify PodResourceProfile](https://docs.kedify.io/how-to/prp-shrink-pod-instead-of-scale-to-zero/), [EPCAS](https://github.com/doordash-oss/elastic-cpu-pod-autoscaler), [OpenCost na OCI](https://www.opencost.io/docs/configuration/oracle), [disruption no Karpenter](https://karpenter.sh/docs/concepts/disruption/).
