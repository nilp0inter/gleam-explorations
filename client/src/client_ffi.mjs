let chart = null;
let currentNodes = [];
let currentLinks = [];
let eventsRegistered = false;
let externalHighlight = false; // true when Gleam controls the highlight
let activeSelection = [];      // node names currently selected from Gleam

const DIM_OPACITY = 0.08;

function getChart() {
  if (chart) return chart;
  const el = document.getElementById("sankey-chart");
  if (!el) return null;
  chart = echarts.init(el);
  window.addEventListener("resize", () => chart && chart.resize());
  return chart;
}

const RED_NUMBERS = new Set([1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]);

const DEPTH_MAP = {};
["Low Force", "Medium Force", "High Force"].forEach((n) => (DEPTH_MAP[n] = 0));
["Short Duration", "Medium Duration", "Long Duration"].forEach((n) => (DEPTH_MAP[n] = 1));
for (let i = 0; i <= 36; i++) DEPTH_MAP[String(i)] = 2;
["Red", "Black", "Green"].forEach((n) => (DEPTH_MAP[n] = 3));

const COLOR_MAP = {
  "Low Force": "#60a5fa",
  "Medium Force": "#f59e0b",
  "High Force": "#a855f7",
  "Short Duration": "#60a5fa",
  "Medium Duration": "#f59e0b",
  "Long Duration": "#a855f7",
  "Red": "#dc2626",
  "Black": "#1f2937",
  "Green": "#16a34a",
};
// Number nodes get their roulette color
COLOR_MAP["0"] = "#16a34a";
for (let i = 1; i <= 36; i++) {
  COLOR_MAP[String(i)] = RED_NUMBERS.has(i) ? "#dc2626" : "#1f2937";
}

// Build adjacency maps from current links
function buildAdjacency() {
  const downstream = {}; // source -> [target]
  const upstream = {};   // target -> [source]
  for (const link of currentLinks) {
    if (!downstream[link.source]) downstream[link.source] = [];
    downstream[link.source].push(link.target);
    if (!upstream[link.target]) upstream[link.target] = [];
    upstream[link.target].push(link.source);
  }
  return { downstream, upstream };
}

// BFS from a set of start nodes in both directions through all levels
function getFullChain(startNodes) {
  const { downstream, upstream } = buildAdjacency();
  const visited = new Set(startNodes);

  // Trace upstream
  const upQueue = [...startNodes];
  while (upQueue.length) {
    const current = upQueue.shift();
    for (const prev of upstream[current] || []) {
      if (!visited.has(prev)) {
        visited.add(prev);
        upQueue.push(prev);
      }
    }
  }

  // Trace downstream
  const downQueue = [...startNodes];
  while (downQueue.length) {
    const current = downQueue.shift();
    for (const next of downstream[current] || []) {
      if (!visited.has(next)) {
        visited.add(next);
        downQueue.push(next);
      }
    }
  }

  return visited;
}

// Group selected nodes by depth, union chains within each depth (OR),
// then intersect across depths (AND).
function computeActiveNodes(nodeNames) {
  // Group by depth
  const byDepth = {};
  for (const name of nodeNames) {
    const d = DEPTH_MAP[name];
    if (d === undefined) continue;
    if (!byDepth[d]) byDepth[d] = [];
    byDepth[d].push(name);
  }

  const depths = Object.keys(byDepth);
  if (depths.length === 0) return new Set();

  // For each depth: union the chains of all selected nodes at that depth
  const perDepth = depths.map((d) => {
    const union = new Set();
    for (const name of byDepth[d]) {
      for (const n of getFullChain([name])) {
        union.add(n);
      }
    }
    return union;
  });

  // Intersect across depths
  return perDepth.reduce((acc, set) => {
    const result = new Set();
    for (const node of acc) {
      if (set.has(node)) result.add(node);
    }
    return result;
  });
}

