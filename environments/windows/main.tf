terraform {
  required_version = "= 1.12.6"
  backend "local" {
    path = "../../.local/terraform.tfstate"
  }
}

locals {
  root     = abspath("${path.module}/../..")
  versions = jsondecode(file("${local.root}/versions.json"))
}

# Keep the owner stable if the WSL resource's create provisioner fails/taints.
resource "terraform_data" "identity" {}

resource "terraform_data" "wsl" {
  input = {
    owner      = terraform_data.identity.id
    root       = local.root
    bridge     = "${local.root}/scripts/windows/Bridge.ps1"
    image_hash = local.versions.ubuntu.sha256
  }
  triggers_replace = [local.versions.ubuntu.sha256]

  provisioner "local-exec" {
    interpreter = ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = "& $env:INFRA_BRIDGE -Action Create; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }"
    environment = {
      INFRA_ROOT       = self.input.root
      INFRA_BRIDGE     = self.input.bridge
      INFRA_OWNER      = self.input.owner
      INFRA_IMAGE_HASH = self.input.image_hash
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = "& $env:INFRA_BRIDGE -Action Destroy; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }"
    environment = {
      INFRA_ROOT       = self.input.root
      INFRA_BRIDGE     = self.input.bridge
      INFRA_OWNER      = self.input.owner
      INFRA_IMAGE_HASH = self.input.image_hash
    }
  }
}

output "owner_id" {
  value = terraform_data.identity.id
}
