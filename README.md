# ai-factory

AI-native 애플리케이션과 LiteLLM 같은 공통 서비스를 개발·시험할 Kubernetes 환경을
코드로 구성하는 프로젝트다. OpenTofu로 전용 실행 환경을 만들고,
Ansible로 Docker와 kind 기반 Kubernetes 클러스터를 설치한다.

현재는 **Windows WSL2에서 Ubuntu 24.04와 Kubernetes v1.37.0의 2노드 클러스터**
(control-plane 1개, worker 1개)를 구성한다. macOS/Lima와 클라우드는 향후 지원 대상이며,
Argo CD·공유 PostgreSQL·LiteLLM은 별도 앱 배포 명령으로 설치한다. 프로덕션 운영용 클러스터가 아닌 로컬 개발 환경이다.

## 전제조건

- **Windows x64(AMD64)**와 로컬 스크립트 실행이 허용된 **Windows PowerShell 5.1**.
  아래 명령은 WSL 터미널이 아니라 Windows PowerShell에서 실행한다.
- **WSL2 설치 및 가상화 활성화**. 게스트에서 systemd와 cgroup v2를 사용할 수 있어야 한다.
  WSL이 없다면 먼저 [Microsoft WSL 설치 안내](https://learn.microsoft.com/windows/wsl/install)를 따른다.
- **Windows 기본 `tar.exe`**. 소스를 WSL로 복사할 때 사용한다.
- **호스트와 WSL의 인터넷 연결**. Ubuntu, GitHub, Docker, PyPI, Kubernetes 배포 서버에서
  이미지와 패키지를 내려받는다.
- **로컬 포트 `16443`, `18080`이 비어 있고 Windows에서 WSL의 localhost 서비스에 접근 가능**해야 한다.
- 최초 설치 시 다른 용도로 만든 **`infra` WSL 배포판이 없어야 한다**. 같은 이름의 배포판을 자동으로 가져다 쓰거나 삭제하지 않는다.

설치 전에 WSL 버전과 기존 배포판을 확인한다.

```powershell
wsl --version
wsl --list --verbose
```

실제 검증 환경은 WSL 2.7.10.0의 mirrored networking 환경이다. 다른 네트워크 설정에서의
동작과 최소 CPU·메모리·디스크 요구량은 아직 검증하지 않았다.
전역 WSL 설정, 기본 배포판, 방화벽, 시스템 PATH는 설치 스크립트가 바꾸지 않는다.

**OpenTofu, Ansible, Docker, kind, kubectl은 미리 설치할 필요가 없다.**
프로젝트가 고정 버전을 설치하며, Docker Desktop도 필요하지 않다.

## 설치

프로젝트 소스를 준비한 뒤 Windows PowerShell에서 **`infra.ps1`이 있는 프로젝트 루트**로
이동한다. 운영 스크립트 이름은 `infra.ps1`, 생성되는 WSL 배포판과 클러스터 이름은 `infra`다.

다음 명령을 순서대로 실행하고, 각 명령이 성공한 뒤 다음 단계로 진행한다.

```powershell
# OpenTofu와 Ubuntu 이미지를 다운로드하고 체크섬 검증
.\infra.ps1 Bootstrap

# 인프라 변경 계획 생성 및 삭제·재생성 여부 검사
.\infra.ps1 Plan

# 전용 WSL 환경 생성 및 Kubernetes 설치
.\infra.ps1 Apply

# 설치 결과 확인 — 정상 상태는 ready
.\infra.ps1 Doctor
```

첫 Apply에서는 OS 패키지와 컨테이너 이미지를 내려받으므로 시간이 걸릴 수 있다.
설치 버전은 [versions.json](versions.json)에서 확인할 수 있다.

## Argo CD and LiteLLM

기반 클러스터 설치 후 [LLM 게이트웨이 운영 안내](docs/litellm.md)를 따른다.
PostgreSQL은 다른 서비스도 별도 DB·계정으로 연결할 수 있는 독립 Kustomize 컴포넌트이며, LiteLLM과 별도 Argo CD Application으로 관리한다.
초기 LLM 모니터링은 LiteLLM Admin UI의 사용량·토큰·비용·요청 로그를 사용한다.

## 실행 확인과 클러스터 사용

설치가 끝나면 클러스터가 실행 중이다. WSL에 설치된 kubectl로 노드를 확인한다.

```powershell
wsl -d infra -u root --exec kubectl --kubeconfig /opt/infra/.local/kubeconfig get nodes
```

`infra-control-plane`, `infra-worker` 두 노드가 모두 `Ready`여야 한다.
샘플 앱을 배포해 Windows에서도 접근할 수 있는지 확인한다.

```powershell
.\infra.ps1 Smoke
(Invoke-WebRequest -UseBasicParsing http://127.0.0.1:18080/).Content
```

응답은 `infra-ready`다. 브라우저에서 <http://127.0.0.1:18080/>를 열어도 된다.
샘플 앱은 Smoke에서만 배포하며, Apply만 실행했을 때는 설치되지 않는다.

Kubernetes API 주소는 `https://127.0.0.1:16443`, 호스트 접속 설정은 `.local/kubeconfig`다.
Windows용 kubectl을 별도로 설치했다면 다음처럼 사용한다. 기본 kubeconfig/context는 바꾸지 않는다.

```powershell
kubectl --kubeconfig .\.local\kubeconfig get nodes
```

## 중지와 다시 시작

사용하지 않을 때는 이 프로젝트의 WSL 환경만 중지한다.

```powershell
.\infra.ps1 Stop
```

다시 사용할 때는 Apply를 실행한다. 기존 환경을 시작하고 같은 클러스터에 설정을 적용한다.

```powershell
.\infra.ps1 Apply
.\infra.ps1 Doctor
```

Windows 로그인 시 자동으로 시작하지 않는다. `.local/`에는 상태와 인증정보가 있으므로
삭제하거나 공개하지 않는다. 설치 실패나 소유권 오류도 이 디렉터리를 지워 해결하지 않는다.

## 삭제

**아래 명령은 `infra` 배포판과 그 안의 클러스터·데이터를 삭제한다.**
필요한 데이터를 먼저 백업하고, 환경을 완전히 제거하려는 경우에만 실행한다.
실제 삭제 동작은 아직 검증하지 않았다.

```powershell
.\infra.ps1 Destroy -ConfirmName infra
```

## 상세 문서

- [Windows 운영 및 구현 참고](docs/windows-reference.md): 명령별 동작, 오류 확인, 상태 관리, 내부 구성, 개발 검증
- [Windows 검증 기록](docs/verification/windows-local-kubernetes.md): 실제 구축 결과와 미검증 범위
