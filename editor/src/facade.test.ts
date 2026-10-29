import { beforeAll, describe, expect, it } from "vitest";

type Message = Record<string, any>;
type Facade = Record<string, any>;

const posted: Message[] = [];
let facade: Facade;

function latest(type: string): Message {
  const message = posted.filter((entry) => entry.type === type).at(-1);
  if (!message) throw new Error(`no ${type} message`);
  return message;
}

describe("native bridge facade", () => {
  beforeAll(async () => {
    document.body.innerHTML = '<div id="editor"></div>';
    Object.assign(window, {
      webkit: {
        messageHandlers: {
          host: { postMessage: (message: Message) => posted.push(message) },
        },
      },
    });
    await import("./main");
    facade = (window as unknown as { editor: Facade }).editor;
    facade.load("Selected words\r\n", 1, "doc");
  });

  it("reports the document with its generation when it changes", () => {
    expect(posted.some((entry) => entry.type === "ready")).toBe(true);
    expect(facade.insertText("!", 1)).toBe(true);
    expect(latest("changed")).toMatchObject({
      generation: 1,
      documentId: "doc",
      format: "md",
      text: expect.stringContaining("!"),
    });
    expect(latest("changed").document).toBeUndefined();
    expect(latest("changed").text).toBe(facade.snapshot(1).text);
    expect(latest("changed").text.endsWith("\r\n")).toBe(true);
  });

  it("offers every heading level and names the caret in the commands message", () => {
    facade.load("Plain\n", 2, "next");
    const { commands, caret, generation, documentId } = latest("commands");
    expect({ generation, documentId }).toEqual({
      generation: 2,
      documentId: "next",
    });
    for (const level of [1, 2, 3, 4, 5, 6])
      expect(commands.format[`heading${level}`]).toBe(true);
    expect(commands.format.heading).toBeUndefined();
    expect(caret).toEqual({
      marks: [],
      block: { type: "paragraph" },
      quoted: false,
    });
    expect(facade.format("heading2", null, 2)).toBe(true);
    expect(latest("commands").caret.block).toEqual({
      type: "heading",
      level: 2,
    });
    expect(facade.snapshot(2).text).toBe("## Plain\n");
  });

  it("changes and removes a link through the destination option", () => {
    facade.load("[Link](https://old.example)\n", 3, "link");
    expect(
      facade.format("link", { destination: "https://example.com" }, 3),
    ).toBe(true);
    expect(facade.snapshot(3).text).toBe("[Link](https://example.com)\n");
    expect(facade.format("link", null, 3)).toBe(true);
    expect(facade.snapshot(3).text).toBe("Link\n");
  });

  it("hands a refused edit back as a command error instead of throwing", () => {
    facade.load("Keep this\n", 4, "refused");
    const before = facade.snapshot(4).text;
    expect(facade.format("bold", null, 3)).toMatchObject({
      commandError: "stale-document",
    });
    expect(facade.format("heading", null, 4)).toMatchObject({
      commandError: "invalid-argument",
    });
    expect(facade.table("nonsense", 4)).toMatchObject({
      commandError: "invalid-argument",
    });
    expect(facade.pasteAsPlainText("x", 3)).toMatchObject({
      commandError: "stale-document",
    });
    expect(facade.snapshot(4).text).toBe(before);
  });

  it("accepts a key as an object and leaves the code out", () => {
    facade.setKeymap({ bold: ["Mod-b"] });
    facade.load("", 5, "keys");
    expect(
      facade.keyDown(
        { key: "b", metaKey: true, ctrlKey: false, altKey: false },
        5,
      ),
    ).toBe(true);
    expect(latest("commands").caret.marks).toEqual(["bold"]);
  });

  it("copies the document without taking a second snapshot", async () => {
    facade.load("Some **bold** text\n", 6, "copy");
    const output = await facade.clipboard(6);
    expect(output.text).toBe("Some bold text");
    expect(output.html).toContain("<strong>bold</strong>");
    await expect((async () => facade.clipboard(5))()).rejects.toThrow();
  });

  it("sets the reading width and accent on InkKit's own tokens", () => {
    const style = document.documentElement.style;
    facade.setReadingWidth(600);
    expect(style.getPropertyValue("--inkkit-reading-width")).toBe("600px");
    facade.setReadingWidth(null);
    expect(style.getPropertyValue("--inkkit-reading-width")).toBe("");
    facade.setAccent("#336699");
    expect(style.getPropertyValue("--inkkit-accent-color")).toBe("#336699");
  });

  it("reports a preservation refusal to the app and not as a warning", () => {
    facade.load("A <!--note--> B\n", 7, "preserved-comment");
    const before = facade.snapshot(7).text;
    const warnings = posted.filter((entry) => entry.type === "editorWarning");
    // A code block cannot retain the hidden comment. Table multiline input is
    // supported by InkKit 0.1.2 and is no longer a refusal fixture.
    const refusal = facade.format("codeBlock", null, 7);
    expect(refusal).toMatchObject({
      commandError: "preservation",
      message: expect.stringMatching(/\S/),
    });
    expect(facade.snapshot(7).text).toBe(before);
    expect(posted.filter((entry) => entry.type === "editorWarning")).toEqual(
      warnings,
    );
    expect(facade.insertText("x", 6)).toMatchObject({
      commandError: "stale-document",
    });
    expect(facade.keyDown({ key: "Enter", metaKey: false }, 6)).toMatchObject({
      commandError: "stale-document",
    });
  });

  it("scopes page editing errors with a code and the current document", () => {
    facade.load("A <!--note--> B\n", 8, "page-event");
    facade.setKeymap({ codeBlock: ["Mod-Alt-c"] });
    const press = new KeyboardEvent("keydown", {
      key: "c",
      metaKey: true,
      altKey: true,
      bubbles: true,
      cancelable: true,
    });
    document.querySelector(".ProseMirror")!.dispatchEvent(press);
    expect(press.defaultPrevented).toBe(true);
    expect(latest("editorWarning")).toMatchObject({
      code: "preservation",
      source: "edit",
      generation: 8,
      documentId: "page-event",
    });
    expect(facade.snapshot(8).text).toBe("A <!--note--> B\n");
  });

  it("warns when a diagram cannot be exported to the clipboard", async () => {
    facade.load("```mermaid\ngraph TD\n  A --> B\n```\n", 9, "diagram");
    const warnings = () =>
      posted.filter(
        (entry) =>
          entry.type === "editorWarning" &&
          entry.code === "diagram-unavailable" &&
          entry.source === "clipboard",
      );
    const before = warnings().length;
    const output = await facade.clipboard(9);
    expect(output.diagrams.some((diagram: any) => diagram.error)).toBe(true);
    expect(output.text).toContain("A --> B");
    expect(warnings()).toHaveLength(before + 1);
    expect(warnings().at(-1)).toMatchObject({
      source: "clipboard",
      code: "diagram-unavailable",
      generation: 9,
      documentId: "diagram",
    });
  });
  it("keeps delayed clipboard failures attached to their original document", async () => {
    facade.load("```mermaid\ngraph TD\n  A --> B\n```\n", 10, "old-copy");
    facade.setEditingMode("source", 10);
    const surface = document.querySelector("textarea")!;
    surface.setSelectionRange(0, surface.value.length);
    surface.dispatchEvent(
      new Event("copy", { bubbles: true, cancelable: true }),
    );
    await expect
      .poll(
        () => posted.filter((entry) => entry.type === "writeClipboard").length,
      )
      .toBeGreaterThan(0);
    const request = latest("writeClipboard");
    expect(request.documentId).toBe("old-copy");
    facade.load("New document\n", 11, "new-copy");
    facade.clipboardResponse(request.requestId, {
      error: "Fixture clipboard failure",
    });
    await expect
      .poll(
        () =>
          posted.filter(
            (entry) =>
              entry.type === "editorWarning" &&
              entry.code === "clipboard-unavailable",
          ).length,
      )
      .toBeGreaterThan(0);
    expect(latest("editorWarning")).toMatchObject({
      code: "clipboard-unavailable",
      source: "clipboard",
      generation: 10,
      documentId: "old-copy",
    });
  });
  it("loads, edits and snapshots an RTF document as JSON text", () => {
    const loaded = {
      version: 1,
      blocks: [
        {
          type: "paragraph",
          align: "center",
          content: [{ type: "text", text: "Rich", marks: [{ type: "bold" }] }],
        },
      ],
    };
    facade.load(JSON.stringify(loaded), 20, "rich", "rtf");
    const clean = facade.snapshot(20);
    expect(clean).toMatchObject({ format: "rtf", dirty: false });
    expect(clean.text).toBeUndefined();
    expect(JSON.parse(clean.document)).toEqual(loaded);
    const state = latest("commands");
    expect(state.format).toBe("rtf");
    expect(state.commands.format.heading1).toBe(false);
    expect(state.commands.format.quote).toBe(false);
    expect(state.commands.format.codeBlock).toBe(false);
    expect(state.commands.format.alignRight).toBe(true);
    expect(state.commands.format.underline).toBe(true);
    expect(facade.setEditingMode("source", 20)).toBe(false);
    expect(facade.insertText("!", 20)).toBe(true);
    const changed = latest("changed");
    expect(changed).toMatchObject({ format: "rtf", generation: 20 });
    expect(changed.text).toBeUndefined();
    expect(JSON.parse(changed.document).blocks[0].content.at(-1).text).toContain(
      "!",
    );
    expect(facade.snapshot(20)).toMatchObject({ dirty: true });
  });

  it("underlines with the host keymap in Markdown and RTF", () => {
    facade.setKeymap({ underline: ["Mod-u"] });
    facade.load("", 21, "underline-md");
    expect(facade.keyDown({ key: "u", metaKey: true }, 21)).toBe(true);
    facade.insertText("under", 21);
    expect(facade.snapshot(21).text).toBe("<u>under</u>\n");
    facade.load('{"version":1,"blocks":[]}', 22, "underline-rtf", "rtf");
    expect(facade.keyDown({ key: "u", metaKey: true }, 22)).toBe(true);
    facade.insertText("under", 22);
    expect(JSON.parse(facade.snapshot(22).document)).toEqual({
      version: 1,
      blocks: [
        {
          type: "paragraph",
          content: [
            { type: "text", text: "under", marks: [{ type: "underline" }] },
          ],
        },
      ],
    });
  });

  it("converts between Markdown and RTF and names what is lost", () => {
    facade.load("# Title\n\nBody\n", 23, "convert");
    const rich = facade.convert("rtf", 23);
    expect(rich.format).toBe("rtf");
    expect(rich.lost).toEqual([{ code: "heading", count: 1 }]);
    expect(JSON.parse(rich.document).blocks).toHaveLength(2);
    expect(facade.snapshot(23)).toMatchObject({ format: "md", dirty: false });
    facade.load(rich.document, 24, "convert", "rtf");
    const markdown = facade.convert("md", 24);
    expect(markdown).toMatchObject({ format: "md", lost: [] });
    expect(markdown.text).toContain("**Title**");
    expect(facade.convert("rtf", 23)).toMatchObject({
      snapshotError: "stale-document",
    });
  });
});
