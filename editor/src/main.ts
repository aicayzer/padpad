import {
  InkKitEditor,
  InkKitError,
  type ClipboardOutput,
  type FormatCommand,
  type FormatOptions,
  type KeyInput,
  type TableCommand,
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
const clipboardReplies = new Map<
  string,
  { resolve(): void; reject(error: Error): void }
>();
function writeClipboard(output: ClipboardOutput): Promise<void> {
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
      documentId: output.documentId,
      generation: output.generation,
      text: output.text,
      html: output.html,
    });
  });
}
const editor = await InkKitEditor.mount(
  root,
  {
    changed(snapshot) {
      post({
        type: "changed",
        markdown: snapshot.text,
        generation: snapshot.generation,
      });
    },
    commandStateChanged(state) {
      post({ type: "commands", ...state });
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
    // Any other rejection leaves the editor usable and the person's text untouched.
    if (
      error instanceof InkKitError &&
      error.code !== "destroyed" &&
      error.code !== "internal"
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
    editor.loadDocument({
      text,
      generation: nextGeneration,
      documentId,
      format: "md",
    });
  },
  reload(
    text: string,
    nextGeneration: number,
    documentId = String(nextGeneration),
  ) {
    editor.reloadDocument({
      text,
      generation: nextGeneration,
      documentId,
      format: "md",
    });
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
  clipboard: (expected: number) =>
    editor.clipboardSnapshot("document", expected),
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
      const output = await editor.printableSnapshot(expectedGeneration);
      return {
        documentId: output.documentId,
        generation: output.generation,
        revision: output.revision,
        format: output.format,
        html: output.html,
        styles: output.styles,
        assetCount: output.assets.length,
        warnings: output.warnings,
      };
    } catch (error) {
      if (error instanceof InkKitError)
        return { snapshotError: error.code, message: error.message };
      throw error;
    }
  },
  format: (
    command: FormatCommand,
    options: FormatOptions | null,
    expected: number,
  ) =>
    guardedCommand(() =>
      editor.format(command, options ?? undefined, expected),
    ),
  focus: editor.focus.bind(editor),
  find: (search: string, expected: number) =>
    guardedCommand(() => editor.find(search, expected)),
  insertText: (text: string, expected: number) =>
    guardedCommand(() => editor.insertText(text, expected)),
  keyDown: (input: KeyInput, expected: number) =>
    guardedCommand(() => editor.keyDown(input, expected)),
  pasteAsPlainText: (text: string, expected: number) =>
    guardedCommand(() => editor.pasteAsPlainText(text, expected)),
  table: (command: TableCommand, expected: number) =>
    guardedCommand(() => editor.table(command, undefined, expected)),
  setAccent: (color: string) =>
    document.documentElement.style.setProperty("--inkkit-accent-color", color),
  setTextSize: (px: number) =>
    document.documentElement.style.setProperty("font-size", `${px}px`),
  setReadingWidth: (width: number | null) => {
    if (width !== null && Number.isFinite(width) && width > 0)
      document.documentElement.style.setProperty(
        "--inkkit-reading-width",
        `${width}px`,
      );
    else
      document.documentElement.style.removeProperty("--inkkit-reading-width");
  },
  setKeymap: editor.setKeymap.bind(editor),
};
Object.assign(window, { editor: facade });
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
window.addEventListener("error", (event) =>
  post({ type: "error", message: event.message }),
);
window.addEventListener("unhandledrejection", (event) =>
  post({ type: "error", message: String(event.reason) }),
);
post({ type: "ready" });
