// DisplayControl loader and DisplayManager mirror follow scrcpy 5.0.1
// (Genymobile, Apache-2.0). See NOTICE/LICENSE. No video encoder is used.
package io.simwisp;

import android.graphics.Bitmap;
import android.graphics.PixelFormat;
import android.hardware.display.VirtualDisplay;
import android.media.Image;
import android.media.ImageReader;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.Process;
import android.system.Os;
import android.view.Surface;
import java.io.*;
import java.lang.reflect.*;
import java.nio.ByteBuffer;

/** Private SWJ1 fresh-buffer JPEG70 / SWH1 idle-heartbeat protocol. */
public final class SimwispJpeg {
    private static volatile long progress = System.nanoTime();
    private static final int MAX_JPEG = 8 * 1024 * 1024;
    private static final long HEARTBEAT_NS = 1_000_000_000L, INFO_NS = 250_000_000L;
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
    private static void checkPhysicalDisplay() throws Exception {
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
    }
    // At most three producer buffers, one acquired image, one reusable packed
    // RGBA buffer and Bitmap. acquireLatestImage discards superseded buffers.
    private static final class Mirror implements AutoCloseable {
        final Object signal;
        final int width, height;
        ImageReader reader;
        VirtualDisplay display;
        Bitmap bitmap;
        ByteBuffer rgba;
        boolean available, closed;
        Mirror(Object signal, int width, int height) { this.signal=signal; this.width=width; this.height=height; }
        static Mirror open(Object signal, Handler handler, Method create, int width, int height) throws Exception {
            Mirror m = new Mirror(signal, width, height);
            try {
                m.reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 3);
                m.bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
                m.rgba = ByteBuffer.allocateDirect(width * height * 4);
                m.reader.setOnImageAvailableListener(reader -> {
                    synchronized (signal) { if (!m.closed) { m.available=true; signal.notifyAll(); } }
                }, handler);
                // AUTO_MIRROR only: no SECURE/PROTECTED flags, own-content
                // display, Activity, power request or change to input routing.
                m.display = (VirtualDisplay) create.invoke(null, "simwisp-jpeg-"+Process.myPid(), width, height, 0, m.reader.getSurface());
                if (m.display == null) throw new IllegalStateException("Android display mirror unavailable");
                return m;
            } catch (Throwable t) { m.close(); throw t; }
        }
        boolean takeAvailable() { synchronized (signal) { boolean value=available; available=false; return value; } }
        @Override public void close() {
            synchronized (signal) { closed=true; available=false; }
            try { if (display != null) display.release(); }
            finally {
                display=null;
                try { if (reader != null) { reader.setOnImageAvailableListener(null, null); reader.close(); } }
                finally { reader=null; if (bitmap != null) bitmap.recycle(); bitmap=null; rgba=null; }
            }
        }
    }
    public static void main(String[] args) throws Exception {
        // Native/GPU libraries may write stdout; only the duplicated FD carries
        // framed packets. Neither pixels nor native logs are retained on disk.
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
        Mirror mirror = null;
        HandlerThread events = null;
        try {
            if (args.length != 3 || Build.VERSION.SDK_INT < 34) throw new IllegalArgumentException("Emulator JPEG requires Android 14 / API34 or newer");
            int edge = Integer.parseInt(args[0]), fps = Integer.parseInt(args[1]);
            if (edge < 8 || edge > 4096 || fps < 1 || fps > 60 || !args[2].matches("/data/local/tmp/simwisp-jpeg-[a-f0-9]{32}/pid")) throw new IllegalArgumentException("Invalid JPEG session arguments");
            try (FileWriter pid = new FileWriter(args[2])) { pid.write(Integer.toString(Process.myPid())); }
            Looper.prepareMainLooper();
            checkPhysicalDisplay();
            Class<?> dmClass = Class.forName("android.hardware.display.DisplayManagerGlobal");
            Object dm = dmClass.getMethod("getInstance").invoke(null);
            Method displayInfo = dmClass.getMethod("getDisplayInfo", int.class);
            Class<?> infoClass = Class.forName("android.view.DisplayInfo");
            Field logicalWidth = infoClass.getField("logicalWidth"), logicalHeight = infoClass.getField("logicalHeight");
            Field rotation = infoClass.getField("rotation"), state = infoClass.getField("state");
            Method createMirror = Class.forName("android.hardware.display.DisplayManager").getMethod(
                    "createVirtualDisplay", String.class, int.class, int.class, int.class, Surface.class);
            events = new HandlerThread("simwisp-jpeg-images"); events.start();
            Handler handler = new Handler(events.getLooper());
            Object signal = new Object();
            int previousWidth=0, previousHeight=0, previousRotation=-1;
            BoundedBytes jpeg = new BoundedBytes();
            long sequence=0, period=1_000_000_000L/fps, nextFrame=0, nextInfo=0, firstDeadline=0;
            for (;;) {
                long now = System.nanoTime();
                if (now >= nextInfo) {
                    Object info = displayInfo.invoke(dm, 0);
                    if (info == null || (state.getInt(info) != 2 && state.getInt(info) != 5)) throw new IllegalStateException("Android display is inactive");
                    int dw=logicalWidth.getInt(info), dh=logicalHeight.getInt(info), r=rotation.getInt(info);
                    int[] size=JpegPixels.scaledSize(dw, dh, edge);
                    if (r < 0 || r > 3) throw new IllegalStateException("Invalid Android display rotation");
                    if (mirror == null || dw != previousWidth || dh != previousHeight || r != previousRotation) {
                        if (mirror != null) { mirror.close(); mirror=null; }
                        mirror=Mirror.open(signal, handler, createMirror, size[0], size[1]);
                        previousWidth=dw; previousHeight=dh; previousRotation=r;
                        firstDeadline=now+5_000_000_000L; nextFrame=0;
                    }
                    if (!mirror.display.getDisplay().isValid()) throw new IllegalStateException("Android display mirror disconnected");
                    nextInfo=now+INFO_NS;
                }
                boolean produced=false;
                if (now >= nextFrame && mirror.takeAvailable()) {
                    long captured=System.nanoTime();
                    try (Image image=mirror.reader.acquireLatestImage()) {
                        if (image != null) {
                            int width=mirror.width, height=mirror.height;
                            android.graphics.Rect crop=image.getCropRect();
                            if (image.getWidth()!=width || image.getHeight()!=height || image.getFormat()!=PixelFormat.RGBA_8888
                                    || crop.left!=0 || crop.top!=0 || crop.width()!=width || crop.height()!=height || image.getPlanes().length!=1)
                                throw new IllegalStateException("Unexpected Android mirror pixel layout");
                            Image.Plane plane=image.getPlanes()[0];
                            JpegPixels.packRGBA(plane.getBuffer(), plane.getPixelStride(), plane.getRowStride(), width, height, mirror.rgba);
                            mirror.bitmap.copyPixelsFromBuffer(mirror.rgba);
                            // Release the producer buffer before compression or blocked ADB.
                        } else { continue; }
                    }
                    jpeg.reset();
                    if (!mirror.bitmap.compress(Bitmap.CompressFormat.JPEG, 70, jpeg)) throw new IllegalStateException("Android JPEG encoding failed");
                    out.writeInt(0x53574a31); out.writeInt(jpeg.size()); out.writeLong(++sequence);
                    out.writeLong(captured); out.writeInt(mirror.width); out.writeInt(mirror.height);
                    jpeg.writeTo(out); out.flush(); progress=System.nanoTime();
                    nextFrame=JpegPixels.nextDeadline(captured, period); firstDeadline=0; produced=true;
                }
                now=System.nanoTime();
                if (firstDeadline != 0 && now >= firstDeadline) throw new IllegalStateException("Android mirror produced no initial frame");
                if (!produced && now-progress >= HEARTBEAT_NS) {
                    out.writeInt(0x53574831); out.writeInt(8); out.writeLong(now); out.flush(); progress=System.nanoTime();
                }
                synchronized (signal) {
                    long wake=Math.min(nextInfo, progress+HEARTBEAT_NS);
                    if (mirror.available) wake=Math.min(wake, nextFrame);
                    long wait=wake-System.nanoTime();
                    if (wait>0) signal.wait(wait/1_000_000L, (int)(wait%1_000_000L));
                }
            }
        } catch (Throwable t) {
            while (t instanceof InvocationTargetException && t.getCause() != null) t=t.getCause();
            try {
                byte[] error=("Emulator JPEG mirror: "+t.getClass().getSimpleName()+": "+String.valueOf(t.getMessage())).getBytes("UTF-8");
                out.writeInt(0x53574531); out.writeInt(Math.min(error.length, 2048));
                out.write(error, 0, Math.min(error.length, 2048)); out.flush();
            } catch (Throwable ignored) { }
            code=2;
        } finally {
            try { if (mirror != null) mirror.close(); } catch (Throwable ignored) { }
            if (events != null) { events.quitSafely(); try { events.join(1000); } catch (InterruptedException ignored) { } }
            try { out.close(); } catch (Throwable ignored) { }
        }
        System.exit(code);
    }
}

