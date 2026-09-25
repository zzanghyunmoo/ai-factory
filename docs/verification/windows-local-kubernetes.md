# Windows 로컬 Kubernetes 검증

검증일: 2026-09-25. **실제 구축 및 동작 검증 완료.**
전용 `infra` WSL2 배포판에서 두 Kubernetes 노드와 샘플 앱이 실행 중이다.

## 실제 결과

| 항목 | 결과 |
| --- | --- |
| 환경 | Windows amd64, PowerShell 5.1, WSL 2.7.10.0 / 커널 6.18.33.2-2 |
| 게스트 | Ubuntu 24.04, PID 1 `systemd`, `cgroup2fs` |
| 도구 | OpenTofu 1.12.6, Ansible Core 2.21.4, Docker Engine 29.8.1, kind 0.33.0, kubectl 1.37.0 |
| 노드 | `infra-control-plane`, `infra-worker` 모두 v1.37.0 / Ready |
| Kubernetes API | Windows에서 `https://127.0.0.1:16443/readyz`에 CA 검증·클라이언트 인증 후 HTTP 200 / `ok` |
| 샘플 앱 | Windows `http://127.0.0.1:18080/` → HTTP 200 / `infra-ready` |
| 노출 범위 | control-plane의 API/HTTP Docker publish 주소가 모두 `127.0.0.1`, worker publish 없음 |
| 반복 Apply | 같은 Kubernetes node UID·Docker container ID, Ansible `changed=0`, `failed=0` |
| 유휴 유지 | 다른 게스트 호출 없이 15초 대기한 뒤 Windows HTTP 200 유지 |
| Stop/Start 복구 | `Stop → Doctor(stopped) → Start → Apply → Doctor(ready) → Smoke` 성공 |
| 재시작 후 동일성 | 같은 node UID·container ID, HTTP 200. 재시작 Apply는 기존 컨테이너 시작으로 `changed=1` |
| 인증정보 권한 | 게스트 `.local` 0700, kubeconfig 0600. 호스트 상태/kubeconfig는 사용자 전용 ACL |

실제 설치 과정에서 Ansible `--syntax-check`와 playbook 실행이 성공했다.
`guard versions`로 바이너리 SHA-256, 설치된 Docker 패키지 버전, 실행 중 Docker
버전과 Ansible 버전을 확인했다. 게스트와 Windows의 기본 kubeconfig/context는 바꾸지 않았다.
Windows API 검증에 사용한 임시 인증서·키 파일은 사용자 전용 `.local` 아래 생성하고
검증 후 제거했으며 내용은 출력하지 않았다.

반복 적용에서 관측한 리캡:

```text
localhost : ok=21 changed=0 unreachable=0 failed=0 skipped=6 rescued=0 ignored=0
```

재시작 후 컨테이너를 다시 시작한 적용:

```text
localhost : ok=22 changed=1 unreachable=0 failed=0 skipped=5 rescued=0 ignored=0
```

## 정적·오프라인 검증

| 검사 | 결과와 범위 |
| --- | --- |
| PowerShell | PS 5.1 파싱 및 fake WSL/registry 기반 보호 검사 26개 통과 |
| Python | 게스트 보호 로직 unit test 14개 통과 |
| Bash | 게스트 shell 파일 4개 `bash -n` 통과 |
| OpenTofu | fmt/init/validate 통과, built-in provider만 사용 |
| 공식 다운로드 | OpenTofu ZIP·내부 exe·설치 exe 및 Ubuntu rootfs SHA-256 비교 통과 |
| Python 잠금 | Python 3.12/Linux amd64용 Ansible과 전이 wheel 의존성 9개 해시 확인·실제 설치 |
| Git 제외·공개성 | state, plan, 다운로드, 로그, kubeconfig, 복구 백업과 에이전트 산출물 제외 확인 |

이 검사들은 실제 삭제나 모든 실패 시나리오의 OS 수준 검증을 대체하지 않는다.

## 실제 검증 중 발견하고 수정한 문제

### WSL 옵션 인용

