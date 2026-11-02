# Format control comparison

A standalone macOS comparison of 14 system-control presentations for enabling multiple formats. Each example includes the same single-selection Default format picker as a reference.

The examples use standard SwiftUI controls and unmodified AppKit controls. No arrows, bezels, hover effects, focus rings, or inactive colors are drawn by the comparison. AppKit adapters connect the controls to temporary example values.

The app does not read or write PadPad preferences, open documents, or register shortcuts. Each example starts with all three formats enabled, prevents disabling the final format, and updates its default format when necessary. Reset Examples restores all examples.

## Presentations

1. Automatic SwiftUI menu
2. Borderless SwiftUI menu
3. Bordered AppKit pop-up button
4. Borderless AppKit pop-up button
5. AppKit pull-down button
6. Standard button with a checkbox popover
7. Borderless button with a checkbox popover
8. Disclosure group with checkboxes
9. Vertical checkboxes
10. Horizontal checkboxes
11. Separate switches
12. Multiple-selection AppKit segmented control
13. Standard button with a native multiple-selection list
14. Standard button with a checkbox sheet

These cover the relevant system-control families and their compact or expanded presentations. A single-selection picker, radio group, or single-selection segmented picker cannot independently enable multiple formats.

## Build

Requires Xcode 27 and macOS 27. From the repository root, with Xcode selected as the developer directory:

```sh
mkdir -p '_tmp/Format Control Comparison.app/Contents/MacOS'
cp Design/FormatControls/Info.plist '_tmp/Format Control Comparison.app/Contents/Info.plist'
xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos27.0 \
  -framework SwiftUI -framework AppKit Design/FormatControls/FormatControls.swift \
  -o '_tmp/Format Control Comparison.app/Contents/MacOS/FormatControls'
```

This builds a separate app without launching it or rebuilding PadPad. Sign the bundle with the existing local development identity before interactive review.

## Review

Compare each enabled-formats control with the Default format row immediately below it. Check hover, keyboard focus, the open menu or popover, and the inactive appearance after activating another window. Check the count after enabling or disabling formats. Menus close after a selection; checkbox popovers remain open for multiple changes.

The selection list uses the standard Command-click and Shift-click gestures. The sheet closes with Done. The disclosure group expands within the form.
