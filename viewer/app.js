const svg = document.getElementById("scene");
const legendEl = document.getElementById("legend");
const zoomSummaryEl = document.getElementById("zoomSummary");
const selectionEl = document.getElementById("selection");
const summaryEl = document.getElementById("summary");
const resetButton = document.getElementById("resetButton");
const upButton = document.getElementById("upButton");
const themeToggleButton = document.getElementById("themeToggleButton");

const svgNS = "http://www.w3.org/2000/svg";
const rootNodeId = "repo";

let sceneDocument;
let currentRootId = rootNodeId;
let selectedId = null;

function cssColor(name, fallback) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim() || fallback;
}

function setTheme(theme) {
  document.documentElement.dataset.theme = theme;
  themeToggleButton.textContent = theme === "light" ? "Dark" : "Light";
  localStorage.setItem("git-visualization-diff-theme", theme);
}

function currentTheme() {
  return document.documentElement.dataset.theme === "light" ? "light" : "dark";
}

function createSvgElement(name, attrs = {}) {
  const element = document.createElementNS(svgNS, name);
  for (const [key, value] of Object.entries(attrs)) {
    element.setAttribute(key, String(value));
  }
  return element;
}

function languageForHighlightJs(language) {
  switch (language) {
    case "cpp": return "cpp";
    case "c": return "c";
    case "rust": return "rust";
    case "swift": return "swift";
    case "typescript": return "typescript";
    case "javascript": return "javascript";
    case "python": return "python";
    case "json": return "json";
    case "ocaml": return "ocaml";
    case "markdown": return "markdown";
    default: return null;
  }
}

function nodeById(id) {
  return sceneDocument.scene.nodes.find((node) => node.id === id);
}

function childrenOf(nodeId) {
  return sceneDocument.scene.nodes.filter((node) => node.parentId === nodeId && node.kind !== "issue_marker");
}

function issueChildrenOf(nodeId) {
  return sceneDocument.scene.nodes.filter((node) => node.parentId === nodeId && node.kind === "issue_marker");
}

function descendantNodesOf(nodeId) {
  const result = [];
  const queue = [...childrenOf(nodeId), ...issueChildrenOf(nodeId)];
  while (queue.length > 0) {
    const node = queue.shift();
    result.push(node);
    queue.push(...childrenOf(node.id), ...issueChildrenOf(node.id));
  }
  return result;
}

function ancestorChain(nodeId) {
  const chain = [];
  let cursor = nodeById(nodeId);
  while (cursor) {
    chain.push(cursor);
    cursor = cursor.parentId ? nodeById(cursor.parentId) : null;
  }
  return chain.reverse();
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

const languageKeywords = {
  rust: [
    "as", "async", "await", "const", "crate", "dyn", "else", "enum", "fn", "for",
    "if", "impl", "let", "match", "mod", "move", "mut", "pub", "ref", "return",
    "self", "Self", "static", "struct", "super", "trait", "type", "unsafe", "use",
    "where", "while"
  ],
  cpp: [
    "alignas", "auto", "bool", "break", "case", "class", "const", "constexpr",
    "continue", "delete", "do", "else", "enum", "explicit", "false", "for",
    "if", "inline", "namespace", "new", "noexcept", "private", "protected",
    "public", "return", "sizeof", "static", "struct", "switch", "template",
    "this", "true", "typename", "using", "virtual", "void", "while"
  ],
  c: [
    "auto", "bool", "break", "case", "const", "continue", "default", "do", "else",
    "enum", "extern", "false", "for", "if", "inline", "return", "sizeof", "static",
    "struct", "switch", "true", "typedef", "union", "void", "while"
  ],
  swift: [
    "actor", "as", "async", "await", "case", "class", "defer", "else", "enum",
    "extension", "false", "for", "func", "guard", "if", "import", "in", "init",
    "let", "nil", "private", "protocol", "public", "return", "self", "static",
    "struct", "switch", "throw", "throws", "true", "typealias", "var", "while"
  ]
};

function syntaxRules(language) {
  const keywords = languageKeywords[language] ?? [];
  const keywordRule = keywords.length > 0
    ? [{ regex: new RegExp(`\\b(${keywords.map(escapeRegExp).join("|")})\\b`, "g"), className: "syntax-keyword" }]
    : [];
  return [
    { regex: /\/\/.*/g, className: "syntax-comment" },
    { regex: /"([^"\\]|\\.)*"/g, className: "syntax-string" },
    { regex: /\b\d+(?:\.\d+)?\b/g, className: "syntax-number" },
    ...keywordRule,
    { regex: /\b[A-Z][A-Za-z0-9_]*\b/g, className: "syntax-type" },
    { regex: /\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()/g, className: "syntax-function" }
  ];
}

