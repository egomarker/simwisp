package io.simwisp;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.Random;
// Runs on the host JVM: no Android runtime, device, capture or installed app.
public final class Surface {
    static int checks;
    static void check(boolean value,String label){if(!value)throw new AssertionError(label);checks++;}
    static void reject(Runnable call){try{call.run();throw new AssertionError("accepted unsafe layout");}catch(IllegalArgumentException expected){checks++;}}
    public static void main(String[] args){
        check(Arrays.equals(JpegPixels.scaledSize(1080,2400,914),new int[]{411,914}),"portrait content dimensions");
        check(Arrays.equals(JpegPixels.scaledSize(2400,1080,914),new int[]{914,411}),"rotation swaps content dimensions");
        check(Arrays.equals(JpegPixels.scaledSize(8,16384,4096),new int[]{8,4096}),"minimum dimensions");
        check(Arrays.equals(JpegPixels.scaledSize(100,200,4096),new int[]{100,200}),"never upscale");
        for(int[] invalid:new int[][]{{0,100,914},{100,7,914},{16385,100,914},{100,100,7},{100,100,4097}})reject(()->JpegPixels.scaledSize(invalid[0],invalid[1],invalid[2]));
        for(int divisor:new int[]{1,2,4}) {
            check(Arrays.equals(JpegPixels.scaledSize(1080,2400,2400/divisor),new int[]{1080/divisor,2400/divisor}),"phone scale before JPEG compression");
            check(Arrays.equals(JpegPixels.scaledSize(2400,1080,2400/divisor),new int[]{2400/divisor,1080/divisor}),"phone rotation preserves scale");
        }
        Random random=new Random(17030);
        for(int i=0;i<500;i++){
            int w=8+random.nextInt(128),h=8+random.nextInt(128),pad=random.nextInt(16)*4,stride=w*4+pad,offset=random.nextInt(16);
            int length=(h-1)*stride+w*4;
            ByteBuffer src=i%2==0?ByteBuffer.allocateDirect(offset+length):ByteBuffer.allocate(offset+length);
            byte[] expected=new byte[w*h*4];random.nextBytes(expected);
            for(int y=0;y<h;y++)for(int x=0;x<w*4;x++)src.put(offset+y*stride+x,expected[y*w*4+x]);
            src.position(offset);ByteBuffer target=ByteBuffer.allocateDirect(w*h*4);
            JpegPixels.packRGBA(src,4,stride,w,h,target);byte[] actual=new byte[target.remaining()];target.get(actual);
            check(Arrays.equals(actual,expected),"RGBA channel bytes, odd dimensions, final-row padding and stride");
            check(src.position()==offset && src.limit()==offset+length,"source bounds never modified");
            src.position(offset);target.clear();JpegPixels.packRGBA(src,4,stride,w,h,target);check(target.remaining()==w*h*4,"same buffers reusable");
        }
        ByteBuffer s=ByteBuffer.allocate(8*8*4),d=ByteBuffer.allocate(8*8*4);
        for(int pixel:new int[]{0,1,3,8})reject(()->JpegPixels.packRGBA(s,pixel,32,8,8,d));
        for(int row:new int[]{0,-4,28,33,Integer.MAX_VALUE-3})reject(()->JpegPixels.packRGBA(s,4,row,8,8,d));
        reject(()->JpegPixels.packRGBA(s,4,32,7,8,d));reject(()->JpegPixels.packRGBA(s,4,32,8,4097,d));
        reject(()->JpegPixels.packRGBA(s,4,32,8,8,ByteBuffer.allocate(255)));
        s.limit(255);reject(()->JpegPixels.packRGBA(s,4,32,8,8,d));
        long period=1_000_000_000L/60;
        for(int i=0;i<100;i++){long begin=10_000_000_000L+i*period*7;check(JpegPixels.nextDeadline(begin,period)==begin+period,"late completion skips missed source slots, never catch-up bursts");}
        System.out.println("Persistent JPEG surface JVM checks: "+checks+" passed");
    }
}
