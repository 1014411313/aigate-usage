package site.chudian.githubhosts;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;

/** 以 root 身份执行 shell 命令。KernelSU / SterSU 的 su 在 /system/bin/su */
public final class RootShell {

    public static final class Result {
        public final int code;
        public final String out;

        Result(int code, String out) {
            this.code = code;
            this.out = out;
        }

        public boolean ok() {
            return code == 0;
        }
    }

    private RootShell() {
    }

    /** 依次尝试常见 su 路径，返回第一个能执行的结果 */
    public static Result su(String script) {
        Result last = new Result(-1, "su 不可用");
        String[] candidates = {"/system/bin/su", "su", "/data/adb/ksu/bin/su"};
        for (String su : candidates) {
            Result r = exec(su, "-c", script);
            if (r.code != -2) {
                return r;
            }
            last = r;
        }
        return last;
    }

    /** code = -2 表示该可执行文件不存在 */
    private static Result exec(String... cmd) {
        Process p = null;
        try {
            p = new ProcessBuilder(cmd).redirectErrorStream(true).start();
            p.getOutputStream().close();
            String out = readAll(p.getInputStream());
            int code = p.waitFor();
            return new Result(code, out.trim());
        } catch (Exception e) {
            return new Result(-2, "无法执行 " + cmd[0] + "：" + e.getMessage());
        } finally {
            if (p != null) {
                p.destroy();
            }
        }
    }

    public static boolean isRootAvailable() {
        Result r = su("id");
        return r.ok() && r.out.contains("uid=0");
    }

    static String readAll(InputStream in) throws Exception {
        StringBuilder sb = new StringBuilder();
        BufferedReader r = new BufferedReader(new InputStreamReader(in, "UTF-8"));
        String line;
        while ((line = r.readLine()) != null) {
            sb.append(line).append('\n');
        }
        r.close();
        return sb.toString();
    }
}
