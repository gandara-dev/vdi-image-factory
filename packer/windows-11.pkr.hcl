packer {
  required_version = ">= 1.16.1"

  required_plugins {
    vsphere = {
      source  = "github.com/vmware/vsphere"
      version = "= 2.5.0"
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

variable "vsphere_server" {
  type        = string
  description = "vCenter Server FQDN or IP address."
}

variable "vsphere_username" {
  type        = string
  description = "Least-privilege vCenter service account."
  sensitive   = true
}

variable "vsphere_password" {
  type        = string
  description = "Password for the vCenter service account."
  sensitive   = true
}

variable "vsphere_insecure_connection" {
  type        = bool
  default     = false
  description = "Disable vCenter TLS certificate verification. Use only for an explicitly trusted lab."
}

variable "vsphere_datacenter" {
  type = string
}

variable "vsphere_cluster" {
  type        = string
  default     = null
  description = "Optional cluster. Use with host when DRS cannot select one; omit for a standalone ESXi host."
}

variable "vsphere_host" {
  type        = string
  default     = null
  description = "Optional ESXi host. Set it when DRS cannot select a host."
}

variable "vsphere_datastore" {
  type = string
}

variable "vsphere_folder" {
  type = string
}

variable "vsphere_network" {
  type = string
}

variable "vsphere_disk_controller" {
  type        = string
  default     = "lsilogic-sas"
  description = "System disk controller. Windows Setup has in-box drivers for LSI Logic SAS and NVMe; PVSCSI needs a WinPE driver this template does not inject."

  validation {
    condition     = contains(["lsilogic-sas", "nvme"], var.vsphere_disk_controller)
    error_message = "Use lsilogic-sas or nvme. PVSCSI requires loading its driver in the windowsPE pass."
  }
}

variable "vmware_tools_iso_path" {
  type        = string
  default     = "[] /vmimages/tools-isoimages/windows.iso"
  description = "ESXi host path to the VMware Tools Windows ISO."
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

source "vsphere-iso" "windows_11" {
  vcenter_server      = var.vsphere_server
  username            = var.vsphere_username
  password            = var.vsphere_password
  insecure_connection = var.vsphere_insecure_connection

  datacenter = var.vsphere_datacenter
  cluster    = var.vsphere_cluster
  host       = var.vsphere_host
  datastore  = var.vsphere_datastore
  folder     = var.vsphere_folder

  vm_name             = var.image_name
  convert_to_template = false
  guest_os_type       = "windows11_64Guest"
  firmware            = "efi-secure"
  vTPM                = true
  CPUs                = var.cpus
  RAM                 = var.memory_mb

  disk_controller_type = [var.vsphere_disk_controller]
  storage {
    disk_size             = var.disk_size_mb
    disk_thin_provisioned = true
  }

  network_adapters {
    network      = var.vsphere_network
    network_card = "vmxnet3"
  }

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum
  iso_paths    = [var.vmware_tools_iso_path]
  remove_cdrom = true

  communicator     = "winrm"
  winrm_username   = "packer"
  winrm_password   = var.winrm_password
  winrm_timeout    = "4h"
  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer shutdown\""
  shutdown_timeout = "30m"
  boot_wait        = "5s"
  boot_command     = ["<spacebar>"]

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
  sources = ["source.vsphere-iso.windows_11"]

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