function tokenizeSyntax(text, language) {
  const matches = [];
  for (const rule of syntaxRules(language)) {
    for (const match of text.matchAll(rule.regex)) {
      matches.push({
        start: match.index,
        end: match.index + match[0].length,
        className: rule.className,
        text: match[0]
      });
    }
  }
  matches.sort((left, right) => left.start - right.start || right.end - left.end);

  const tokens = [];
  let cursor = 0;
  for (const match of matches) {
    if (match.start < cursor) continue;
    if (match.start > cursor) {
      tokens.push({ text: text.slice(cursor, match.start), className: null });
    }
    tokens.push({ text: match.text, className: match.className });
    cursor = match.end;
  }
  if (cursor < text.length) {
    tokens.push({ text: text.slice(cursor), className: null });
  }
  return tokens;
}

function appendHighlightedText(textElement, text, language) {
  const highlighted = highlightWithHighlightJs(text, language);
  if (highlighted) {
    appendHighlightedHtml(textElement, highlighted);
    return;
  }
  for (const token of tokenizeSyntax(text, language)) {
    const tspan = createSvgElement("tspan", token.className ? { class: token.className } : {});
    tspan.textContent = token.text;
    textElement.appendChild(tspan);
  }
}

function highlightWithHighlightJs(text, language) {
  const highlighter = globalThis.hljs;
  const hljsLanguage = languageForHighlightJs(language);
  if (!highlighter || !hljsLanguage || !highlighter.getLanguage?.(hljsLanguage)) return null;
  try {
    return highlighter.highlight(text, {
      language: hljsLanguage,
      ignoreIllegals: true
    }).value;
  } catch {
    return null;
  }
}

function appendHighlightedHtml(textElement, html) {
  const template = document.createElement("template");
  template.innerHTML = html;
  const appendNode = (node, inheritedClass = null) => {
    if (node.nodeType === Node.TEXT_NODE) {
      if (node.textContent.length === 0) return;
      const attrs = inheritedClass ? { class: inheritedClass } : {};
      const tspan = createSvgElement("tspan", attrs);
      tspan.textContent = node.textContent;
      textElement.appendChild(tspan);
      return;
    }
    if (node.nodeType !== Node.ELEMENT_NODE) return;
    const className = node.getAttribute("class") ?? inheritedClass;
    for (const child of node.childNodes) appendNode(child, className);
  };
  for (const child of template.content.childNodes) appendNode(child);
}

function renderLegend(legend = []) {
  legendEl.innerHTML = "";
  for (const entry of legend) {
    const row = document.createElement("div");
    row.className = "legend-item";
    const swatch = document.createElement("span");
    swatch.className = "legend-swatch";
    swatch.style.background = entry.color ?? cssColor("--node-fill", "#202938");
    row.appendChild(swatch);
    const label = document.createElement("span");
    label.textContent = entry.label;
    row.appendChild(label);
    legendEl.appendChild(row);
  }
}

