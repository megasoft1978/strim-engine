import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Comparator;

/** Trusted reflective test runner (grader-owned). args: nonceFd resultFd fullyQualifiedTestClass... */
public final class StrimRun {
    private StrimRun() {}

    private static String quote(String s) {
        StringBuilder b = new StringBuilder("\"");
        for (char c : s.toCharArray()) {
            if (c == '"' || c == '\\') b.append('\\').append(c);
            else if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
            else b.append(c);
        }
        return b.append('"').toString();
    }

    public static void main(String[] args) throws Exception {
        String nonce;
        try (InputStream in = new FileInputStream("/dev/fd/" + args[0])) {
            // Plain read loop: readAllBytes() seeks first, which fails on a Linux pipe (ESPIPE).
            java.io.ByteArrayOutputStream buffer = new java.io.ByteArrayOutputStream();
            byte[] chunk = new byte[256];
            for (int n; (n = in.read(chunk)) > 0; ) buffer.write(chunk, 0, n);
            nonce = new String(buffer.toByteArray(), StandardCharsets.US_ASCII).trim();
        }
        // Local variables only: no static field holds the nonce or the channel.
        final OutputStream out = new FileOutputStream("/dev/fd/" + args[1]);
        int total = 0;
        boolean ok = args.length > 2;
        for (int i = 2; i < args.length; i++) {
            Class<?> c = Class.forName(args[i]);
            Method[] methods = c.getDeclaredMethods();
            Arrays.sort(methods, Comparator.comparing(Method::getName));
            for (Method m : methods) {
                if (!m.getName().startsWith("test") || !Modifier.isPublic(m.getModifiers()) || m.getParameterCount() != 0) continue;
                String name = c.getSimpleName() + "." + m.getName();
                boolean pass;
                try {
                    Object o = c.getDeclaredConstructor().newInstance();
                    m.invoke(o);
                    pass = true;
                } catch (ReflectiveOperationException | LinkageError | RuntimeException e) {
                    pass = false;
                }
                total++;
                if (!pass) ok = false;
                out.write((nonce + " {\"k\":\"" + (pass ? "pass" : "fail") + "\",\"n\":" + quote(name) + "}\n").getBytes(StandardCharsets.UTF_8));
                out.flush();
            }
        }
        if (total == 0) ok = false;
        out.write((nonce + " {\"k\":\"end\",\"total\":" + total + ",\"ok\":" + ok + "}\n").getBytes(StandardCharsets.UTF_8));
        out.flush();
        Runtime.getRuntime().halt(ok ? 0 : 1);
    }
}
