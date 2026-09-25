# Windows 운영 및 구현 참고

처음 설치하고 실행하는 순서는 [README](../README.md)에 있다.
이 문서는 명령별 동작, 상태 관리와 내부 구현을 설명한다.
실제 실행 결과와 실패·복구 이력은 [검증 기록](verification/windows-local-kubernetes.md)에 있다.

## 명령별 동작

모든 명령은 저장소 루트에서 `infra.ps1`로 실행한다.

| 명령 | 동작 |
| --- | --- |
| `Bootstrap` | 공식 고정 버전과 SHA-256을 검증해 OpenTofu와 Ubuntu 이미지를 준비한다. WSL은 변경하지 않는다. |
| `Plan` | 인프라 변경 계획을 `.local/`에 저장한다. 삭제나 재생성이 필요하면 거부한다. |
| `Apply` | 삭제·재생성 여부를 검사하고 인프라 계획을 적용한 뒤 Ansible을 매번 실행한다. |
| `Doctor` | 소유권과 실행 상태를 확인한다. 중지된 배포판은 시작하지 않는다. |
| `Start` | 소유한 WSL 배포판과 유지용 클라이언트를 시작한다. 중지된 kind 컨테이너 복구에는 Apply가 필요하다. |
| `Stop` | 실행 중인 소유 배포판만 종료한다. 이미 중지된 경우 그대로 둔다. |
| `Smoke` | 게스트에 복사된 샘플 앱을 배포하고 응답을 검사한다. |
| `Destroy -ConfirmName infra` | 소유권을 확인한 뒤 해당 배포판을 삭제한다. 실제 삭제 검증은 하지 않았다. |

Plan/Apply는 상속된 destroy 확인 환경변수도 지운다. Destroy는 중지된 게스트라도
소유권 marker 확인을 위해 잠시 시작할 수 있다. Windows 로그인 자동 실행 서비스나
예약 작업은 설치하지 않는다.

### Doctor 상태

- `absent`: 소유권 기록과 배포판이 모두 없다.
- `stopped`: 소유한 배포판이 중지돼 있다. 게스트 marker와 readiness는 검사하지 않았다.
- `unconfigured`: 게스트 검사 스크립트나 필요한 구성이 없다.
- `unready`: 게스트 준비 검사를 통과하지 못했다.
- `ready`: 선언된 버전과 두 노드·API의 준비 상태를 확인했다.

게스트 `doctor.sh` 종료 코드는 0 ready, 3 unconfigured, 4 unready다.
Windows Doctor는 상태 문자열을 출력하며 게스트 종료 코드를 그대로 전달하지 않는다.

## 상태와 파일

프로젝트명은 `ai-factory`지만 기존 환경의 이름은 `infra`로 유지한다.
운영 명령의 대상 이름이나 아래 경로를 일괄 치환하지 않는다.

| 위치 | 내용 |
| --- | --- |
| `LOCALAPPDATA/infra/owner.json` | 호스트 소유권 기록 |
| `LOCALAPPDATA/infra/instance.lock` | 호스트 작업 잠금 |
| `LOCALAPPDATA/infra/wsl/` | WSL 설치 디렉터리와 VHD |
| `LOCALAPPDATA/infra/keeper.json` | WSL 유지용 클라이언트 식별 정보 |
| `.local/terraform.tfstate` | OpenTofu 상태 |
| `.local/kubeconfig` | Windows에서 사용할 클러스터 접속 정보 |
| `.local/downloads/` | `opentofu.zip`, `ubuntu-rootfs.tar.gz` |
| `.local/tools/opentofu-1.12.6/tofu.exe` | 프로젝트 전용 OpenTofu |
| `/opt/infra` | 게스트 소스와 구성 |
| `/etc/infra-owner.json` | 게스트 소유권 marker |
| `/opt/infra/.local/` | 게스트 상태, kubeconfig, 프로젝트 로그 |

OpenTofu ZIP뿐 아니라 ZIP 내부 exe와 설치 exe의 해시도 비교한다.
state, plan, 게스트 전달용 archive는 `.local/`에 둔다. Destroy 후에도 로컬 상태와
다운로드는 보존하며, VHD 설치 디렉터리는 비어 있을 때만 제거한다.
기본 kubeconfig/context는 변경하지 않는다.

### 오류 확인