function summarizeNode(node) {
  const lines = [`${node.kind}: ${node.name}`];
  if (node.path !== undefined) lines.push(`path: ${node.path || "<repo root>"}`);
  if (node.oldPath) lines.push(`old path: ${node.oldPath}`);
  if (node.language) lines.push(`language: ${node.language}`);
  if (node.languageKind) lines.push(`language kind: ${node.languageKind}`);
  if (node.lineCount !== undefined) lines.push(`lines: ${node.lineCount}`);
  if (node.diff) {
    lines.push(`added: ${node.diff.linesAdded}, removed: ${node.diff.linesRemoved}, ratio: ${node.diff.changedRatio.toFixed(3)}`);
  }
  if (node.semantic?.patterns?.length) lines.push(`patterns: ${node.semantic.patterns.join(", ")}`);
  if (node.semantic?.paradigms?.length) lines.push(`paradigms: ${node.semantic.paradigms.join(", ")}`);
  if (node.semantic?.issues?.length) lines.push(`issues: ${node.semantic.issues.join(", ")}`);
  if (node.semantic?.severity) lines.push(`severity: ${node.semantic.severity}`);
  return lines.join("\n");
}

function updateSelection(node) {
  selectionEl.textContent = node ? summarizeNode(node) : "Nothing selected.";
}

function severityColor(severity) {
  switch (severity) {
    case "error": return cssColor("--severity-error", "#fb7185");
    case "warning": return cssColor("--severity-warning", "#fbbf24");
    case "info": return cssColor("--severity-info", "#22d3ee");
    default: return cssColor("--severity-default", "#a7b0c0");
  }
}

function summarizedIssuesForNode(nodeId) {
  const issues = new Map();
  for (const node of descendantNodesOf(nodeId)) {
    if (node.kind !== "issue_marker") continue;
    for (const issue of node.semantic?.issues ?? []) {
      issues.set(issue, node.semantic?.severity);
    }
  }
  return Array.from(issues.entries()).sort().map(([issue, severity]) => ({ issue, severity }));
}

function updateZoomSummary(root, visible) {
  const counts = new Map();
  for (const node of visible) counts.set(node.kind, (counts.get(node.kind) ?? 0) + 1);
  const kinds = Array.from(counts.entries()).map(([kind, count]) => `${count} ${kind}`).join(", ");
  zoomSummaryEl.innerHTML = "";
  const text = document.createElement("div");
  text.textContent = `${root?.name ?? "scene"} has ${visible.length} child node${visible.length === 1 ? "" : "s"}${kinds ? ` (${kinds})` : ""}.`;
  zoomSummaryEl.appendChild(text);
  const issueRow = document.createElement("div");
  issueRow.style.marginTop = "10px";
  const issues = summarizedIssuesForNode(currentRootId);
  if (issues.length === 0) {
    issueRow.textContent = "No issue markers in this zoom.";
  } else {
    for (const issue of issues) {
      const chip = document.createElement("span");
      chip.className = "issue-chip";
      chip.style.color = severityColor(issue.severity);
      chip.style.background = `${severityColor(issue.severity)}22`;
      chip.textContent = issue.issue;
      issueRow.appendChild(chip);
    }
  }
  zoomSummaryEl.appendChild(issueRow);
}

function lineNumberText(line) {
  const oldLine = line.oldLine === undefined ? "" : String(line.oldLine);
  const newLine = line.newLine === undefined ? "" : String(line.newLine);
  return `${oldLine.padStart(4, " ")} ${newLine.padStart(4, " ")}`;
}

function changeColor(kind, node) {
  if (kind === "deletion" || node?.status === "deleted") return node?.render?.deletionColor ?? cssColor("--deletion", "#fb7185");
  return node?.render?.additionColor ?? cssColor("--addition", "#4ade80");
}

