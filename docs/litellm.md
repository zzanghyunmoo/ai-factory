# Local LLM gateway

공유 PostgreSQL, Argo CD, LiteLLM을 기존 `infra` 클러스터에 설치한다.
LLM 모니터링은 LiteLLM Admin UI의 Usage와 Logs를 먼저 사용한다.

## Components

| 컴포넌트 | 소유 경로 | 역할 |
|---|---|---|
| Argo CD 3.5.3 | `kubernetes/argocd/` | 공식 Non-HA 구성. 내부 Redis 포함 |
| PostgreSQL 16.15 | `kubernetes/postgresql/` | 공유 DB 인스턴스와 5Gi PVC |
| LiteLLM 1.102.1 | `kubernetes/litellm/` | LLM Proxy, Admin UI와 요청 기록 |

PostgreSQL과 LiteLLM은 각각 독립 namespace 및 Argo CD Application이다.
LiteLLM은 `litellm` DB와 같은 이름의 비관리자 계정만 사용한다.
다음 서비스도 공유 PostgreSQL에 별도 DB와 계정을 만들어 연결한다. PostgreSQL 관리자의 Secret을 소비 서비스에 주입하지 않는다.
Argo CD는 PostgreSQL을 사용하지 않는다. Argo CD 내부 Redis는 Argo CD가 소유한다.

## Install

Windows PowerShell 5.1에서 프로젝트 루트를 작업 디렉터리로 사용한다.

```powershell
.\infra.ps1 Apply
.\infra.ps1 Doctor
.\apps.ps1 Bootstrap
```

Bootstrap은 클러스터 소유권·게스트 상태를 검사하고 namespace, 비공개 자격증명과 Argo CD를 설치한다.
공식 Argo CD manifest는 `versions.json`의 SHA256으로 검증하고, 모든 새 컨테이너 이미지는 각 Kustomize manifest에 버전과 digest를 고정한다.
GitOps에서 사용할 공개 저장소 경로와 revision은 `kubernetes/bootstrap/*application.yaml`에 있다.
원격 반영은 프로젝트 AGENTS.md에 따라 승인받고, 해당 revision에 배포 파일이 존재하는 것을 확인한다.

```powershell
# 승인받아 게시한 Git revision을 Argo CD에 연결
.\apps.ps1 Deploy
.\apps.ps1 Status
```

Deploy는 PostgreSQL Application이 Synced/Healthy가 된 다음 LiteLLM DB/계정을 생성하고 LiteLLM Application을 연결한다.
기존 DB/계정의 암호를 변경하지 않으며, 두 Application의 자동 prune은 비활성화한다.

Git에 게시하기 전 로컬 배포 검토가 필요한 경우에만 다음 명령을 사용한다.

```powershell
.\apps.ps1 DeployLocal
```

DeployLocal은 API server dry-run 후 동일 Kustomize 구성을 직접 적용한다.
Argo CD Application이 이미 있으면 실행을 거절한다. 이후 Deploy로 같은 리소스를 GitOps에 인계한다.
서비스가 사용하는 DB 스키마 migration은 단일 LiteLLM 프로세스 시작 시 실행한다.

## Access

별도 PowerShell 터미널 두 개에서 실행한다. 각 터널은 Ctrl+C로 종료한다.
첫 터널의 `Forwarding from` 출력이 나타난 뒤 두 번째 터널을 시작한다. 초기 소유권 검사가 인스턴스 lock을 잠시 사용한다.
배포로 연결된 Pod가 교체되어 터널이 종료되면 같은 Forward 명령을 다시 실행한다.

```powershell
.\apps.ps1 Forward -Service argocd
```

```powershell
.\apps.ps1 Forward -Service litellm
```

- Argo CD: <http://127.0.0.1:18081>, 사용자 `admin`.
- LiteLLM: <http://127.0.0.1:4000/ui>, 사용자 `admin`.
- LiteLLM API: <http://127.0.0.1:4000/v1>.

모든 Service는 ClusterIP다. HTTP 터널은 loopback에만 바인딩하며 네트워크 공개용 구성이 아니다.
LiteLLM 로그인 암호와 master/salt key는 Git 제외 파일 `.local/apps/secrets.json`의 `litellm-env.stringData`에 있다.
Argo CD 초기 암호는 아래 명령으로 본인의 터미널에서 확인하고 첫 로그인 후 변경한다. 명령 결과를 문서·로그에 공유하지 않는다.

