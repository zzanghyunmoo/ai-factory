---
title: Argo CD와 LiteLLM으로 첫 LLM 게이트웨이 구축
date: 2026-09-27
type: feat
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

## Goal Capsule

기존 소유 WSL/kind 환경에 Argo CD와 LiteLLM, PostgreSQL을 설치한다.
Argo CD가 Git의 LiteLLM 구성을 동기화하고, z.ai 실제 호출의 사용량·비용·오류 기록을 LiteLLM UI에서 확인하면 완료다.
사용자의 최소 구성 결정과 저장소 AGENTS.md가 이 계획보다 우선한다.
구현·검증은 현재 goal이 담당하며, 원격 push는 검토 가능한 변경을 만든 뒤 별도 승인받는다.

## Product Contract

### Requirements

**실행과 관찰**

- R1. 기존 `infra` 클러스터의 소유권·노드·스토리지를 유지한다.
- R2. Argo CD Non-HA가 Git에 있는 LiteLLM 단일 인스턴스와 공유 PostgreSQL 단일 인스턴스를 각각 별도 Application과 Kustomize로 관리한다.
- R3. localhost에서 Argo CD와 LiteLLM UI에 로그인하고, 가상 키로 z.ai 모델을 호출할 수 있다.
- R4. 실제 성공 호출의 토큰·비용 기록과 실패 호출의 오류 기록을 UI에서 확인한다. Coding Plan의 추정 비용은 실제 구독 청구액으로 표현하지 않는다.

**설정과 데이터**

- R5. 부트스트랩 키·비밀번호·salt는 Git 제외 `.local/`와 Kubernetes Secret에 저장한다. 제공자 키는 LiteLLM DB에 암호화해 저장한다. Git에는 포함하지 않으며 재실행으로 재생성하지 않는다. 요청·응답 본문 저장은 기본 비활성화한다.
- R6. PostgreSQL PVC는 Pod 재시작 후에도 데이터를 유지하며, 일반 재적용은 PVC와 Secret을 삭제하지 않는다.
- R7. 공식 출처의 버전·SHA256을 고정하고 PowerShell 5.1 운영 명령과 검증 기록을 제공한다.

### Scope Boundaries

Langfuse, HyperDX, ClickHouse, ingress, TLS 인증서 자동화, 외부 Secret 관리자, 고가용성과 백업 자동화는 추가하지 않는다.
특정 MCP 서버 연결은 이번 인수 조건에 포함하지 않는다.
kind 클러스터 자체 삭제 시 로컬 PVC 데이터도 사라지므로 이 구성을 운영용 영속성으로 설명하지 않는다.

## Planning Contract

- KTD1. 인프라 수명주기는 `infra.ps1`에 유지하고 앱 운영은 별도 `apps.ps1`로 제공한다. 기존 소유권·lock·guest marker 검사를 재사용한다.
- KTD2. Argo CD 공식 고정 manifest를 체크섬 검증 후 Kustomize로 image digest와 로컬 접속 설정을 적용한다. 공유 DB는 `kubernetes/postgresql/`과 `postgresql` namespace, 소비 앱은 `kubernetes/litellm/`과 `litellm` namespace로 관리한다. Argo CD는 PostgreSQL을 사용하지 않는다.
- KTD3. 앱 Secret은 운영 스크립트로 부트스트랩한다. Argo CD source는 이 공개 저장소의 승인된 branch/ref이며 자동 prune은 끈다. PVC와 Secret의 기존 상태를 확인하고 누락된 로컬 자격증명은 자동 재생성하지 않는다.
- KTD4. 공유 PostgreSQL 16에 서비스별 DB와 비관리자 계정을 만든다. 부트스트랩 명령은 PostgreSQL 준비 후 LiteLLM DB/role을 멱등 생성하고 기존 암호를 변경하지 않는다. 새 LiteLLM DB 스키마는 단일 LiteLLM 프로세스의 시작 migration으로 초기화하며 배포 전략은 Recreate다. 향후 업그레이드에는 별도 DB 백업·migration 검토가 필요하다.
- KTD5. 서비스는 ClusterIP, 접속은 localhost port-forward다. LiteLLM 모델은 Admin UI/API에서 등록하고 DB에 저장한다. z.ai의 제공자 구현은 OpenAI Chat Completions 프로토콜을 사용하며 일반/Coding Plan endpoint를 구분한다.
- KTD6. Argo CD 3.5의 공개 테스트 표에 Kubernetes 1.37이 포함되지 않으므로 이 조합은 실제 동기화로 확인한다. 설치 실패를 이유로 기존 클러스터를 재생성하지 않는다.