function drawLineChangeMarkers(group, node, width, height, options = {}) {
  const changes = node.lineChanges ?? [];
  if (changes.length === 0) return;
  const lineCount = Math.max(node.lineCount ?? 1, 1);
  const top = options.top ?? 42;
  const markerHeight = Math.max(1, height - top - (options.bottomPadding ?? 14));
  for (const change of changes) {
    const y = top + ((change.startLine - 1) / lineCount) * markerHeight;
    const h = Math.max(2, (change.lineCount / lineCount) * markerHeight);
    group.appendChild(createSvgElement("rect", {
      x: options.x ?? width - 9,
      y,
      width: options.width ?? 3,
      height: Math.min(h, markerHeight),
      fill: changeColor(change.kind, node),
      opacity: options.opacity ?? 0.82
    }));
  }
}

function drawNetDiffBar(group, node, width, height) {
  const added = node.diff?.linesAdded ?? 0;
  const removed = node.diff?.linesRemoved ?? 0;
  const total = added + removed;
  if (total <= 0) return;
  const addedWidth = width * (added / total);
  group.appendChild(createSvgElement("rect", {
    x: 0,
    y: height - 10,
    width: addedWidth,
    height: 10,
    fill: cssColor("--addition", "#4ade80"),
    opacity: 0.86
  }));
  group.appendChild(createSvgElement("rect", {
    x: addedWidth,
    y: height - 10,
    width: width - addedWidth,
    height: 10,
    fill: cssColor("--deletion", "#fb7185"),
    opacity: 0.86
  }));
}

function preferredLane(kind) {
  switch (kind) {
    case "directory": return "Directories";
    case "file": return "Files";
    case "type_container": return "Types";
    case "function": return "Functions";
    case "symbol": return "Symbols";
    default: return "Other";
  }
}

function changedWeight(node) {
  return (node.diff?.linesAdded ?? 0) + (node.diff?.linesRemoved ?? 0);
}

function layoutLanes(nodes) {
  const laneOrder = ["Directories", "Files", "Types", "Functions", "Symbols", "Other"];
  const grouped = new Map(laneOrder.map((lane) => [lane, []]));
  for (const node of nodes) grouped.get(preferredLane(node.kind)).push(node);

  const lanes = [];
  let y = 62;
  for (const lane of laneOrder) {
    const laneNodes = grouped.get(lane);
    if (!laneNodes?.length) continue;
    laneNodes.sort((left, right) =>
      changedWeight(right) - changedWeight(left) ||
      (right.diff?.changedRatio ?? 0) - (left.diff?.changedRatio ?? 0) ||
      left.name.localeCompare(right.name)
    );
    let x = 28;
    let rowBottom = y + 22;
    const cards = [];
    for (const node of laneNodes) {
      const normalized = Math.max(0.12, node.render?.normalizedSize ?? 0.2);
      const width = Math.round(172 + normalized * 170);
      const height = Math.round(88 + normalized * 50);
      if (x + width > 1172) {
        x = 28;
        y = rowBottom + 18;
      }
      cards.push({ node, x, y: y + 24, width, height });
      rowBottom = Math.max(rowBottom, y + 24 + height);
      x += width + 16;
    }
    lanes.push({ title: lane, y, cards });
    y = rowBottom + 34;
  }
  return lanes;
}

function nodeFill(node) {
  if (node.status === "added") return cssColor("--node-fill-added", "#06351f");
  if (node.status === "deleted") return cssColor("--node-fill-deleted", "#3a1117");
  if (currentTheme() === "light") return node.render?.baseColor ?? cssColor("--node-fill", "#e5e7eb");
  return cssColor("--node-fill", "#202938");
}

function breadcrumbText(nodeId) {
  return ancestorChain(nodeId).map((node) => node.name).join(" / ");
}

function goToNode(nodeId) {
  const node = nodeById(nodeId);
  if (!node) return;
  currentRootId = node.id;
  selectedId = node.id;
  updateSelection(node);
  renderScene();
}

function goUp() {
  const root = nodeById(currentRootId);
  if (root?.parentId) goToNode(root.parentId);
}