```powershell
$encoded = wsl -d infra -u root --exec kubectl --kubeconfig /opt/infra/.local/kubeconfig -n argocd get secret argocd-initial-admin-secret -o 'jsonpath={.data.password}'
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
```

## Z.ai Coding Plan

LiteLLM UI의 Models에서 모델을 등록한다.

- Provider: Z.AI (`zai`). OpenAI Chat Completions 호환 프로토콜을 사용한다.
- 모델: 계정에서 허용된 모델. 현재 예시는 `glm-5.3`, LiteLLM 표기는 `zai/glm-5.3`이다.
- API Base: `https://api.z.ai/api/coding/paas/v4`.
- API Key: 본인의 z.ai 키.
- Model Name: 클라이언트에 제공할 이름, 예: `zai-coding`.

모델 설정은 PostgreSQL에 저장하고 제공자 키는 `LITELLM_SALT_KEY`로 암호화한다.
자동 검증에 키를 제공할 때에는 `.local/llm-provider.env`에 `ZAI_API_KEY=...`를 저장하고 채팅이나 Git에 넣지 않는다.
일반 종량제 주소 `https://api.z.ai/api/paas/v4`와 Coding Plan 주소를 혼용하지 않는다.
Coding Plan은 제공자가 지원하는 도구·제품 환경에서 사용하는 구독이므로 연결하려는 클라이언트는 [z.ai 도구 안내](https://docs.z.ai/devpack/tool/others)를 확인한다.

UI의 Virtual Keys에서 해당 모델에 접근할 키를 만들고 클라이언트에는 master key 대신 이 키를 전달한다.
사용량은 Usage에서, 개별 성공·실패 요청은 Logs에서 확인한다.
Coding Plan에서 표시되는 토큰 기반 비용은 실제 구독 청구액이나 잔여 구독 한도와 같지 않다.
프롬프트·응답 본문 저장은 기본 비활성화하며 요청 메타데이터의 보존기간은 7일이다.
MCP Gateway 기능은 LiteLLM에 포함되어 있지만 이번 단계에서 특정 MCP 서버는 등록하지 않는다.

## Persistence and recovery

PostgreSQL PVC는 Pod 교체와 기존 WSL/kind 재개 후 유지된다. kind 노드·클러스터·WSL 삭제에 대한 백업은 아니다.
`.local/apps/secrets.json`은 DB 암호, master key와 암호화 salt를 포함하므로 안전하게 별도 보관한다.
파일이 사라졌는데 Secret 또는 PVC가 남아 있으면 자동으로 다른 암호를 생성하지 않는다. 원본 자격증명을 복원해야 한다.
salt를 바꾸면 기존 암호화된 제공자 키를 복호화할 수 없다.
DB major upgrade나 데이터 삭제는 이 운영 명령의 범위에 포함하지 않는다. 업데이트 전에는 별도 DB 백업과 migration 확인이 필요하다.

## Validation

오프라인 검증은 실제 WSL을 실행하지 않는다.

```powershell
. .\tests\windows\Run-Tests.ps1
.\tests\windows\Test-Apps.ps1
```

실제 검증은 [검증 기록](verification/argocd-litellm.md)을 확인한다.
Argo CD Application의 `Synced/Healthy`, PostgreSQL/LiteLLM Pod readiness, LiteLLM UI의 실제 요청 로그를 각각 확인한다.
모델 호출 성공만으로 GitOps 동기화나 데이터 보존이 검증된 것으로 간주하지 않는다.

## Sources

- [Argo CD installation](https://argo-cd.readthedocs.io/en/stable/operator-manual/installation/)
- [LiteLLM deployment](https://docs.litellm.ai/docs/proxy/deploy)
- [LiteLLM UI logs](https://docs.litellm.ai/docs/proxy/ui_logs)
- [LiteLLM Z.AI provider](https://docs.litellm.ai/docs/providers/zai)
- [Z.AI Coding Plan protocols](https://docs.z.ai/devpack/tool/others)
