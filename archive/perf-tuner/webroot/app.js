import { exec, isAvailable, toast } from "./ksu.js";

const MODULE_ID = "perf_tuner";

const PROFILES = [
  { id: "powersave", name: "省电", desc: "限制 CPU 调度倾向、降低预读，换取更长的续航" },
  { id: "balanced", name: "均衡", desc: "接近系统默认的日常使用配置" },
  { id: "performance", name: "性能", desc: "优先调度与吞吐，增大预读，适合游戏" },
];

const elements = {
  current: document.getElementById("current"),
  notice: document.getElementById("notice"),
  profiles: document.getElementById("profiles"),
  log: document.getElementById("log"),
  refresh: document.getElementById("refresh"),
  reset: document.getElementById("reset"),
};

let moduleDir = `/data/adb/modules/${MODULE_ID}`;

function setLog(text) {
  elements.log.textContent = text.trim() || "—";
}

function setCurrent(profile) {
  const match = PROFILES.find((item) => item.id === profile);
  elements.current.textContent = match ? match.name : profile === "default" ? "设备默认" : profile;
  for (const card of elements.profiles.children) {
    card.classList.toggle("active", card.dataset.profile === profile);
  }
}

function renderProfiles() {
  for (const profile of PROFILES) {
    const card = document.createElement("article");
    card.className = "card";
    card.dataset.profile = profile.id;

    const title = document.createElement("h2");
    title.textContent = profile.name;

    const desc = document.createElement("p");
    desc.textContent = profile.desc;

    const button = document.createElement("button");
    button.textContent = "应用";
    button.addEventListener("click", () => run(`apply ${profile.id}`, `${profile.name}方案已应用`));

    card.append(title, desc, button);
    elements.profiles.append(card);
  }
}

async function findModuleDir() {
  const { stdout } = await exec(
    `ls -d /data/adb/modules/${MODULE_ID} /data/adb/modules_update/${MODULE_ID} 2>/dev/null | head -n 1`,
  );
  const found = stdout.trim();
  if (found) moduleDir = found;
}

async function run(command, successMessage) {
  try {
    const { errno, stdout, stderr } = await exec(`sh ${moduleDir}/bin/perf.sh ${command}`);
    setLog([stdout, stderr].filter(Boolean).join("\n"));
    if (errno === 0) {
      if (successMessage) toast(successMessage);
      await refresh();
    } else {
      toast(`执行失败（errno ${errno}）`);
    }
  } catch (error) {
    setLog(String(error.message ?? error));
    toast("执行失败");
  }
}

async function refresh() {
  const { stdout } = await exec(`sh ${moduleDir}/bin/perf.sh status`);
  setLog(stdout);
  const match = stdout.match(/当前方案：(\S+)/);
  setCurrent(match ? match[1] : "unknown");
}

async function main() {
  renderProfiles();

  if (!isAvailable()) {
    elements.notice.hidden = false;
    elements.notice.textContent = "未检测到 KernelSU WebUI 环境，此页面仅作预览，按钮不可用。";
    setCurrent("unknown");
    setLog("请在 KernelSU 管理器的模块页面中打开本 WebUI。");
    return;
  }

  await findModuleDir();
  await refresh();
}

elements.refresh.addEventListener("click", refresh);
elements.reset.addEventListener("click", () => run("reset", "已恢复默认"));

main();
