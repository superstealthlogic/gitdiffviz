# Git Visualization Diff UI Style Guide

This guide covers the native Tauri UI surface in `viewer/index.html`, `viewer/styles.css`, and `viewer/app.js`.

## Design Direction

The app is a dense repository inspection tool. Keep the UI quiet, readable, and operational rather than decorative. Controls should look tactile enough to be recognized as controls, but the repository visualization should remain the visual focus.

## Layout

- Topbar: app title and current view summary on the left, global navigation and theme controls on the right.
- Native panel: repository workflow controls in a single horizontal row when space allows.
- Main layout: sidebar, repository canvas, optional timeline panel.
- Repository canvas: primary work area. Empty-state prompts belong inside this panel, not in the topbar or status line.
- Timeline panel: only appears when the loaded document has multiple timeline steps.

Use these spacing defaults:

- Outer page padding: `22px` horizontally.
- Main grid gap: `14px`.
- Native panel gap: `10px`.
- Button/control radius: `6px`.
- Cards and major panels: `8px` radius.

## Typography

The app uses system UI fonts:

```css
font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
```

Guidelines:

- Topbar title: `22px`, bold.
- Panel headings: `14px` to `15px`, bold.
- Toolbar and native panel labels: `12px` to `13px`.
- SVG node labels: `12px`, bold.
- SVG metadata: `10px`.
- Code diff text: `11px` monospace.

Do not scale fonts with viewport width. Prefer stable font sizes and adjust layout instead.

## Color Tokens

Edit theme values in `:root` and `:root[data-theme="light"]`.

Core tokens:

- `--bg`: page background.
- `--panel`: major panel background.
- `--panel-soft`: native control strip background.
- `--border`: panel and control border.
- `--text`: primary text.
- `--muted`: secondary text.
- `--addition` and `--deletion`: diff state colors.
- `--control-top`, `--control-bottom`, `--control-shadow`: bevel treatment.

When tweaking the theme, change tokens first. Avoid one-off colors unless the color represents a semantic state, such as alert red.

## Buttons And Controls

Buttons should use the shared beveled treatment:

- Slight top highlight.
- Darker bottom edge.
- Small outer shadow.
- `translateY(1px)` on active press.

Native workflow controls should keep a consistent height, currently `39px`. The Timeline checkbox is intentionally styled as a larger segmented control so it reads as part of the render mode selection.

Manual tweaks:

- Button height: `.native-panel button`.
- Topbar button padding: `.controls button`.
- Timeline control size: `.native-panel .checkbox-label`.
- Control bevel strength: `--control-top`, `--control-bottom`, and `--control-shadow`.

## Repository Prompt

The empty repository prompt is `#repositoryPrompt`. It is positioned over the repository canvas below the toolbar.

Manual tweaks:

- Vertical offset: `.repository-prompt { inset: 43px 0 0; }`
- Backdrop strength: `.repository-prompt { background: ... }`
- Prompt size: `.repository-prompt { font-size: 20px; }`

The prompt should stay passive: no pointer events and no extra controls inside it.

## Timeline

The timeline panel should remain narrow and scannable:

- Keep `#timelineSlider` tall enough to make commit steps separable.
- Keep tick labels short, preferably short hashes.
- Put detailed commit context in the status line or selection panel, not beside every tick.

Manual tweaks:

- Panel width: `.timeline-panel { width: 148px; }`
- Slider height: `#timelineSlider` and `.timeline-track-wrap`.
- Tick label size: `.timeline-tick-hash`.

## Watch Alerts

Watch mode uses two alert layers:

- In-app badge: `#waitOnBadge`, shown inside the Wait On button.
- Native attention: Tauri `request_user_attention`, triggered only when new commits arrive while the app is out of focus.

The badge count represents new commits detected since the app last became focused. Focus clears the count and asks the native window system to stop requesting attention.

Manual tweaks:

- Badge color: `.watch-badge { background: #dc2626; }`
- Badge size: `.watch-badge { min-width: 18px; height: 18px; }`
- Poll interval: `waitOnPollMs` in `viewer/app.js`.

## Responsive Behavior

Below `1000px`, the main layout collapses into one column and the timeline slider becomes horizontal. Keep mobile controls stable in height and avoid adding text that cannot wrap cleanly.

If adding controls to the native panel, test both:

- Wide desktop, where controls sit in one row.
- Narrow windows, where the grid may need explicit responsive rules.

## SVG Visualization

The SVG scene is the product surface. Keep UI chrome visually subordinate.

Guidelines:

- Do not put decorative cards around the SVG.
- Keep node labels short and truncate in JavaScript when needed.
- Use semantic colors for added, deleted, warnings, and errors.
- Use the sidebar for verbose details.

## Safe Manual Tweak Order

1. Adjust CSS variables first.
2. Tune shared component classes next.
3. Only then add element-specific overrides.
4. Run `node --check viewer/app.js` after JavaScript edits.
5. Run `cargo check` in `native/tauri/src-tauri` after Rust edits.
