import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "cameraInput",
    "libraryInput",
    "submitButton",
    "fileName",
    "emptyState",
    "previewWrapper",
    "preview"
  ]

  connect() {
    this.selectedObjectUrl = null
  }

  disconnect() {
    this.revokePreviewUrl()
  }

  openCamera() {
    this.libraryInputTarget.value = ""
    this.cameraInputTarget.click()
  }

  openLibrary() {
    this.cameraInputTarget.value = ""
    this.libraryInputTarget.click()
  }

  previewCamera() {
    this.updatePreview(this.cameraInputTarget)
  }

  previewLibrary() {
    this.updatePreview(this.libraryInputTarget)
  }

  disableSubmit() {
    this.submitButtonTarget.disabled = true
  }

  updatePreview(input) {
    const file = input.files && input.files[0]
    this.submitButtonTarget.disabled = !file

    if (!file) {
      this.clearPreview()
      return
    }

    this.revokePreviewUrl()
    this.selectedObjectUrl = URL.createObjectURL(file)
    this.previewTarget.src = this.selectedObjectUrl
    this.previewWrapperTarget.classList.remove("hidden")
    this.emptyStateTarget.classList.add("hidden")
    this.fileNameTarget.textContent = file.name
  }

  clearPreview() {
    this.revokePreviewUrl()
    this.previewTarget.src = ""
    this.previewWrapperTarget.classList.add("hidden")
    this.emptyStateTarget.classList.remove("hidden")
    this.fileNameTarget.textContent = "画像はまだ選択されていません"
  }

  revokePreviewUrl() {
    if (!this.selectedObjectUrl) return

    URL.revokeObjectURL(this.selectedObjectUrl)
    this.selectedObjectUrl = null
  }
}