function renderFileDiff(root, semanticChildren) {
  const rows = [];
  for (const hunk of root.hunks ?? []) {
    rows.push({ kind: "hunk", text: hunk.header });
    for (const line of hunk.lines ?? []) rows.push(line);
  }
  if (rows.length === 0 && root.status === "added") rows.push({ kind: "hunk", text: `new file: ${root.path}` });
  if (rows.length === 0 && root.status === "deleted") rows.push({ kind: "hunk", text: `deleted file: ${root.oldPath ?? root.path}` });
  if (rows.length === 0) rows.push({ kind: "hunk", text: "No textual diff available." });

  const panel = createSvgElement("g", { transform: "translate(28, 70)" });
  const width = 1144;
  const rowHeight = 18;
  const diffHeight = Math.min(620, Math.max(170, rows.length * rowHeight + 46));
  panel.appendChild(createSvgElement("rect", {
    x: 0,
    y: 0,
    width,
    height: diffHeight,
    rx: 8,
    ry: 8,
    fill: root.status === "added"
      ? cssColor("--diff-frame-added", "#06291b")
      : root.status === "deleted"
        ? cssColor("--diff-frame-deleted", "#2f1116")
        : cssColor("--diff-frame", "#0f172a"),
    stroke: root.render?.outlineColor ?? cssColor("--border", "#475569"),
    "stroke-width": 2
  }));
  drawLineChangeMarkers(panel, root, width, diffHeight, { x: width - 8, top: 32, bottomPadding: 10, width: 4 });

  const title = createSvgElement("text", { x: 14, y: 23, class: "diff-title" });
  title.textContent = root.path ?? root.name;
  panel.appendChild(title);

  const visibleRows = rows.slice(0, Math.floor((diffHeight - 40) / rowHeight));
  visibleRows.forEach((row, index) => {
    const y = 44 + index * rowHeight;
    if (row.kind === "addition" || row.kind === "deletion") {
      panel.appendChild(createSvgElement("rect", {
        x: 8,
        y: y - 13,
        width: width - 28,
        height: rowHeight,
        fill: changeColor(row.kind, root),
        opacity: 0.15
      }));
    }
    const text = createSvgElement("text", { x: 16, y, class: `diff-line ${row.kind ?? "context"}` });
    if (row.kind === "hunk") {
      text.textContent = row.text;
    } else {
      const prefix = row.kind === "addition" ? "+" : row.kind === "deletion" ? "-" : " ";
      const gutter = `${lineNumberText(row)} ${prefix}`;
      const gutterSpan = createSvgElement("tspan");
      gutterSpan.textContent = gutter;
      text.appendChild(gutterSpan);
      appendHighlightedText(text, row.content ?? "", root.language);
    }
    panel.appendChild(text);
  });
  svg.appendChild(panel);

  if (semanticChildren.length > 0) {
    const title = createSvgElement("text", { x: 32, y: diffHeight + 112, class: "lane-title" });
    title.textContent = "Changed Structures";
    svg.appendChild(title);
    let x = 32;
    for (const child of semanticChildren.slice(0, 5)) {
      const group = renderCard(child, x, diffHeight + 128, 210, 84, false);
      svg.appendChild(group);
      x += 224;
    }
  }
}

