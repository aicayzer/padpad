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
      markdown: expect.stringContaining("!"),
    });
    expect(latest("changed").markdown).toBe(facade.snapshot(1).text);
    expect(latest("changed").markdown.endsWith("\r\n")).toBe(true);
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
    facade.load("", 7, "table");
    expect(facade.table("insert", 7)).toBe(true);
    const before = facade.snapshot(7).text;
    const warnings = posted.filter((entry) => entry.type === "editorWarning");
    const refusal = facade.insertText("one\ntwo", 7);
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
});
