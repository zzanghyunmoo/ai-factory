---
title: Server-side dry-run과 실제 적용의 field manager 일치
date: 2026-09-27
category: integration-issues
module: Kubernetes application deployment
problem_type: integration_issue
component: tooling
symptoms:
  - "첫 배포는 성공하지만 ConfigMap 변경 후 DeployLocal의 server dry-run이 실패한다."
  - "conflict with ai-factory-apps on the Deployment configMap volume name"
root_cause: config_error
resolution_type: code_fix
severity: medium
tags: [kubernetes, kustomize, server-side-apply, dry-run, field-manager]
---

# Server-side dry-run field manager

## Problem

실제 적용은 `--field-manager=ai-factory-apps`를 지정했지만 server dry-run은 kubectl 기본 manager를 사용했다.
Kustomize의 ConfigMap hash가 바뀌면서 Deployment의 volume 참조가 변경되자 dry-run이 이를 다른 소유자의 필드 변경으로 판단했다.
첫 설치와 동일 값 재적용만으로는 드러나지 않는 실패다.

## Symptoms

`DeployLocal`의 ConfigMap 변경 검증에서 `.spec.template.spec.volumes[name="config"].configMap.name` 충돌이 발생했고 실제 업데이트에 도달하지 못했다.

## What Didn't Work

초기 배포 성공만 확인하는 검증으로는 기존 리소스의 변경 시나리오를 확인할 수 없었다.

## Solution

`scripts/windows/Apps.psm1`의 `DeployLocal`에서 dry-run과 실제 apply에 같은 field manager를 지정한다.

```powershell
Invoke-AppKubectl @('apply','--server-side','--field-manager=ai-factory-apps','--dry-run=server','-k',$path)
Invoke-AppKubectl @('apply','--server-side','--field-manager=ai-factory-apps','-k',$path)
```

수정 후 같은 ConfigMap 변경을 재적용해 dry-run, 실제 Deployment 업데이트와 readiness 성공을 확인했다.

## Why This Works

Server-side dry-run도 필드 소유권 충돌을 평가한다.
동일한 manager로 검증해야 실제 적용을 수행할 주체의 권한과 ownership으로 변경을 판단한다.
강제 충돌 덮어쓰기를 추가할 필요가 없었다.

## Prevention

최초 설치와 무변경 재적용 외에 ConfigMap 내용을 변경하는 실제 업데이트 시나리오를 검증한다.
검증 명령과 실제 명령의 context, namespace, field manager를 일치시킨다.

## Related Issues

- [앱 운영 안내](../../litellm.md)
- [실제 검증 기록](../../verification/argocd-litellm.md)