실제 z.ai 검증에는 사용자가 `.local/llm-provider.env`에 제공하는 키와 요금제 선택이 필요하다.
키가 없는 동안 배포·로그인·인증 거부·DB 보존 검증을 수행할 수 있지만 실제 호출 통과로 기록하지 않는다.
원격 branch 반영 승인 전에는 로컬 서버 dry-run과 직접 배포로 런타임을 확인하고, 승인 후 동일 구성을 Argo CD로 인계해 동기화까지 검증한다.

## Implementation Units

### U1. 고정 배포 구성

- **Files:** `kubernetes/argocd/`, `kubernetes/postgresql/`, `kubernetes/litellm/`, `kubernetes/bootstrap/`, `versions.json`.
- **Approach:** 공식 manifest checksum과 모든 새 이미지 digest를 고정한다. PostgreSQL PVC, probe, resources, LiteLLM 설정을 추가한다.
- **Verification:** Kustomize build, API server dry-run, 새 이미지의 공식 registry digest 비교. 순수 manifest 변경은 런타임 검증을 우선한다.

### U2. 재현 가능한 로컬 운영

- **Files:** `apps.ps1`, `scripts/windows/Apps.psm1`, `tests/windows/Test-Apps.ps1`.
- **Patterns:** `scripts/windows/Infra.psm1`의 소유권·lock·비공개 오류 로그·네이티브 인수 처리.
- **Approach:** Bootstrap, Deploy, Status와 foreground localhost Forward 명령을 구현한다. Secret 생성·재사용·누락 상태를 분리하고 기존 자격증명을 덮어쓰지 않는다.
- **Test scenarios:** 잘못된 소유권 거절, 외부 context 미사용, 자격증명 재사용, 기존 데이터에서 자격증명 누락 거절, 민감 값 출력 억제, PS5.1 구문.
- **Verification:** WSL을 건드리지 않는 오프라인 테스트와 실제 반복 배포.

### U3. 실제 호출과 운영 인수

- **Files:** `docs/verification/argocd-litellm.md`, `docs/litellm.md`, `README.md`, 필요 시 `docs/solutions/`.
- **Dependencies:** U1, U2.
- **Approach:** 기존 infra를 재개하고 배포한다. 승인된 Git ref를 Argo CD에 연결한다. UI 로그인, z.ai 모델 등록, 가상 키 호출, 오류 기록과 Pod 재시작 후 로그 보존을 검증한다.
- **Verification:** Argo CD Synced/Healthy, LiteLLM UI와 실제 성공·실패 기록, PVC/데이터 보존, 기존 노드 UID 유지. 민감정보 없는 결과만 추적한다.

## Verification Contract

- `. .\tests\windows\Run-Tests.ps1`: PowerShell에서 dot-source하여 기존 오프라인 회귀와 전체 PowerShell 구문을 검사한다.
- `powershell -File tests/windows/Test-Apps.ps1`: 앱 운영 경계 테스트.
- `kubectl kustomize`와 `kubectl apply --dry-run=server`: manifest와 클러스터 API 계약.
- `infra.ps1 Doctor`, `apps.ps1 Status`: 실제 소유 클러스터와 앱 상태.
- Windows localhost의 두 UI: 로그인과 기록 확인. 원본 화면·로그·키는 `.local/`에만 보관한다.
- 코드 검토 시 Secret 누출, 재시도 시 데이터 손실, GitOps와 수동 배포 충돌을 확인한다.

## Definition of Done

R1–R7의 관측 결과가 검증 문서에 있고, 실제 z.ai 응답 및 UI 기록과 Argo CD 동기화가 확인되어야 한다.
미제공 키, 미승인 push, 실제 검증 실패는 통과로 대체하지 않는다.
요청 범위의 문서·운영 명령이 완성되고 코드 검토에서 발견된 결함이 해소되면 종료한다.