// Pure, separately JVM-tested layout/pacing policy. Android RGBA_8888 bytes have
// Bitmap ARGB_8888's native memory layout; never reinterpret them as Java ARGB ints.
final class JpegPixels {
    static int[] scaledSize(int width, int height, int edge) {
        if (width<8 || height<8 || width>16384 || height>16384 || edge<8 || edge>4096)
            throw new IllegalArgumentException("Invalid Android display dimensions");
        double scale=Math.min(1.0, (double)edge/Math.max(width, height));
        return new int[]{Math.max(8,(int)Math.round(width*scale)),Math.max(8,(int)Math.round(height*scale))};
    }
    static long nextDeadline(long captured, long period) { return Math.addExact(captured, period); }
    static void packRGBA(ByteBuffer source, int pixelStride, int rowStride, int width, int height, ByteBuffer packed) {
        if (width<8 || height<8 || width>4096 || height>4096 || pixelStride!=4 || rowStride<(long)width*4
                || rowStride%4!=0 || (long)(height-1)*rowStride+(long)width*4>source.remaining()
                || packed.capacity()!=(long)width*height*4) throw new IllegalArgumentException("Invalid Android mirror RGBA stride/bounds");
        ByteBuffer rows=source.duplicate(); int start=rows.position(), end=rows.limit(), bytes=width*4;
        packed.clear();
        if (rowStride==bytes) { rows.limit(start+bytes*height); packed.put(rows); }
        else for (int y=0; y<height; y++) { rows.limit(end); rows.position(start+y*rowStride); rows.limit(rows.position()+bytes); packed.put(rows); }
        packed.flip();
    }
}