최초 실행은 모든 인수를 따옴표로 감싸 `"--import"`를 전달하면서 종료 코드 127로
실패했다. WSL의 초기 옵션 파서는 일반 Windows CRT 파서와 달리 이 따옴표를
제거하지 않는다. 공백·내부 따옴표·빈 문자열처럼 필요한 경우에만 인용하도록 고쳤다.
회귀 검사의 수정 전 실패·수정 후 통과와 실제 WSL 목록/버전 조회를 확인했다.

최초 잘못된 명령이 기본 배포판에서 실행할 명령으로 해석돼 기존 Ubuntu가 일시적으로
시작되었을 가능성이 있다. 따라서 기존 배포판을 한 번도 시작하지 않았다고 보장하지 않는다.
최종 상태와 등록 정보의 보존은 아래 범위 검증에서 별도로 확인했다.

- [WSL 옵션 분기](https://github.com/microsoft/WSL/blob/master/src/windows/common/WslClient.cpp)
- [ParseArgument 구현](https://github.com/microsoft/WSL/blob/master/src/windows/common/helpers.cpp)

### 설치 디렉터리 SYSTEM 권한

인용 수정 후에도 `Wsl/Service/ERROR_UNHANDLED_EXCEPTION`이 발생했다.
직접 Windows subprocess로 같은 import를 실행해도 동일하게 실패하여 OpenTofu나
PowerShell provisioner만의 문제는 아님을 확인했다.

같은 이미지·대상·전역 설정에서 **비어 있는 전용 WSL 설치 디렉터리에만 SYSTEM
FullControl을 추가하자 import가 성공했다.** 이를 `Protect-Directory -AllowSystem`으로
반영했다. 호스트 owner/state/plan/kubeconfig 디렉터리는 계속 현재 사용자 전용이며,
SYSTEM 허용 옵션은 VHD 설치 디렉터리에만 사용한다. 이 경계도 오프라인 검사에 추가했다.
관리자 권한 상승이나 전역 ACL 변경은 없었다. 내부 WSL 서비스의 정확한 실패 호출
스택까지 입증한 것은 아니며, 여기서 확인한 것은 이 호스트의 단일 변수 비교 결과다.

이전 실패 기록은 사용자 승인 후 `.local/recovery/`로 이동 보존했다. 성공한 import는
이 세션이 등록 부재를 확인하고 기존 preparing intent 아래 직접 생성한 대상이다.
같은 OpenTofu owner, live GUID/설치 경로, 이미지 해시와 새 guest marker를 검증한 뒤
committed로 전환했다. 기존 state를 백업하고 **검증된 해당 리소스만 untaint**했으며,
배포판 삭제·재생성은 하지 않았다. 일반 명령의 preparing 자동 채택 금지는 그대로다.

### WSL 유휴 종료와 기존 컨테이너 복구

첫 Ansible 적용은 성공했지만 클라이언트 명령이 끝난 뒤 WSL이 중지되어 앱을 계속
사용할 수 없었다. systemd 서비스만으로는 WSL 인스턴스가 유지되지 않았다.

- Apply/Start는 소유권을 확인한 `infra`에 고정된 `sleep infinity` 클라이언트를 유지한다.
- keeper 기록은 owner/GUID/PID/프로세스 시작 시각을 결합한다. 재사용 시 PID만 신뢰하지 않는다.
- Stop은 `infra`만 terminate하며 그 게스트의 keeper도 종료된다. 다른 PID를 직접 kill하지 않는다.
- 재부팅 후 기존 kind 컨테이너가 중지된 경우 Apply는 owner/config/image/정확한 container ID를
  먼저 검증한 뒤 그 컨테이너만 시작한다. 외부 컨테이너 채택이나 새 노드 생성이 아니다.
- Doctor는 중지된 컨테이너를 Ready로 인정하지 않는다.

유휴 유지, 반복 Apply, Stop/Start/Apply, 동일 ID와 호스트 HTTP 응답을 실제 확인했다.
Windows 로그인 시 자동 실행하는 서비스나 예약 작업은 설치하지 않았다.

## 범위 보존

- 최종 WSL 목록: 기존 `Ubuntu-26.04`는 **Stopped**, 새 `infra`는 **Running**.
- 기존 등록 GUID·설치 경로, 기본 배포판, `.wslconfig` 해시는 사전 기록과 동일하다.
- `wsl --shutdown`, 전체 WSL/서비스 재시작, 방화벽·시스템 PATH 변경을 실행하지 않았다.
- 실제 unregister/Destroy는 실행하지 않았다. 삭제는 fake runner에서만 검증했다.
- `my-desk-setup`과 다른 프로젝트 소스는 수정하지 않았다.
- Git commit, 원격 저장소 생성, push, PR, merge는 하지 않았다.

## 프로젝트명 변경과 경로 이동 — 2026-09-26

프로젝트를 `projects/infra`에서 `projects/ai-factory`로 이동하고 목적을 Kubernetes 기반
AI-native 애플리케이션 개발 인프라로 명시했다. LiteLLM 배포, macOS·클라우드 구현은
이번 변경에 포함하지 않았다. WSL2·kind 이름, CLI, 호스트·게스트의 실행 경로는 유지했다.

- `.git`과 `.local/`을 포함해 저장소 전체를 이동했다. 소스 변경은 README, AGENTS,
  기존 계획의 프로젝트명과 이 검증 기록뿐이며 실행 코드·버전·설정은 바꾸지 않았다.
- state, backend 메타데이터, 기존 plan, owner/keeper 기록을 `.local/recovery/`에 백업했다.
  소유권을 확인하고 인스턴스 잠금 아래 기존 local state로 backend를 재연결했다.
- 최초 폴더 이동은 작업 세션의 PowerShell 언어 서버가 경로를 잡고 있어 실패했다.
  해당 세션이 시작한 언어 서버만 종료한 뒤 이동했다. WSL과 VS Code는 종료하지 않았다.
- 첫 재연결의 경로 구분자 표기가 운영 CLI와 달라 후속 init이 거부됐다. 두 경로가 같은
  파일임을 확인하고 CLI와 동일한 표기로 다시 연결했다. 재초기화 전후 state 해시는 같았다.
- OpenTofu는 `terraform_data.wsl`의 `root`·`bridge` 경로만 in-place 갱신했다.
  state lineage, 리소스 ID, owner와 keeper 기록은 같으며 생성·삭제·재등록은 없었다.
- 새 경로에서 일반 `Apply` 성공, Ansible `changed=0`, `failed=0`, `Doctor`는 `ready`.
  이후 일반 `Plan`도 변경 없음이었다.
- 두 노드 모두 Ready이고 최초 구축 기록과 Kubernetes node UID·Docker container ID가 같다.
  Windows 인증·CA 검증 API 요청은 HTTP 200 / `ok`, 샘플 HTTP는 200 / `infra-ready`였다.
- PowerShell 26개·Python 14개 오프라인 테스트, Bash 4개 문법 검사,
  OpenTofu fmt/init/validate와 Git 제외 검사를 새 경로에서 다시 통과했다.
- 문서 LSP는 서버가 준비되지 않아 확인하지 못했다. 상대 링크와 공개 소스의
  개인 경로·private key 헤더·줄 끝 공백 검사는 별도로 통과했다.
- 기존 배포판 등록·기본 배포판·`.wslconfig`는 그대로다. 실행 중인 배포판은 `infra`뿐이다.
  commit, remote 생성, push, PR, merge는 하지 않았다.

## 남은 검증 한계

- macOS/Lima, 실제 Destroy, Windows 전체 재부팅 후 복구는 미검증이다.
- keeper 새 실행은 실제 검증했지만 PID 재사용 경쟁 조건의 전 경로를 fake test로 다루지는 않았다.
- rootfs 첫 적용의 dist-upgrade는 보안 패치이며 전체 OS/전이 apt 패키지 재현성이나
  이후 자동 보안 업데이트를 보장하지 않는다.
- OpenTofu `terraform_data`는 first-class WSL drift 탐지 provider가 아니다.
- 독립 정적 검토는 Windows 수명주기와 게스트 구성에서 차단 사항을 발견하지 않았다.
  실제 OS 검증은 코디네이터가 수행했으며 서로 다른 모델 계열의 교차 검토는 하지 않았다.