실패하면 먼저 Doctor 결과와 다음 비공개 로그를 확인한다.

- 호스트: `.local/native-error.log`, `.local/native-bridge-error.log`
- 게스트: `/opt/infra/.local/apply.log`, `/opt/infra/.local/smoke.log`

로그에는 개인 경로나 인증정보가 들어갈 수 있으므로 그대로 공개하지 않는다.
타임아웃이나 import 중단은 안전한 롤백을 보장하지 않는다. 소유권 오류, 부분 생성,
불완전한 기록이 있으면 상태를 보존하고 원인을 조사한다. state나 stamp를 삭제해
재시도하거나 기존 배포판을 자동 채택하는 복구는 지원하지 않는다.

저장소 경로를 옮기면 OpenTofu backend와 state에 기록된 소스 경로의 재연결이 필요하다.
`.local/`을 버리고 새로 설치하지 않는다. 기존 이동 사례는 검증 기록에 있다.

## 소유권과 실행 보호

호스트 owner/state/kubeconfig에는 현재 사용자 전용 ACL을 적용한다.
**VHD 설치 디렉터리 `wsl/`에만** WSL 저장소 작업에 필요한 SYSTEM FullControl을 추가한다.
게스트 `.local`은 0700, kubeconfig와 프로젝트 로그는 0600이다.
OS 자체 apt/journal 로그의 권한과 보관은 별개다.

OpenTofu의 별도 `terraform_data.identity.id`가 안정적인 owner ID다.
배포판 이름뿐 아니라 HKCU Lxss GUID, 정규화한 BasePath, 이미지 해시와
`/etc/infra-owner.json`을 확인한다. import 전에 preparing을 기록하고 marker 작성·재검증
후 committed로 전환한다. 불완전 기록, 다른 소유자의 배포판, GUID/path 변경,
기록 없는 설치 디렉터리는 자동 채택·삭제·복구하지 않는다.

단일 호스트 파일 잠금이 OpenTofu와 게스트 적용 전체를 감싼다.
하위 provisioner는 잠긴 파일의 임의 lease를 확인해 잠금을 위임받는다.
독립 실행 시에는 직접 잠근다. 이는 같은 사용자 권한의 악성 행위에 대한 보안 경계가 아니다.

WSL은 systemd 서비스만으로 계속 실행되지 않으므로 Apply/Start가 전용 `infra`에
`sleep infinity` 클라이언트를 유지한다. 사용자 전용 keeper 기록의 owner/GUID/PID/시작
시각으로 재사용을 확인한다. Stop/Destroy로 `infra`를 종료하면 keeper도 종료된다.
다른 Windows PID를 직접 종료하지 않는다.

OpenTofu `terraform_data`는 실제 WSL drift를 관찰하지 않는다. wrapper/Doctor 검사를
우회하는 raw tofu 실행은 지원 운영 경로가 아니다. raw destroy는
`INFRA_DESTROY_CONFIRM=infra` 없이는 unregister 전에 실패하지만,
tainted resource나 configuration 제거는 destroy provisioner를 생략해 자원을 남길 수 있다.
자동 replacement나 삭제를 통한 복구는 지원하지 않는다.

## 게스트 구성 인터페이스

Apply는 `ansible/`, `config/`, `versions.json`, `scripts/guest/` 및 존재하는
`examples/smoke/`를 tar로 묶어 Linux 파일시스템 `/opt/infra`에 복사한다.
게스트 root로 아래 고정 인터페이스를 실행하며, 동적 값은 shell 문자열이 아닌 argv로 전달한다.

```text
/bin/bash /opt/infra/scripts/guest/apply.sh --root /opt/infra --owner-id <stable-owner-id>
/bin/bash /opt/infra/scripts/guest/smoke.sh --root /opt/infra --owner-id <stable-owner-id>
/bin/bash /opt/infra/scripts/guest/doctor.sh --root /opt/infra --owner-id <stable-owner-id>
```

- apply/smoke 성공 코드는 0이다. apply는 매번 Ansible을 실행하고 게스트 kubeconfig를 생성한다.
- 게스트 스크립트는 `/run/infra-guest.lock`의 flock으로 중복 실행을 막고 기존 상태를 보존한다.
- apply/smoke는 guest timeout 2100초 + kill-after 30초, host timeout 2200초다.
- doctor는 guest timeout 240초 + kill-after 10초이며 host timeout은 300초다.
- Smoke는 이미 복사된 게스트 스크립트를 실행한다. 변경한 코드는 Apply로 먼저 반영한다.
- 버전 JSON 키는 ubuntu/opentofu/kind/kubectl/ansible/docker/smoke다.