function renderCard(node, x, y, width, height, zoomOnClick = true) {
  const group = createSvgElement("g", {
    transform: `translate(${x}, ${y})`,
    class: `scene-node${selectedId === node.id ? " selected" : ""}`,
    opacity: node.render?.opacity ?? 1
  });
  group.appendChild(createSvgElement("rect", {
    x: 0,
    y: 0,
    rx: 8,
    ry: 8,
    width,
    height,
    fill: nodeFill(node),
    stroke: node.render?.outlineColor ?? cssColor("--border", "#64748b"),
    "stroke-width": node.render?.priority === "context" ? 1 : 2
  }));
  drawLineChangeMarkers(group, node, width, height);
  drawNetDiffBar(group, node, width, height);

  const label = createSvgElement("text", { x: 12, y: 22, class: "node-label" });
  label.textContent = node.name;
  group.appendChild(label);

  const meta = [node.kind, node.languageKind ?? node.language, node.lineCount !== undefined ? `${node.lineCount} lines` : null]
    .filter(Boolean).join("  ");
  const metaText = createSvgElement("text", { x: 12, y: 42, class: "node-meta" });
  metaText.textContent = meta;
  group.appendChild(metaText);

  const diffText = createSvgElement("text", { x: 12, y: 62, class: "node-meta" });
  diffText.textContent = `+${node.diff?.linesAdded ?? 0} / -${node.diff?.linesRemoved ?? 0}`;
  group.appendChild(diffText);

  const semantic = [...(node.semantic?.patterns ?? []), ...(node.semantic?.paradigms ?? [])].slice(0, 2).join(", ");
  if (semantic) {
    const semanticText = createSvgElement("text", { x: 12, y: 82, class: "node-meta" });
    semanticText.textContent = semantic;
    group.appendChild(semanticText);
  }

  const issues = summarizedIssuesForNode(node.id);
  if (issues.length > 0) {
    group.appendChild(createSvgElement("circle", { cx: width - 16, cy: 16, r: 10, fill: severityColor(issues[0].severity) }));
    const issueText = createSvgElement("text", { x: width - 19, y: 20, class: "node-meta", fill: "#fff" });
    issueText.textContent = String(issues.length);
    group.appendChild(issueText);
  }

  group.addEventListener("click", () => {
    selectedId = node.id;
    updateSelection(node);
    if (zoomOnClick) currentRootId = node.id;
    renderScene();
  });
  return group;
}

function renderScene() {
  svg.innerHTML = "";
  const root = nodeById(currentRootId);
  const visible = childrenOf(currentRootId);
  summaryEl.textContent = root
    ? `Viewing ${root.name} (${root.kind}) with ${visible.length} child node${visible.length === 1 ? "" : "s"}`
    : "Viewing scene";
  updateZoomSummary(root, visible);
  upButton.disabled = !root?.parentId;

  const breadcrumb = createSvgElement("text", { x: 32, y: 18, class: "breadcrumb" });
  breadcrumb.textContent = breadcrumbText(currentRootId);
  svg.appendChild(breadcrumb);
  const title = createSvgElement("text", { x: 32, y: 40, class: "node-label" });
  title.textContent = root ? `${root.kind}: ${root.name}` : "Scene";
  svg.appendChild(title);

  if (root?.kind === "file") {
    renderFileDiff(root, visible);
    return;
  }

  for (const lane of layoutLanes(visible)) {
    const laneTitle = createSvgElement("text", { x: 32, y: lane.y, class: "lane-title" });
    laneTitle.textContent = lane.title;
    svg.appendChild(laneTitle);
    for (const card of lane.cards) {
      svg.appendChild(renderCard(card.node, card.x, card.y, card.width, card.height));
    }
  }
}

async function boot() {
  setTheme(localStorage.getItem("git-visualization-diff-theme") === "light" ? "light" : "dark");
  const response = await fetch("/scene.json");
  if (!response.ok) throw new Error(`scene request failed: ${response.status}`);
  sceneDocument = await response.json();
  renderLegend(sceneDocument.scene?.legend ?? []);
  currentRootId = nodeById(rootNodeId) ? rootNodeId : sceneDocument.scene.nodes[0]?.id;
  updateSelection(nodeById(currentRootId));
  renderScene();
}

resetButton.addEventListener("click", () => goToNode(rootNodeId));
upButton.addEventListener("click", goUp);
themeToggleButton.addEventListener("click", () => {
  setTheme(currentTheme() === "light" ? "dark" : "light");
  renderLegend(sceneDocument.scene?.legend ?? []);
  renderScene();
});

boot().catch((error) => {
  summaryEl.textContent = `Failed to load scene: ${error.message}`;
});
