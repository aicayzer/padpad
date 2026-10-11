import {
  InkKitEditor,
  InkKitError,
  type ClipboardOutput,
} from "@aicayzer/inkkit";
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
const clipboardReplies = new Map<
  string,
  { resolve(): void; reject(error: Error): void }
>();
function writeClipboard(output: ClipboardOutput): Promise<void> {
  const scope = editor.snapshot();
  const requestId = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      clipboardReplies.delete(requestId);
      reject(new Error("Clipboard write timed out"));
    }, 15000);
    clipboardReplies.set(requestId, {
      resolve() {
        clearTimeout(timeout);
        resolve();
      },
      reject(error) {
        clearTimeout(timeout);
        reject(error);
      },
    });
    post({
      type: "writeClipboard",
      requestId,
      documentId: scope.documentId,
      generation: scope.generation,
      text: output.text,
      html: output.html,
    });
  });
}
const editor = await InkKitEditor.mount(
  root,
  {
    changed(markdown, generation) {
      post({ type: "changed", markdown, generation });
    },
    commandStateChanged(state) {
      post({ type: "commands", ...state });
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
function guardedCommand<T>(
  action: () => T,
): T | { commandError: string; message: string } {
  try {
    return action();
  } catch (error) {
    if (
      error instanceof InkKitError &&
      [
        "not-ready",
        "stale-document",
        "composition",
        "operation-pending",
        "preservation",
        "image-unavailable",
        "diagram-unavailable",
      ].includes(error.code)
    )
      return { commandError: error.code, message: error.message };
    throw error;
  }
}

const facade = {
  clipboardResponse(requestId: string, response: { error?: string }) {
    const reply = clipboardReplies.get(requestId);
    clipboardReplies.delete(requestId);
    if (response.error) reply?.reject(new Error(response.error));
    else reply?.resolve();
  },
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
  snapshot(expectedGeneration: number) {
    try {
      return editor.snapshot(expectedGeneration);
    } catch (error) {
      if (error instanceof InkKitError)
        return { snapshotError: error.code, message: error.message };
      throw error;
    }
  },
  clipboard: () => editor.clipboardSnapshot(true),
  setEditingMode: (mode: "source" | "formatted", expected: number) =>
    guardedCommand(() => editor.setEditingMode(mode, expected)),
  undo: (expected: number) => guardedCommand(() => editor.undo(expected)),
  redo: (expected: number) => guardedCommand(() => editor.redo(expected)),
  replace: (search: string, replacement: string, expected: number) =>
    guardedCommand(() => editor.replace(search, replacement, expected)),
  replaceAll: (search: string, replacement: string, expected: number) =>
    guardedCommand(() => editor.replaceAll(search, replacement, expected)),
  async printable(expectedGeneration: number) {
    try {
      return await editor.printableSnapshot(expectedGeneration);
    } catch (error) {
      if (error instanceof InkKitError)
        return { snapshotError: error.code, message: error.message };
      throw error;
    }
  },
  format: editor.format.bind(editor),
  focus: editor.focus.bind(editor),
  find: (search: string, expected: number) =>
    guardedCommand(() => editor.find(search, expected)),
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
    event.key.toLowerCase() === "k" &&
    editor.commandState().commands.format.link
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
