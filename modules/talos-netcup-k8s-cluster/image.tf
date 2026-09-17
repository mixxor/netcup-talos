# Talos image, built by the Image Factory.
#
# The factory derives the schematic id from the content, so the same extensions
# always yield the same id - this POST is idempotent and safe to run on every
# plan.

data "http" "schematic" {
  url    = "https://factory.talos.dev/schematics"
  method = "POST"

  request_body = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = var.talos_extensions
      }
    }
  })

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 || self.status_code == 201
      error_message = "Image Factory returned HTTP ${self.status_code}"
    }
  }
}

locals {
  schematic_id = jsondecode(data.http.schematic.response_body).id
  image_url    = "https://factory.talos.dev/image/${local.schematic_id}/${var.talos_version}/metal-amd64.raw.zst"

  # The installer image must carry the same schematic, otherwise the next
  # "talosctl upgrade" silently drops the extensions.
  installer_image = "factory.talos.dev/metal-installer/${local.schematic_id}:${var.talos_version}"
}
