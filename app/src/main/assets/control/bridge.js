(function () {
  'use strict';
  let sequence = 0;
  const LONG_JOB_MS = 15 * 60 * 1000;
  window.xjApi = function (action, payload) {
    return new Promise(function (resolve, reject) {
      const callback = '__xjReply_' + Date.now() + '_' + (++sequence);
      let settled = false;
      const timer = setTimeout(function () { finish(new Error('请求超时：' + action)); }, 30000);
      function finish(error, raw) {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        delete window[callback];
        if (error) reject(error);
        else resolve(raw == null ? '' : String(raw));
      }
      window[callback] = function (result) {
        try {
          const reply = typeof result === 'string' ? JSON.parse(result) : result;
          if (!reply || reply.ok !== true) {
            finish(new Error(reply && (reply.error || reply.raw) || '请求失败：' + action));
            return;
          }
          finish(null, reply.raw);
        } catch (error) { finish(error); }
      };
      try {
        if (!window.NativeShell || typeof window.NativeShell.request !== 'function') {
          finish(new Error('安全桥未连接'));
          return;
        }
        window.NativeShell.request(action, JSON.stringify(payload || {}), callback);
      } catch (error) { finish(error); }
    });
  };
  window.xjJob = async function (action, payload, onProgress) {
    let job = JSON.parse(await window.xjApi(action, payload));
    const started = Date.now();
    for (;;) {
      if (onProgress) onProgress(job);
      const status = job.status;
      if (status === 'succeeded') {
        if (Number(job.exitCode) !== 0) throw new Error(job.output || '任务执行失败');
        return job.output == null ? '' : String(job.output);
      }
      if (status === 'failed') {
        throw new Error(job.output || '任务执行失败');
      }
      if (!job.jobId) throw new Error('任务未返回 jobId');
      if (Date.now() - started >= LONG_JOB_MS) throw new Error('任务等待超时，请稍后查看日志');
      await new Promise(function (resolve) { setTimeout(resolve, 1000); });
      job = JSON.parse(await window.xjApi('job.get', { jobId: job.jobId }));
    }
  };
})();
