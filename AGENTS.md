# AGENTS.md

## 범위

- `ai-factory`는 Kubernetes 기반 AI-native 애플리케이션 개발용 인프라를 관리한다. LiteLLM 같은 공통 서비스가 후속 배포 대상이다.
- Windows WSL2와 macOS Lima의 로컬 환경을 우선하고 이후 클라우드로 확장한다. 현재 구현·검증 범위는 Windows이며, 미래 목표를 이미 구현한 것으로 표현하지 않는다.
- OpenTofu의 인프라 수명주기, Ansible의 게스트 구성, Kubernetes 애플리케이션 배포를 구분한다.
- 프로젝트명은 `ai-factory`지만 기존 실행 이름 `infra`, `infra.ps1`, `LOCALAPPDATA/infra`, `/opt/infra`와 소유권 marker는 유지한다. 실행 이름 변경은 별도 승인된 마이그레이션으로 다룬다.
- `my-desk-setup`과 독립된 저장소다. 다른 배포판·VM·저장소는 변경하지 않는다.
- 구현은 feature branch에서 수행한다. remote 생성, push, PR, merge는 별도 사용자 승인 대상이다.
- 문서·계획·검증 기록은 이 저장소의 `docs/`가 소유한다. 상위 워크스페이스에는 작성하지 않는다.

## 안전

- 기존 같은 이름의 배포판을 자동 채택하지 않는다. 저장된 소유자 ID, WSL 등록 ID, 설치 경로를 확인한다.
- 전역 `.wslconfig`, WSL 기본 배포판, 시스템 PATH, 방화벽을 자동 변경하지 않는다. `wsl --shutdown`을 사용하지 않는다.
- 삭제는 정확한 대상과 소유권을 확인하고 명시적인 확인 값을 요구한다. 일반 apply에서 삭제·재생성을 자동 승인하지 않는다.
- kubeconfig, 인증서, private key, state, plan binary, 다운로드, 로그, 개인 경로는 `.local/` 등 Git 제외 영역에만 저장한다.
- 새 도구·이미지는 공식 출처의 고정 버전과 SHA-256으로 검증한다. 미검증 해시를 만들거나 `latest`를 설치 기본값으로 사용하지 않는다.

## 검증

- PowerShell 5.1에서 동작해야 한다. 테스트는 기존 WSL을 생성·시작·중지·삭제하지 않아야 한다.
- OpenTofu fmt/validate, PowerShell 파싱·오프라인 테스트, Ansible 문법 검사와 실제 Windows/WSL 검증을 구분한다.
- 실제 검증 전후의 대상, 성공·실패, 미실행 이유를 기록한다. 삭제 테스트는 실제 배포판이 아닌 fake runner에서 수행한다.
- 실행하지 않은 macOS 검증이나 완전한 OS 패키지 재현성을 성공으로 표현하지 않는다.
