packer {
  required_version = ">= 1.16.1"

  required_plugins {
    hyperv = {
      source  = "github.com/hashicorp/hyperv"
      version = "= 1.1.5"
    }
  }
}

variable "iso_url" {
  type        = string
  description = "Path or URL of a licensed Windows 11 ISO."
}

variable "iso_checksum" {
  type        = string
  description = "ISO checksum, for example sha256:0123..."
}

variable "winrm_password" {
  type        = string
  description = "Temporary password for the local Packer account."
  sensitive   = true

  validation {
    condition = (
      length(var.winrm_password) >= 16 &&
      can(regex("[A-Z]", var.winrm_password)) &&
      can(regex("[a-z]", var.winrm_password)) &&
      can(regex("[0-9]", var.winrm_password)) &&
      can(regex("^[A-Za-z0-9!@#%_+=.-]+$", var.winrm_password))
    )
    error_message = "The WinRM password must be at least 16 XML-safe characters and contain upper, lower, and numeric characters."
  }
}

variable "windows_image_index" {
  type        = number
  default     = 6
  description = "Windows edition index in install.wim; confirm it with DISM before building."
}

variable "image_name" {
  type    = string
  default = "vdi-windows-11"
}

variable "image_version" {
  type    = string
  default = "dev"
}

variable "ui_language" {
  type        = string
  default     = "en-US"
  description = "Windows display language; it must exist in the installation media."

  validation {
    condition     = can(regex("^[a-z]{2,3}-[A-Z]{2}$", var.ui_language))
    error_message = "Use a language tag such as en-US or pt-BR."
  }
}

variable "locale" {
  type        = string
  default     = "en-US"
  description = "Input, system, and user locale applied during unattended setup."

  validation {
    condition     = can(regex("^[a-z]{2,3}-[A-Z]{2}$", var.locale))
    error_message = "Use a locale tag such as en-US or pt-BR."
  }
}

variable "time_zone" {
  type        = string
  default     = "UTC"
  description = "Windows time zone ID, for example E. South America Standard Time."

  validation {
    condition     = can(regex("^[A-Za-z0-9 .()+-]+$", var.time_zone))
    error_message = "Use a Windows time zone ID such as UTC or Pacific Standard Time."
  }
}

variable "application_profiles" {
  type        = list(string)
  default     = ["standard"]
  description = "Application profiles to combine from the catalog."
}

variable "include_applications" {
  type        = list(string)
  default     = []
  description = "Additional exact WinGet IDs from the catalog, or an asterisk for all."
}

variable "exclude_applications" {
  type        = list(string)
  default     = []
  description = "Exact WinGet IDs to remove after profile resolution."
}

variable "switch_name" {
  type    = string
  default = "Default Switch"
}

variable "cpus" {
  type    = number
  default = 4
}

variable "memory_mb" {
  type    = number
  default = 8192
}

variable "disk_size_mb" {
  type    = number
  default = 81920
}

variable "run_optimizer" {
  type        = bool
  default     = false
  description = "Run Citrix Optimizer when it has been staged in the guest."
}

variable "optimizer_engine_path" {
  type    = string
  default = "C:\\CitrixOptimizer\\CtxOptimizerEngine.ps1"
}

variable "optimizer_template" {
  type    = string
  default = "AutoSelect"
}

source "hyperv-iso" "windows_11" {
  vm_name              = var.image_name
  output_directory     = "output-${var.image_name}"
  iso_url              = var.iso_url
  iso_checksum         = var.iso_checksum
  generation           = 2
  enable_secure_boot   = true
  secure_boot_template = "MicrosoftWindows"
  switch_name          = var.switch_name
  cpus                 = var.cpus
  memory               = var.memory_mb
  disk_size            = var.disk_size_mb
  headless             = true
  communicator         = "winrm"
  winrm_username       = "packer"
  winrm_password       = var.winrm_password
  winrm_timeout        = "4h"
  shutdown_command     = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer shutdown\""
  shutdown_timeout     = "30m"
  skip_compaction      = false
  boot_wait            = "5s"
  boot_command         = ["<spacebar>"]

  cd_content = {
    "Autounattend.xml" = templatefile(
      abspath("${path.root}/answer_files/Autounattend.xml.pkrtpl.hcl"),
      {
        winrm_password      = var.winrm_password
        windows_image_index = var.windows_image_index
        ui_language         = var.ui_language
        locale              = var.locale
        time_zone           = var.time_zone
      }
    )
  }
}

build {
  name    = "vdi-image"
  sources = ["source.hyperv-iso.windows_11"]

  provisioner "file" {
    source      = abspath("${path.root}/../src/VdiImageFactory")
    destination = "C:\\Windows\\Temp\\VdiImageFactory"
  }

  provisioner "file" {
    source      = abspath("${path.root}/../config/application-catalog.json")
    destination = "C:\\Windows\\Temp\\application-catalog.json"
  }

  provisioner "powershell" {
    environment_vars = [
      "VIF_APP_CATALOG=C:\\Windows\\Temp\\application-catalog.json",
      "VIF_APP_PROFILES=${join(",", var.application_profiles)}",
      "VIF_APP_INCLUDE=${join(",", var.include_applications)}",
      "VIF_APP_EXCLUDE=${join(",", var.exclude_applications)}",
      "VIF_IMAGE_VERSION=${var.image_version}",
      "VIF_RUN_OPTIMIZER=${var.run_optimizer}",
      "VIF_OPTIMIZER_ENGINE=${var.optimizer_engine_path}",
      "VIF_OPTIMIZER_TEMPLATE=${var.optimizer_template}"
    ]
    scripts = [abspath("${path.root}/scripts/Customize-Image.ps1")]
  }
}
