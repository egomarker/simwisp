// DisplayControl loader follows scrcpy 5.0.1 (Genymobile, Apache-2.0).
// See NOTICE and LICENSE in this directory. No scrcpy video encoder is used.
package io.simwisp;

import android.graphics.Bitmap;
import android.hardware.HardwareBuffer;
import android.os.Build;
import android.os.IBinder;
import android.os.Looper;
import android.os.Process;
import android.system.Os;
import java.io.*;
import java.lang.reflect.*;
import java.util.concurrent.locks.LockSupport;

/** Private SWJ1 protocol. One fresh display capture + fixed-Q70 JPEG per frame. */
public final class SimwispJpeg {
    private static volatile long progress = System.nanoTime();
    private static final int MAX_JPEG = 8 * 1024 * 1024;
    private static final class BoundedBytes extends ByteArrayOutputStream {
        BoundedBytes() { super(262144); }
        @Override public synchronized void write(int b) {
            if (count >= MAX_JPEG) throw new IllegalStateException("JPEG exceeds limit");
            super.write(b);
        }
        @Override public synchronized void write(byte[] b, int off, int len) {
            if (len < 0 || count > MAX_JPEG - len) throw new IllegalStateException("JPEG exceeds limit");
            super.write(b, off, len);
        }
    }
    private static IBinder displayToken() throws Exception {
        Class<?> factory = Class.forName("com.android.internal.os.ClassLoaderFactory");
        Method create = factory.getDeclaredMethod("createClassLoader", String.class, String.class,
                String.class, ClassLoader.class, int.class, boolean.class, String.class);
        ClassLoader loader = (ClassLoader) create.invoke(null, Os.getenv("SYSTEMSERVERCLASSPATH"),
                null, null, ClassLoader.getSystemClassLoader(), 0, true, null);
        Class<?> dc = loader.loadClass("com.android.server.display.DisplayControl");
        Method load = Runtime.class.getDeclaredMethod("loadLibrary0", Class.class, String.class);
        load.setAccessible(true); load.invoke(Runtime.getRuntime(), dc, "android_servers");
        long[] ids = (long[]) dc.getMethod("getPhysicalDisplayIds").invoke(null);
        if (ids == null || ids.length != 1) throw new IllegalStateException("JPEG requires one physical emulator display");
        return (IBinder) dc.getMethod("getPhysicalDisplayToken", long.class).invoke(null, ids[0]);
    }
    public static void main(String[] args) throws Exception {
        // Keep a clean binary transport even if Android GPU/native code writes stdout.
        FileDescriptor transport = Os.dup(FileDescriptor.out);
        FileDescriptor sink = Os.open("/dev/null", android.system.OsConstants.O_WRONLY, 0);
        Os.dup2(sink, 1); Os.dup2(sink, 2); Os.close(sink);
        DataOutputStream out = new DataOutputStream(new BufferedOutputStream(new FileOutputStream(transport), 262144));
        Thread watchdog = new Thread(() -> {
            for (;;) {
                try { Thread.sleep(1000); } catch (InterruptedException e) { return; }
                if (System.nanoTime() - progress > 10_000_000_000L) System.exit(124);
            }
        }, "simwisp-jpeg-watchdog");
        watchdog.setDaemon(true); watchdog.start();
        int code = 0;
        try {
            if (args.length != 3 || Build.VERSION.SDK_INT < 34) throw new IllegalArgumentException("Emulator JPEG requires Android 14 / API34 or newer");
            int edge = Integer.parseInt(args[0]), fps = Integer.parseInt(args[1]);
            if (edge < 8 || edge > 4096 || fps < 1 || fps > 60 || !args[2].matches("/data/local/tmp/simwisp-jpeg-[a-f0-9]{32}/pid")) throw new IllegalArgumentException("Invalid JPEG session arguments");
            try (FileWriter pid = new FileWriter(args[2])) { pid.write(Integer.toString(Process.myPid())); }
            Looper.prepareMainLooper();
            IBinder token = displayToken();
            Class<?> dmClass = Class.forName("android.hardware.display.DisplayManagerGlobal");
            Object dm = dmClass.getMethod("getInstance").invoke(null);
            Method displayInfo = dmClass.getMethod("getDisplayInfo", int.class);
            Class<?> infoClass = Class.forName("android.view.DisplayInfo");
            Field logicalWidth = infoClass.getField("logicalWidth"), logicalHeight = infoClass.getField("logicalHeight");
            Class<?> builderClass = Class.forName("android.window.ScreenCapture$DisplayCaptureArgs$Builder");
            Class<?> argsClass = Class.forName("android.window.ScreenCapture$DisplayCaptureArgs");
            Class<?> screenClass = Class.forName("android.window.ScreenCapture");
            Class<?> shotClass = Class.forName("android.window.ScreenCapture$ScreenshotHardwareBuffer");
            Method capture = screenClass.getMethod("captureDisplay", argsClass);
            Method asBitmap = shotClass.getMethod("asBitmap"), hardware = shotClass.getMethod("getHardwareBuffer");
            Object captureArgs = null;
            int previousWidth = 0, previousHeight = 0;
            BoundedBytes jpeg = new BoundedBytes();
            long sequence = 0, period = 1_000_000_000L / fps, next = System.nanoTime();
            for (;;) {
                long wait = next - System.nanoTime();
                if (wait > 0) LockSupport.parkNanos(wait);
                long begin = System.nanoTime();
                // Skip missed source deadlines, never generate a catch-up burst.
                next = Math.max(next + period, begin + period);
                Object info = displayInfo.invoke(dm, 0);
                if (info == null) throw new IllegalStateException("Android display is inactive");
                int dw = logicalWidth.getInt(info), dh = logicalHeight.getInt(info);
                if (dw < 8 || dh < 8 || dw > 16384 || dh > 16384) throw new IllegalStateException("Invalid Android display dimensions");
                double scale = Math.min(1.0, (double) edge / Math.max(dw, dh));
                int width = Math.max(8, (int) Math.round(dw * scale)), height = Math.max(8, (int) Math.round(dh * scale));
                if (width != previousWidth || height != previousHeight) {
                    Object builder = builderClass.getConstructor(IBinder.class).newInstance(token);
                    builderClass.getMethod("setSize", int.class, int.class).invoke(builder, width, height);
                    builderClass.getMethod("setPixelFormat", int.class).invoke(builder, 1);
                    builderClass.getMethod("setCaptureSecureLayers", boolean.class).invoke(builder, false);
                    builderClass.getMethod("setAllowProtected", boolean.class).invoke(builder, false);
                    captureArgs = builderClass.getMethod("build").invoke(builder);
                    previousWidth = width; previousHeight = height;
                }
                Object shot = capture.invoke(null, captureArgs);
                if (shot == null) throw new IllegalStateException("Android display capture failed");
                Bitmap raw = null, soft = null; HardwareBuffer hb = null;
                try {
                    hb = (HardwareBuffer) hardware.invoke(shot); raw = (Bitmap) asBitmap.invoke(shot);
                    if (raw == null) throw new IllegalStateException("Android display bitmap unavailable");
                    soft = raw.copy(Bitmap.Config.ARGB_8888, false);
                    if (soft == null || soft.getWidth() != width || soft.getHeight() != height) throw new IllegalStateException("Android display readback dimensions changed");
                    jpeg.reset();
                    if (!soft.compress(Bitmap.CompressFormat.JPEG, 70, jpeg)) throw new IllegalStateException("Android JPEG encoding failed");
                    out.writeInt(0x53574a31); out.writeInt(jpeg.size()); out.writeLong(++sequence);
                    out.writeLong(begin); out.writeInt(width); out.writeInt(height);
                    jpeg.writeTo(out); out.flush(); progress = System.nanoTime();
                } finally {
                    if (soft != null) soft.recycle(); if (raw != null) raw.recycle(); if (hb != null) hb.close();
                }
            }
        } catch (Throwable t) {
            while (t instanceof InvocationTargetException && t.getCause() != null) t = t.getCause();
            // Fixed error framing; no device pixels or unbounded logs are retained.
            try {
                byte[] error = ("Emulator JPEG: " + t.getClass().getSimpleName() + ": " + String.valueOf(t.getMessage())).getBytes("UTF-8");
                out.writeInt(0x53574531); out.writeInt(Math.min(error.length, 2048));
                out.write(error, 0, Math.min(error.length, 2048)); out.flush();
            } catch (Throwable ignored) { }
            code = 2;
        } finally { try { out.close(); } catch (Throwable ignored) { } }
        System.exit(code);
    }
}
