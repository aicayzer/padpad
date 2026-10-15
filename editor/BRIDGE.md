# Offline editor bridge

The app bootstrap consumes `@aicayzer/inkkit` and bundles its JavaScript and CSS into one offline HTML file. The native app owns document identity, generation, storage, appearance, and keyboard bindings. InkKit owns editing, preservation, tables, and clipboard conversion.

## Documents and snapshots

`load(text, generation, documentId)` and `reload(text, generation, documentId)` pass Markdown documents to InkKit. `snapshot(expectedGeneration)` returns complete current source with `documentId`, `generation`, `revision`, `format`, and `dirty`. Unchanged text is a successful snapshot. InkKit rejections return `{snapshotError, message}` instead of escaping the native JavaScript evaluation and triggering a fatal browser error. Native readiness, composition, pending operations, stale generations, and preservation rejections stop the current operation while leaving later snapshots available. Genuine script failures disable the bridge. Native save, export, close, switching, and termination must stop when retrieval fails.

`changed` carries the new Markdown and its generation. Discard reports belonging to previous documents. Appearance and formatting changes do not reload source.

## Clipboard and images

Ordinary copy exports readable text and semantic HTML. `clipboard(generation)` asynchronously captures all content; await it before replacing the pasteboard. Copy as Markdown uses a fresh snapshot. `pasteAsPlainText(text)` inserts literal text.

PadPad mounts InkKit without an image adapter and preserves image syntax literally. It does not import, store, resolve, or export managed image bytes. `writeClipboard` receives readable text and semantic HTML only; the native `PadClipboardContents` writer supplies those representations. Scoped requests receive `clipboardResponse` acknowledgments after a successful native write; stale requests and write failures reject the operation. TXT editing remains in the native text editor.

## Verification

Install the locked registry dependency with `pnpm install --frozen-lockfile`, then run editor type checking, consumer tests, and the offline build. Engine regression suites belong in InkKit. Native tests additionally exercise snapshot failure and clipboard interoperability. The app bundles the published package offline; it does not require a network connection at runtime.

## Modes, commands, search, and printing

Markdown Source switches InkKit's editing mode in the existing document; it does not reload source or discard history. Scoped command state controls Undo, Redo, formatting, tables, and replacement availability. The `commands` message is InkKit's `CommandState`: its `commands` hold availability (each heading level is its own format command, `heading1` to `heading6`) and its `caret` holds the active marks, block, and quote the toolbar shows. A format, table, paste, text insertion, key, replace, undo, or redo call that InkKit refuses, for any reason except `destroyed` and `internal`, returns `{commandError, message}` and the native side reports it to the person without disabling the bridge or the rest of the queued input. Edits the person makes in the page itself (typing, shortcuts, paste, drop) are reported through `editorWarning`. Native key input reaches InkKit as `keyDown({key, metaKey, ctrlKey, altKey, shiftKey}, generation)`. Find and Replace searches the current editing mode: literal Markdown in source mode and readable content in formatted mode. TXT continues to use the native text editor and find bar.

Print first captures current source, then awaits the scoped `printableSnapshot`. Its complete HTML includes print CSS and frozen inline image assets. A separate WebKit view waits for fonts and image decoding before presenting the native print panel, including macOS PDF options. Safe fallback warnings appear in the printable content. Snapshot, asset, rendering, and stale document failures stop printing and retain writing.