### 플랫폼과 패키지 설치

Apply는 marker를 확인한 뒤 Ubuntu 24.04 amd64, systemd PID 1, cgroup v2를 검사한다.
systemd 시작은 최대 60초 기다린다. 부팅 구성이 맞지 않으면 원인을 출력하고 중단하며,
전역 WSL 재시작이나 설정 변경은 하지 않는다. rootfs의 기존 `python3`로 설치 전에
소유권을 확인한다. python3가 없으면 설치로 우회하지 않고 중단한다.

최소 `python3-venv`/CA 부트스트랩 후 `/opt/infra/.venv`에 해시 잠금된 Ansible과 전이
의존성을 설치한다. 매 Apply에서 syntax-check와 `ansible/site.yaml`을 실행한다.
오래된 rootfs는 첫 적용에서 dist-upgrade하고 성공 후 `.local/baseline-20240423.patched`를
남긴다. 이후 Apply는 전체 업그레이드를 반복하지 않는다. 이 stamp는 당시 업데이트 성공
기록이며, 보안 업데이트 자동화나 OS·전이 apt 패키지 재현성을 보장하지 않는다.

Docker Engine은 공식 서명 키의 SHA-256을 확인한 noble 저장소와 정확한 top-level
패키지 버전을 사용한다. Docker Desktop/socket 공유나 docker 그룹 권한은 사용하지 않는다.
kind/kubectl도 고정 URL·SHA-256으로 설치한다.

### 클러스터 보호와 준비 검사

클러스터는 `infra`, control-plane 1개와 worker 1개다.
API는 `127.0.0.1:16443`, 예제 HTTP는 `127.0.0.1:18080`에만 바인딩한다.
두 노드 Ready와 API readiness를 확인한 뒤에만 `.local/cluster.json`에
owner/config+image fingerprint/container ID를 기록한다.

기존 컨테이너의 실제 이름·이미지·역할·포트·ID도 검사한다. 기록 없는 기존 클러스터,
부분 생성, 설정 변경, 컨테이너 교체는 자동 채택·삭제·재생성하지 않는다.
kind 생성 실패도 `--retain`으로 부분 컨테이너를 남긴다. 기록된 컨테이너가 중지된 경우에는
같은 owner/config/image/정확한 ID를 확인한 뒤 기존 컨테이너만 다시 시작한다.

Apply는 앱을 배포하지 않는다. Smoke에서만 `examples/smoke/app.yaml`을 적용해 고정
이미지 digest의 nginx와 ConfigMap의 `infra-ready` 응답을 확인한다. 반복 Smoke는 안전하다.
호스트 HTTP 접근은 Windows에서 별도로 확인해야 한다.

## 개발 검증

Windows PowerShell에서 파싱·오프라인 테스트와 OpenTofu 정적 검증을 실행한다.
OpenTofu 검증에는 Bootstrap으로 준비한 프로젝트 전용 실행 파일을 사용한다.

```powershell
powershell.exe -NoProfile -File tests/windows/Run-Tests.ps1
$tofu = '.\.local\tools\opentofu-1.12.6\tofu.exe'
& $tofu fmt -check -recursive
& $tofu -chdir=environments/windows init -backend=false -input=false
& $tofu -chdir=environments/windows validate
```

Python 테스트에는 Python 3, shell 문법 검사에는 Bash가 별도로 필요하다.
Bash에서 저장소 루트를 기준으로 실행한다.

```bash
python -m unittest discover -s tests/guest -v
for script in scripts/guest/*.sh; do bash -n "$script" || exit; done
```

오프라인 테스트는 fake WSL/registry와 임시 파일을 사용하며 실제 WSL을 조작하지 않는다.
이 검사는 실제 apt/systemd/WSL 동작을 입증하지 않는다. Ansible syntax-check,
최초·반복 Apply, Windows API/HTTP 접근, Stop/Start 복구는 실제 게스트 검증과 구분한다.
실제 unregister/Destroy, macOS와 Windows 전체 재부팅 후 복구는 미검증이다.
