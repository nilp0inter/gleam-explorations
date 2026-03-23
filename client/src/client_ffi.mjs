let chart = null;

function getChart() {
  if (chart) return chart;
  const el = document.getElementById("sankey-chart");
  if (!el) return null;
  chart = echarts.init(el);
  window.addEventListener("resize", () => chart && chart.resize());
  return chart;
}

function classifyForce(f) {
  if (f < 3) return "Low Force";
  if (f <= 7) return "Medium Force";
  return "High Force";
}

function classifyDuration(d) {
  if (d < 3) return "Short Duration";
  if (d <= 7) return "Medium Duration";
  return "Long Duration";
}

function classifyNumber(n) {
  if (n === 0) return "Zero (0)";
  if (n <= 12) return "1-12";
  if (n <= 24) return "13-24";
  return "25-36";
}

function classifyColor(c) {
  return c.charAt(0).toUpperCase() + c.slice(1);
}

export function updateChart(jsonString) {
  const c = getChart();
  if (!c) return;

  const runs = JSON.parse(jsonString);
  if (runs.length === 0) {
    c.setOption({ series: [] });
    return;
  }

  // Count links between levels
  const forceDuration = {};
  const durationNumber = {};
  const numberColor = {};

  for (const run of runs) {
    const f = classifyForce(run.force);
    const d = classifyDuration(run.duration);
    const n = classifyNumber(run.winning_number);
    const col = classifyColor(run.color);

    const fd = `${f}||${d}`;
    forceDuration[fd] = (forceDuration[fd] || 0) + 1;

    const dn = `${d}||${n}`;
    durationNumber[dn] = (durationNumber[dn] || 0) + 1;

    const nc = `${n}||${col}`;
    numberColor[nc] = (numberColor[nc] || 0) + 1;
  }

  const nodeSet = new Set();
  const links = [];

  function addLinks(map) {
    for (const [key, value] of Object.entries(map)) {
      const [source, target] = key.split("||");
      nodeSet.add(source);
      nodeSet.add(target);
      links.push({ source, target, value });
    }
  }

  addLinks(forceDuration);
  addLinks(durationNumber);
  addLinks(numberColor);

  const colorMap = {
    "Low Force": "#60a5fa",
    "Medium Force": "#f59e0b",
    "High Force": "#ef4444",
    "Short Duration": "#34d399",
    "Medium Duration": "#a78bfa",
    "Long Duration": "#f87171",
    "Zero (0)": "#10b981",
    "1-12": "#6366f1",
    "13-24": "#ec4899",
    "25-36": "#f97316",
    "Red": "#dc2626",
    "Black": "#1f2937",
    "Green": "#16a34a",
  };

  const nodes = Array.from(nodeSet).map((name) => ({
    name,
    itemStyle: { color: colorMap[name] || "#888" },
  }));

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
        nodeWidth: 20,
        nodeGap: 12,
        layoutIterations: 32,
        emphasis: { focus: "adjacency" },
        lineStyle: { color: "gradient", curveness: 0.5 },
        data: nodes,
        links,
        label: { position: "top", fontSize: 11 },
        levels: [
          { depth: 0, label: { position: "top" } },
          { depth: 1, label: { position: "top" } },
          { depth: 2, label: { position: "top" } },
          { depth: 3, label: { position: "bottom" } },
        ],
      },
    ],
  });
}
