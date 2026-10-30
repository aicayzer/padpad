/** PadPad has no image storage. Refuse before the editor inserts an unavailable-image placeholder. */
export function declineImageInput(root: HTMLElement, report: () => void): void {
  function containsImage(data: DataTransfer | null): boolean {
    if (!data) return false;
    if (
      Array.from(data.files).some(
        (file) =>
          file.type.startsWith("image/") ||
          /\.(png|jpe?g|gif|webp|tiff?|heic|heif|avif|svg|bmp|ico)$/i.test(
            file.name,
          ),
      )
    )
      return true;
    if (
      Array.from(data.items).some(
        (item) => item.kind === "file" && item.type.startsWith("image/"),
      )
    )
      return true;
    const html = data.getData("text/html");
    if (!html) return false;
    const template = document.createElement("template");
    template.innerHTML = html;
    return template.content.querySelector("img, picture, svg") !== null;
  }

  root.addEventListener(
    "paste",
    (event) => {
      if (!containsImage(event.clipboardData)) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      report();
    },
    true,
  );
  root.addEventListener(
    "drop",
    (event) => {
      if (!containsImage(event.dataTransfer)) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      report();
    },
    true,
  );
}
