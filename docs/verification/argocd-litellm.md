# Argo CD and LiteLLM verification

검증일: 2026-09-27. 대상: 이 프로젝트가 소유한 Windows WSL2 `infra`와 kind `infra`.
다른 WSL 배포판, 전역 WSL 설정, kind 노드 구성은 변경하지 않았다.

## Observed results

| 검사 | 결과 |
|---|---|
| `infra.ps1 Apply` 및 소유권 검사 | 기존 두 노드 Ready, 재생성 없음 |
| Argo CD Bootstrap | 공식 v3.5.3 Non-HA 리소스 기동, UI 로그인 성공 |
| PostgreSQL | 16.15, 독립 `postgresql` namespace, 5Gi PVC Bound |
| LiteLLM | 1.102.1, 단일 Deployment Ready, Admin UI 로그인 성공 |
| DB 계정 분리 | `litellm` DB owner는 `litellm`, superuser/createdb/createrole 모두 false |
| HTTP 및 인증 | readiness 200, 인증 없는 모델 목록 요청 401 |
| 가상 키와 오류 기록 | 만료 1시간 검증 키 생성, 잘못된 모델 호출 400, UI Logs에서 실패 기록 확인 |
| z.ai 실제 호출 | Coding Plan의 `zai/glm-5.3`, 가상 키로 HTTP 200과 JavaScript 함수 응답 확인 |
| 성공 호출 DB 기록 | 입력 35·출력 20·전체 55토큰, 추정 비용 $0.000137, success 상태 확인 |
| 반복 Bootstrap/DeployLocal | 동일 자격증명으로 재적용 성공 |
| DB 재시작 | PostgreSQL StatefulSet 재시작 후 같은 PVC UID와 저장된 키 2건 유지 |
| 인프라 보존 | 반복 배포 전후 노드 UID와 자격증명 파일 SHA256 동일 |
| PowerShell 오프라인 | 기존 26개 및 앱 9개 통과, PS5.1 전체 구문 검사 통과 |
| Manifest | PostgreSQL/LiteLLM API server dry-run 및 실제 적용 통과 |

브라우저 검증은 사용자 프로필과 분리된 Chrome을 `omo:browser`의 Omowright owned engine으로 실행했다.
로그인과 Logs 페이지를 실제로 조작하고 화면을 확인했다.
증거 화면과 상세 상태는 Git 제외 `.local/apps/`에만 보관했다.
최신 모델 응답을 흉내 내는 mock은 사용하지 않았다.

## Pending acceptance

- Argo CD Application의 실제 Git 동기화: 사용자가 feature branch push를 승인했다. 현재 배포는 `DeployLocal`의 동일 Kustomize 구성을 사용하며, 게시 후 GitOps 인계와 동기화를 검증한다.
- z.ai 실제 성공 호출의 UI 표시: API와 DB의 토큰·비용 기록은 확인했고, UI Usage/Logs 표시를 확인한다. Coding Plan 추정 비용은 실제 구독 청구액과 다르다.
- 성공 호출 기록의 재시작 후 보존: 실제 호출 후 확인한다. 현재 보존 검증은 저장된 가상 키와 UI의 실패 로그를 대상으로 했다.

위 항목이 남아 있으므로 첫 목표 전체가 완료된 상태는 아니다.

## Findings resolved

- ConfigMap 변경 후 반복 배포 dry-run이 `ai-factory-apps`와 field ownership 충돌을 일으켰다. dry-run에도 실제 apply와 동일한 field manager를 지정한 뒤 같은 변경의 실제 재배포가 통과했다.
- GitOps 대기 함수가 이전 Synced/Healthy 상태를 즉시 수락할 수 있었다. hard refresh가 처리될 때까지 기다리도록 수정했다. 새 회귀 테스트의 실패를 확인한 뒤 수정하고 통과했다.
- PowerShell 기존 오프라인 테스트는 helper scope 때문에 dot-source 방식으로 실행해야 한다. 기존 코드 변경 없이 실제 통과 명령을 운영 문서에 명시했다.

검토는 워크스페이스의 순차 실행 규칙에 따라 주 세션에서 수행했다.
소유권 검사, 자격증명 재사용과 오류 출력, DB 초기화, 재시도·timeout, 독립 Kustomize와 Application 경계를 검토했다.
검토에서 발견한 위 결함은 수정했다. 아직 실행하지 못한 Git 동기화와 성공 호출의 UI·재시작 검증은 위 대기 항목으로 유지한다.

## Operational limits

Argo CD 3.5의 공개 Kubernetes 테스트 표에 1.37이 포함되지 않는다. 설치·로그인은 이 조합에서 관찰했지만 Git 동기화는 위 대기 항목이다.
일반 Pod 재시작 보존 검증은 WSL 삭제·kind 삭제·Windows 전체 재부팅 검증을 대체하지 않는다.
DB 백업 복원, 다중 사용자 운영, 고가용성, 다른 OS는 이번 검증 범위가 아니다.
OpenTofu/Ansible 설정은 변경하지 않아 해당 정적 검사를 반복하지 않았다. 기존 인프라 Apply와 앱의 실제 배포를 검증했다.
