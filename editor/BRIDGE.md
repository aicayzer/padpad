# Offline editor bridge

The app bootstrap consumes `@aicayzer/inkkit` and bundles its JavaScript and CSS into one offline HTML file. The native app owns document identity, generation, storage, appearance, and keyboard bindings. InkKit owns editing, preservation, tables, and clipboard conversion.

## Documents and snapshots

`load(text, generation, documentId)` and `reload(text, generation, documentId)` pass Markdown documents to InkKit. `snapshot(expectedGeneration)` returns complete current source with `documentId`, `generation`, `revision`, `format`, and `dirty`. Unchanged text is a successful snapshot. Known InkKit rejections return `{snapshotError, message}` instead of escaping the native JavaScript evaluation and triggering a fatal browser error. Native readiness, composition, pending operations, stale generations, and preservation rejections stop the current operation while leaving later snapshots available. Destroyed editors, unknown rejection codes, and genuine script failures disable the bridge. Native save, export, close, switching, and termination must stop when retrieval fails.

`changed` carries Markdown and generation. Discard reports belonging to previous documents. Appearance and formatting changes do not reload source.

## Clipboard and images

Ordinary copy exports readable text and semantic HTML. `clipboard()` asynchronously captures all content; await it before replacing the pasteboard. Copy as Markdown uses a fresh snapshot. `pasteAsPlainText(text)` inserts literal text.

PadPad mounts InkKit without an image adapter and preserves image syntax literally. It does not import, store, resolve, or export managed image bytes. `writeClipboard` receives readable text and semantic HTML only; the native `PadClipboardContents` writer supplies those representations. Scoped requests receive `clipboardResponse` acknowledgments after a successful native write; stale requests and write failures reject the operation. TXT editing remains in the native text editor.

## Verification

Install the locked registry dependency with `pnpm install --frozen-lockfile`, then run editor type checking, consumer tests, and the offline build. Engine regression suites belong in InkKit. Native tests additionally exercise snapshot failure and clipboard interoperability. The app bundles the published package offline; it does not require a network connection at runtime.