function applyHighlight(c, activeNodes) {
  const nodes = currentNodes.map((n) => ({
    name: n.name,
    itemStyle: {
      color: COLOR_MAP[n.name] || "#888",
      opacity: activeNodes.has(n.name) ? 1 : DIM_OPACITY,
    },
  }));

  const links = currentLinks.map((l) => {
    const active = activeNodes.has(l.source) && activeNodes.has(l.target);
    return {
      source: l.source,
      target: l.target,
      value: l.value,
      lineStyle: {
        opacity: active ? 0.6 : DIM_OPACITY * 0.5,
      },
    };
  });

  c.setOption({
    series: [{ data: nodes, links }],
  });
}

function resetHighlight(c) {
  const nodes = currentNodes.map((n) => ({
    name: n.name,
    itemStyle: {
      color: COLOR_MAP[n.name] || "#888",
      opacity: 1,
    },
  }));

  const links = currentLinks.map((l) => ({
    source: l.source,
    target: l.target,
    value: l.value,
    lineStyle: { opacity: 0.4 },
  }));

  c.setOption({
    series: [{ data: nodes, links }],
  });
}

function setupChartEvents(c) {
  if (eventsRegistered) return;
  eventsRegistered = true;

  c.on("mouseover", "series.sankey", (params) => {
    if (externalHighlight) return;
    if (params.dataType === "node") {
      const chain = getFullChain([params.name]);
      applyHighlight(c, chain);
    }
  });

  c.on("mouseout", "series.sankey", (params) => {
    if (externalHighlight) return;
    if (params.dataType === "node") {
      resetHighlight(c);
    }
  });
}

export function updateChart(jsonString) {
  const c = getChart();
  if (!c) return;

  const links = JSON.parse(jsonString);
  if (links.length === 0) {
    c.setOption({ series: [] });
    return;
  }

  // Fixed node order: left-to-right within each depth level
  const NUMBERS = [];
  for (let i = 0; i <= 36; i++) NUMBERS.push(String(i));
  const NODE_ORDER = [
    "Low Force", "Medium Force", "High Force",
    "Short Duration", "Medium Duration", "Long Duration",
    ...NUMBERS,
    "Green", "Red", "Black",
  ];

  // Collect which nodes actually appear in the data
  const activeNodes = new Set();
  for (const link of links) {
    activeNodes.add(link.source);
    activeNodes.add(link.target);
  }

  const nodes = NODE_ORDER
    .filter((name) => activeNodes.has(name))
    .map((name) => ({
      name,
      depth: DEPTH_MAP[name],
      itemStyle: { color: COLOR_MAP[name] || "#888" },
    }));

  // Store for highlight logic
  currentNodes = nodes;
  currentLinks = links;

  c.setOption({
    tooltip: { trigger: "item", triggerOn: "mousemove" },
    series: [
      {
        type: "sankey",
        orient: "vertical",
        top: 20,
        bottom: 20,
        left: 40,
        right: 40,
        nodeWidth: 16,
        nodeGap: 4,
        layoutIterations: 0,
        emphasis: { disabled: true },
        lineStyle: { color: "gradient", curveness: 0.5, opacity: 0.4 },
        data: nodes,
        links,
        label: { position: "top", fontSize: 11 },
        levels: [
          { depth: 0, label: { position: "top" } },
          { depth: 1, label: { position: "top" } },
          { depth: 2, label: { position: "top", fontSize: 9, rotate: -45 } },
          { depth: 3, label: { position: "bottom" } },
        ],
      },
    ],
  });

  // Re-apply active selection after chart data rebuild
  if (activeSelection.length > 0) {
    applyHighlight(c, computeActiveNodes(activeSelection));
  }

  setupChartEvents(c);
}

export function highlightNodes(jsonArray) {
  const nodeNames = JSON.parse(jsonArray);
  activeSelection = nodeNames;

  const c = getChart();
  if (!c || currentNodes.length === 0) return;

  if (nodeNames.length === 0) {
    externalHighlight = false;
    resetHighlight(c);
    return;
  }

  externalHighlight = true;
  applyHighlight(c, computeActiveNodes(nodeNames));
}

export function clearHighlight() {
  activeSelection = [];
  externalHighlight = false;

  const c = getChart();
  if (!c || currentNodes.length === 0) return;
  resetHighlight(c);
}
