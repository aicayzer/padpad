import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { InkKitEditor } from "@aicayzer/inkkit";

describe("packed editor consumer", () => {
  let root: HTMLDivElement;
  let editor: InkKitEditor;
  beforeEach(async () => {
    root = document.createElement("div");
    document.body.append(root);
    editor = await InkKitEditor.mount(root, {
      changed() {},
      openLink() {},
      copy() {},
    });
  });
  afterEach(async () => {
    await editor?.destroy();
    root.remove();
  });

  it("keeps loaded source and rejects stale document snapshots", () => {
    const text =
      "\uFEFF---\r\ntitle: Draft\r\n---\r\n\r\n__bold__\r\n\r\nTail\r\n";
    editor.loadDocument({
      documentId: "fixture",
      generation: 1,
      format: "md",
      text,
    });
    expect(editor.snapshot(1)).toMatchObject({
      text,
      dirty: false,
      documentId: "fixture",
      generation: 1,
    });
    expect(() => editor.snapshot(0)).toThrow();
  });

  it("exports formatted content as readable text and semantic HTML", async () => {
    editor.loadDocument({
      documentId: "clipboard",
      generation: 1,
      format: "md",
      text: "tight. and **bold** \n",
    });
    const clipboard = await editor.clipboardSnapshot("document");
    expect(clipboard.text).toContain("tight. and bold");
    expect(clipboard.text).not.toContain("&#x20;");
    expect(clipboard.text).not.toContain("**");
    expect(clipboard.html).toContain("<strong>bold</strong>");
  });

  it("imports an editable HTML table without concatenating its cells", async () => {
    editor.loadDocument({
      documentId: "table",
      generation: 1,
      format: "md",
      text: "",
    });
    await editor.paste({
      text: "Name\tValue\nAlice\t42",
      html: "<table><tr><th>Name</th><th>Value</th></tr><tr><td>Alice</td><td>42</td></tr></table>",
    });
    expect(editor.snapshot().text).toMatch(/\|\s*Alice\s*\|\s*42\s*\|/);
    expect((await editor.clipboardSnapshot("document")).html).toContain(
      "<table",
    );
  });

  it("keeps TXT literal while Markdown plain paste inserts literal markers", () => {
    const text = "**literal**\r\n";
    editor.loadDocument({
      documentId: "text",
      generation: 1,
      format: "txt",
      text,
    });
    expect(editor.snapshot().text).toBe(text);
    editor.loadDocument({
      documentId: "markdown",
      generation: 2,
      format: "md",
      text: "",
    });
    editor.pasteAsPlainText("**literal**");
    expect(editor.snapshot().text).toContain("\\*\\*literal\\*\\*");
  });
  it("switches source without losing untidy input and keeps source undo available", () => {
    const text = "---\r\ntitle: draft\r\n---\r\n\r\n__bold__  \r\n\r\n";
    editor.loadDocument({
      documentId: "source",
      generation: 7,
      format: "md",
      text,
    });
    expect(editor.setEditingMode("source", 7)).toBe(true);
    expect(editor.snapshot(7).text).toBe(text);
    expect(editor.commandState(7).commands.format.bold).toBe(false);
    expect(editor.replaceAll("draft", "edited", 7)).toBe(1);
    expect(editor.commandState(7).commands.undo).toBe(true);
    expect(editor.undo(7)).toBe(true);
    expect(editor.snapshot(7).text).toBe(text);
    expect(editor.redo(7)).toBe(true);
    expect(editor.snapshot(7).text).toContain("edited");
    expect(() => editor.replaceAll("edited", "lost", 6)).toThrow();
    expect(editor.snapshot(7).text).toContain("edited");
  });

  it("searches source syntax separately from formatted readable text", () => {
    editor.loadDocument({
      documentId: "search",
      generation: 1,
      format: "md",
      text: "**bold** and bold",
    });
    expect(editor.replaceAll("**bold**", "source", 1)).toBe(0);
    expect(editor.setEditingMode("source", 1)).toBe(true);
    expect(editor.replaceAll("**bold**", "source", 1)).toBe(1);
    expect(editor.snapshot(1).text).toBe("source and bold");
    expect(editor.replaceAll("", "untouched", 1)).toBe(0);
  });

  it("freezes complete printable HTML and rejects stale print scope", async () => {
    editor.loadDocument({
      documentId: "print",
      generation: 4,
      format: "md",
      text: "# Title\n\n**bold**\n\n<unsafe>",
    });
    const output = await editor.printableSnapshot(4);
    expect(output).toMatchObject({
      documentId: "print",
      generation: 4,
      format: "md",
      assets: [],
    });
    expect(output.html).toContain("<!DOCTYPE html>");
    expect(output.html).toContain("<style>");
    expect(output.html).toContain("<strong>bold</strong>");
    expect(output.html).not.toContain("<unsafe>");
    expect(output.styles).toContain("height: auto");
    editor.loadDocument({
      documentId: "next",
      generation: 5,
      format: "md",
      text: "Other",
    });
    expect(output.html).toContain("Title");
    expect(output.html).not.toContain("Other");
    await expect(editor.printableSnapshot(4)).rejects.toThrow();
  });
});
