export function isAvailable() {
  return typeof window.ksu !== "undefined";
}

export function exec(command, options = {}) {
  return new Promise((resolve, reject) => {
    if (!isAvailable()) {
      reject(new Error("当前环境未提供 ksu.exec（请从 KernelSU 管理器的模块页面打开）"));
      return;
    }
    const callback = `exec_callback_${Date.now()}_${Math.random().toString(36).slice(2)}`;
    window[callback] = (errno, stdout, stderr) => {
      delete window[callback];
      resolve({ errno, stdout, stderr });
    };
    try {
      window.ksu.exec(command, JSON.stringify(options), callback);
    } catch (error) {
      delete window[callback];
      reject(error);
    }
  });
}

export function toast(message) {
  if (isAvailable()) {
    window.ksu.toast(message);
  }
}
