# Using Drag 2.0 (Alpha)

[Website](https://dragtwozero.com) · [Project overview](../README.md)

## First launch

Open **Drag 2.0 (Alpha)** and follow the seven-step introduction. On the permission step, use the Accessibility control and enable the app in **System Settings → Privacy & Security → Accessibility**. Return to the introduction once access is granted. After Accessibility, choose whether to **Launch at login**. This is optional and remains off unless you enable it. The guide also covers the shortcut, optional Buffer, and update notifications.

After setup, Drag 2.0 lives in the menu bar. Open its menu for **Settings**, **Turn Off / Turn On**, or **Quit**.

## Drag a block

1. Place the text cursor where you want to insert content in the destination app.
2. Hold **Option + Command** over a paragraph or link in the source app.
3. Click the highlighted block and drag it into the supported input. Release to insert at its existing caret.

The source content stays in place. Drag 2.0 never submits the destination field. Intentionally selected destination text can be replaced; an unrelated selection change cancels the transfer. Press **Escape** to cancel a drag.

Change the trigger shortcut, formatting, appearance, haptics, and animations in Settings. Links and emphasis depend on the attributes exposed by the source app and your formatting preference. Motion respects Reduce Motion.

**Launch at login** is also in **Settings → General**. It uses the macOS login-item setting, so changes made in System Settings are reflected in the app. If macOS requires approval when you turn it on, Drag opens **System Settings → Login Items** so you can finish enabling it. The approval button remains available if you return before approving. Turning it off removes the login item; it does not quit the current session. You still need to open the app once after installation.

**Settings pages:** General contains activation, Accessibility, launch at login, the shortcut and haptics. Behaviour contains Preserve content structure and Overwrite clipboard. Buffer contains its enable switch and position. Appearance contains visual controls and Hide app icon from Dock. Experimental contains Multi-select and Drag selected text.

## Buffer

Using one screen, or need a place for your drag to rest? Enable **Buffer** in **Settings → Experimental** to hold one item for later. Buffer is off by default.

1. Hold the trigger shortcut to reveal **Buffer**, including over empty space.
2. Drag a captured item into its recessed slot, then release the shortcut.
3. Switch to the destination and drag the stored item out of the slot without holding the shortcut.

Buffer holds one item in memory. A deliberate drop onto its slot replaces the stored item. The **×** clears it. Turning Buffer off, turning the app off, or quitting also clears its contents.

**Position of buffer** offers Left bottom, Right bottom, Left top, Right top, and Dynamic Island. Dynamic Island is the default; the position control is disabled while Buffer is off.

An invalid or cancelled drop keeps the item. Buffer inserts through the same saved-caret delivery path as a direct highlighted drag. Confirmed insertion consumes the item. An unconfirmed paste hides the panel until the next explicit shortcut, then shows the stored content with a warning to check the destination before retrying. There is no automatic retry.

## Experimental features

Both features are in **Settings → Experimental** and are off by default.

**Multi-select:** hold the shortcut and drag from empty space across blocks. Release the shortcut while still pressing the mouse or trackpad to drag the group. If you release the mouse first, keep holding the shortcut and click a highlighted block or the hint to start dragging. Releasing the shortcut before starting that drag clears the group.

Images are skipped while supported text and links remain in the group. A selection containing only images has nothing to capture. Unreadable or changed text still cancels safely.

Some browsers expose clickable images and avatars as links. Including one in a mixed selection can cause the highlights to disappear when dragging starts if that link cannot be revalidated. Leave that item out of the group or drag a supported link individually. This is a known Multi-select limitation.

**Drag selected text:** select a passage natively, then hold the shortcut. A **Drag selected text** hint appears under the pointer without outlining the source selection. Grab that hint, drag it into an input, and release the mouse to drop. After grabbing, you can release the shortcut and keep dragging. Releasing the shortcut before grabbing cancels the hint; Escape cancels at any time. Clicking outside the hint cancels and lets that click reach the source app. This requires readable selected text through Accessibility, but does not require bounds for every selected line. The selection is checked again when the hint is grabbed; changed or unreadable text is rejected.

Formatting also depends on the attributes the source exposes for that selection. Some browsers expose bold text but omit link destinations; the selected words remain plain text for those links. Drag does not infer a URL from color or underlining.

With Drag selected text enabled, an unreadable selection can still prevent capture. A stable browser object/control range that contains no text leaves ordinary block capture available. Missing source text, changed markers or an expired read are rejected. Turning off **Drag selected text** bypasses selected-text pickup; other capture limitations still apply. This is not tied to whether an input is open.

## Clipboard and privacy

In **Settings → About**, use **Check for Updates → Download & Install → Restart**. Each action requires your confirmation. Finish or cancel an active capture/transfer and use or explicitly clear Buffer before restarting. Cancel stops the pending update. Periodic checks can be disabled with **Notify about updates**; manual checks remain available.

**Overwrite clipboard** in Behaviour is off by default. Buffer and direct highlight drops temporarily use the clipboard, restoring its previous contents after confirmed insertion when Drag 2.0 still owns that clipboard revision. Parking an item in Buffer does not change the clipboard. With the option on, confirmed delivered content remains available to paste. A newer copy always takes priority. An unconfirmed paste can leave the captured content on the clipboard for late readers and recovery; check the destination before retrying.

Captured content is processed locally. Optional Screen Recording permission is used for small brightness samples to adapt glass contrast; no frames are saved or uploaded. Update checks contact GitHub and can be disabled in About. See [Legal & Privacy](https://dragtwozero.com/legal#app-privacy).

## Compatibility and limitations

- Apple Silicon only, installable on macOS 13+. Official support is limited to the latest major macOS release once validated. Older versions may work but are unsupported; compatibility is not guaranteed. Liquid Glass requires macOS 26 or later.
- This candidate was tested on macOS 26.4.1; macOS 27 validation is pending. The installation minimum does not mean every installable OS version has been tested.
- Capture and insertion depend on each app's Accessibility support. There is no complete verified app/browser compatibility matrix yet.
- Google Docs canvas targeting is disabled. Table drops require a writable cell and replace that cell's value.
- A [known Chromium clipboard race](#known-chromium-paste-issue) can prevent insertion after Paste, including with both experimental features off. A posted Paste command alone does not prove insertion.
- Rich editors may render emoji as images. If their complete inserted content or line boundaries cannot be established through Accessibility, the transfer remains unconfirmed and Buffer preserves the item for recovery.
- Experimental selection features have additional Accessibility requirements and can safely reject unsupported content.

### Known Chromium paste issue

On affected macOS Chrome/Chromium builds, a direct or Buffer drop can reach the input and send Paste without inserting anything. This is separate from experimental highlighting and mixed-selection limitations. Chromium has an [upstream fix for a clipboard sequence-token race](https://chromium.googlesource.com/chromium/src/+/fc5529f522a28df6ff5d5f7e572debc71d6f18e4) that matches the observed symptom: the browser can generate two different tokens for the same clipboard revision and discard the insertion.

Exact source versions checked on 27 October 2026:

- [155.0.8059.85](https://chromium.googlesource.com/chromium/src/+/155.0.8059.85/ui/base/clipboard/clipboard_mac.mm) and [156.0.8078.48](https://chromium.googlesource.com/chromium/src/+/156.0.8078.48/ui/base/clipboard/clipboard_mac.mm) still contain the affected logic.
- [157.0.8103.15 Beta](https://chromium.googlesource.com/chromium/src/+/157.0.8103.15/ui/base/clipboard/clipboard_mac.mm) contains the upstream correction. This source check does not establish the earliest fixed release or guarantee compatibility with every Chromium-based app.

A newer version number alone is not proof of the fix. Use a browser build confirmed to contain the correction, fully quit and reopen it after updating, and verify insertion in your actual input. An updated app bundle on disk does not update an already running browser session. The Beta source comparison is not a recommendation to depend on a testing browser for normal use.

Check the destination before retrying so a late insertion is not duplicated. An unconfirmed drop keeps its Buffer item for recovery and can leave captured content on the clipboard even with Overwrite clipboard off. Drag does not automatically retry Paste or bypass destination validation. The match to the upstream issue does not prove that every missing insertion has the same cause.

When reporting an issue, include macOS, Drag 2.0, source app, and destination app versions, plus a reproduction using synthetic text. Do not attach private documents or clipboard dumps. Follow [CONTRIBUTING.md](../CONTRIBUTING.md) for bugs and proposals, or [SECURITY.md](../SECURITY.md) for private security reports.
