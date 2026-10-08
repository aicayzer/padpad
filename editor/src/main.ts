import { InkKitEditor, type ClipboardOutput } from "@aicayzer/inkkit";
import "@aicayzer/inkkit/style.css";
import "./style.css";

function post(message: Record<string, unknown>): void {
  const host = (
    window as unknown as {
      webkit?: {
        messageHandlers?: { host?: { postMessage(message: unknown): void } };
      };
    }
  ).webkit?.messageHandlers?.host;
  if (host) host.postMessage(message);
}

const root = document.getElementById("editor");
if (!root) throw new Error("editor root missing");
let generation = 0;
function writeClipboard(output: ClipboardOutput): void {
  post({
    type: "writeClipboard",
    generation,
    text: output.text,
    html: output.html,
    images: [],
  });
}
const editor = await InkKitEditor.mount(
  root,
  {
    changed(markdown, generation) {
      post({ type: "changed", markdown, generation });
    },
    stateChanged(state) {
      post({ type: "state", ...state, generation });
    },
    openLink(href) {
      post({ type: "openLink", href });
    },
    copy(text) {
      post({ type: "copy", text });
    },
    error(error) {
      post({ type: "editorWarning", message: error.message });
    },
    clipboard: writeClipboard,
  },
  {},
);
const facade = {
  load(
    text: string,
    nextGeneration: number,
    documentId = String(nextGeneration),
  ) {
    generation = nextGeneration;
    editor.loadDocument({ text, generation, documentId, format: "md" });
  },
  reload(
    text: string,
    nextGeneration: number,
    documentId = String(nextGeneration),
  ) {
    generation = nextGeneration;
    editor.reloadDocument({ text, generation, documentId, format: "md" });
  },
  snapshot: (expectedGeneration: number) => editor.snapshot(expectedGeneration),
  clipboard: () => editor.clipboardSnapshot(true),
  format: editor.format.bind(editor),
  focus: editor.focus.bind(editor),
  find: editor.find.bind(editor),
  insertText: editor.insertText.bind(editor),
  keyDown: editor.keyDown.bind(editor),
  insertPaths: editor.insertPaths.bind(editor),
  pasteAsPlainText: editor.pasteAsPlainText.bind(editor),
  table: editor.table.bind(editor),
  setAccent: (color: string) =>
    document.documentElement.style.setProperty("--accent", color),
  setTextSize: (px: number) =>
    document.documentElement.style.setProperty("font-size", `${px}px`),
  setReadingWidth: (width: number | null) => {
    if (width !== null && Number.isFinite(width) && width > 0)
      document.documentElement.style.setProperty(
        "--reading-width",
        `${width}px`,
      );
    else document.documentElement.style.removeProperty("--reading-width");
  },
  setKeymap: editor.setKeymap.bind(editor),
};
Object.assign(window, { editor: facade });
for (const name of ["keydown", "keyup"] as const)
  window.addEventListener(name, (event) =>
    document.documentElement.classList.toggle("meta", event.metaKey),
  );
window.addEventListener("keydown", (event) => {
  if (
    event.metaKey &&
    !event.altKey &&
    !event.ctrlKey &&
    event.key.toLowerCase() === "k"
  ) {
    event.preventDefault();
    post({ type: "requestLink" });
  }
});
window.addEventListener("blur", () =>
  document.documentElement.classList.remove("meta"),
);
window.addEventListener("error", (event) =>
  post({ type: "error", message: event.message }),
);
window.addEventListener("unhandledrejection", (event) =>
  post({ type: "error", message: String(event.reason) }),
);
post({ type: "ready" });
