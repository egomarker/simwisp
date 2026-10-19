import Foundation
import IOSurface
import CoreImage

// Independent from Android's source scaling and protocol namespace.
enum IOSCaptureScale:String,CaseIterable {
    case full="1",half="0.5",quarter="0.25"
    static func normalized(_ value:String?)->Self {Self(rawValue:value ?? "") ?? .full}
    var factor:Double {self == .full ? 1:self == .half ? 0.5:0.25}
}

// At most three owned buffers, INCLUDING leases retired by geometry changes.
// Data/CI consumers own a lease; the producer cannot mutate leased storage.
// Neither an IOSurface nor its mutable bytes is handed to CI/VideoToolbox.
final class NativeSnapshotReader {
    struct Layout:Equatable {let width:Int,height:Int,stride:Int,format:UInt32;var count:Int {width*height*4}}
    enum Busy {case seed,storage}
    enum Read {case pixels(NativeCapture.Pixels,Layout),busy(Layout,Busy)}
    enum ReferenceRead {case pixels(NativeCapture.Pixels,Layout,changed:Bool),busy(Layout,Busy)}
    private final class Buffer {
        let pointer:UnsafeMutableRawPointer,count:Int
        var leased=false,retired=false,valid=false
        init(_ count:Int){self.count=count;pointer=UnsafeMutableRawPointer.allocate(byteCount:count,alignment:64)}
        deinit {pointer.deallocate()}
    }
    private final class Lease {
        let buffer:Buffer
        private weak var owner:NativeSnapshotReader?
        init(_ buffer:Buffer,_ owner:NativeSnapshotReader){self.buffer=buffer;self.owner=owner}
        deinit {owner?.release(buffer)}
        // Only call AFTER all active bytes have been initialized and unlocked.
        // The closure retains the lease even if Core Image outlives this call.
        func data()->Data {
            Data(bytesNoCopy:buffer.pointer,count:buffer.count,deallocator:.custom{[self] _,_ in withExtendedLifetime(self){}})
        }
    }
    static let limit=3
    private let lock=NSLock(),readLock=NSLock()
    private var buffers:[Buffer]=[],layout:Layout?,reference:Buffer?
    private var allocations=0,reuses=0,peakBytes=0,copiedBytes=0,reusedBytes=0
    var diagnostics:[String:Int] {lock.withLock{[
        "snapshot_buffer_allocations":allocations,"snapshot_buffer_reuses":reuses,
        "snapshot_buffers":buffers.count,"snapshot_leased_buffers":buffers.filter{$0.leased}.count,
        "snapshot_buffer_bytes":buffers.reduce(0){$0+$1.count},"snapshot_buffer_peak_bytes":peakBytes,
        "snapshot_bytes_copied":copiedBytes,"snapshot_unchanged_bytes_reused":reusedBytes
    ]}}
    private func acquire(_ next:Layout,comparing:Bool=false)->Lease? {lock.withLock {
        if !comparing {reference=nil}
        if layout != next {
            reference=nil
            for buffer in buffers {buffer.retired=true}
            buffers.removeAll{!$0.leased};layout=next
        }
        let buffer:Buffer
        if comparing,let current=reference,!current.leased,!current.retired {buffer=current;reuses+=1}
        else if let available=buffers.first(where:{!$0.leased && !$0.retired}) {buffer=available;reuses+=1}
        else {
            guard buffers.count<Self.limit else{return nil}
            buffer=Buffer(next.count);buffers.append(buffer);allocations+=1
            peakBytes=max(peakBytes,buffers.reduce(0){$0+$1.count})
        }
        buffer.leased=true;return Lease(buffer,self)
    }}
    private func release(_ buffer:Buffer) {lock.withLock {
        buffer.leased=false
        if buffer.retired {buffers.removeAll{$0 === buffer}}
        // A reference capture keeps no idle full-size spare after borrows retire.
        if let reference {buffers.removeAll{!$0.leased && $0 !== reference}}
    }}
    func reset() {readLock.withLock {lock.withLock {
        reference=nil;layout=nil;for buffer in buffers {buffer.retired=true};buffers.removeAll{!$0.leased}
    }}}
    func read(_ surface:IOSurface)throws->Read {
        switch try copy(surface,comparing:false) {
        case .pixels(let pixels,let layout,_):return .pixels(pixels,layout)
        case .busy(let layout,let reason):return .busy(layout,reason)
        }
    }
    // Capture owns the packed comparison reference, not a retained Pixels/Data.
    // Each returned Pixels still leases immutable storage until its FINAL user
    // releases it; a completed render alone cannot revoke a retained CI image.
    func readReference(_ surface:IOSurface)throws->ReferenceRead {try copy(surface,comparing:true)}
    private func copy(_ surface:IOSurface,comparing:Bool)throws->ReferenceRead {try readLock.withLock {
        let w=IOSurfaceGetWidth(surface),h=IOSurfaceGetHeight(surface),stride=IOSurfaceGetBytesPerRow(surface),format=IOSurfaceGetPixelFormat(surface)
        guard (1...8192).contains(w),(1...8192).contains(h),IOSurfaceGetPlaneCount(surface)==0,
              IOSurfaceGetBytesPerElement(surface)==4,(format==0x42475241 || format==0x42475258),stride>=w*4,
              stride<=NativeCapture.maxBytes/h,IOSurfaceGetAllocSize(surface)>=stride*h,w*4<=NativeCapture.maxBytes/h else {
            throw WispError("Native framebuffer has unsupported BGRA/BGRX layout or exceeds64MiB")
        }
        let layout=Layout(width:w,height:h,stride:stride,format:format)
        // Acquire/allocate BEFORE locking the producer. No CI/VT/heap allocation
        // while locked. A retained old lease requires another bounded buffer.
        guard let lease=acquire(layout,comparing:comparing) else{return .busy(layout,.storage)}
        let previous:Buffer?=lock.withLock{comparing && reference?.valid==true ? reference:nil}
        let inPlace=previous === lease.buffer
        var changed=previous==nil,bytesCopied=0
        // In-place copying may destroy the baseline on a seed race. Its validity
        // is committed only after unlock/seed checks; prepared output is separate.
        lock.withLock{lease.buffer.valid=false}
        var seed:UInt32=0
        guard IOSurfaceLock(surface,.readOnly,&seed)==0 else {throw WispError("Native framebuffer read lock failed")}
        let base=IOSurfaceGetBaseAddress(surface),target=lease.buffer.pointer
        if !comparing && stride==w*4 {memcpy(target,base,layout.count);bytesCopied=layout.count}
        else {
            for y in 0..<h {
                let row=base+y*stride,to=target+y*w*4
                if !changed,let previous {
                    let old=previous.pointer+y*w*4
                    if format==0x42475241 {changed=memcmp(row,old,w*4) != 0}
                    else {
                        let a=row.assumingMemoryBound(to:UInt8.self),b=old.assumingMemoryBound(to:UInt8.self)
                        var i=0
                        while i<w*4 {
                            // Incoming X is ignored; normalized alpha is255.
                            if a[i] != b[i] || a[i+1] != b[i+1] || a[i+2] != b[i+2] || b[i+3] != 255 {changed=true;break}
                            i+=4
                        }
                    }
                }
                // Matching rows ALREADY exist in an in-place reference. Avoid
                // rewriting them under the producer lock. A distinct lease must
                // still receive every row, even when the image is unchanged.
                if !inPlace || changed {memcpy(to,row,w*4);bytesCopied+=w*4}
            }
        }
        let during=IOSurfaceGetSeed(surface)
        var after:UInt32=0
        let status=IOSurfaceUnlock(surface,.readOnly,&after)
        lock.withLock{copiedBytes+=bytesCopied;reusedBytes+=layout.count-bytesCopied}
        guard status==0 else {throw WispError("Native framebuffer read unlock failed")}
        guard seed==during,seed==after else{return .busy(layout,.seed)}
        // Normalization touches only owned bytes, outside the producer lock.
        if format==0x42475258 && bytesCopied>0 {
            let bytes=target.assumingMemoryBound(to:UInt8.self)
            for i in Swift.stride(from:3,to:layout.count,by:4) {bytes[i]=255}
        }
        if comparing {lock.withLock{lease.buffer.valid=true;reference=lease.buffer}}
        return .pixels(NativeCapture.Pixels(width:w,height:h,bytes:lease.data()),layout,changed:changed)
    }}

}

// Pull-only: one admitted poll/copy/prepare/encode, no producer queue/callbacks.
// The mutable producer IOSurface NEVER reaches CI/VT: copy active row bytes
// while read-locked, then render only owned immutable bytes. Seeds are a race
// check, NOT a freshness oracle (some GPU producers don't advance them).
final class NativeCapture: @unchecked Sendable {
    typealias Factory=(String)->NativeCapture
    struct Pixels: Equatable { let width:Int, height:Int, bytes:Data }
    struct Video { let frame:H264Frame, generation:UInt64;let sourceWidth:Int,sourceHeight:Int }
    static let maxBytes=64*1024*1024
    private let lock=NSLock(),encodeLock=NSLock()
    private let connect:()throws->any NativeSurfaceSource
    private let health:CaptureHealth
    private let clock:()->Double
    private let snapshots=NativeSnapshotReader()
    private var lastLayout:NativeSnapshotReader.Layout?,lastScale:IOSCaptureScale?
    private var cancelled=false,ended=false
    private var source:(any NativeSurfaceSource)?, cached:H264Encoder.PreparedFrame?, encoder:H264Encoder?
    private var generation:UInt64=0, recovery=true, lastPresent:Double
    private var stats:[String:Any]=["source_mode":"ios_simulator_native","source_format":"BGRA8","polls":0,"source_frames":0,"h264_encodes":0,"cached_image_encodes":0,"prepared_pixel_buffers":0,"encoder_creations":0,"dropped_snapshots":0,"busy_snapshots":0,"busy_seed_snapshots":0,"busy_storage_snapshots":0,"inactive_surfaces":0,"busy_without_cached_image":0,"busy_geometry_changes":0,"busy_cached_image_encodes":0,"jpeg_encodes":0,"jpeg_decodes":0,"queued_frames":0,"hardware_encoder":false,"cached_image_available":false]
    init(udid:String,health:CaptureHealth = .shared) {
        self.health=health;clock=monotonic;lastPresent=monotonic();connect={try NativeFramebufferSource(udid:udid)};health.created()
    }
    init(source:@escaping()throws->any NativeSurfaceSource,health:CaptureHealth = .shared,clock:@escaping()->Double = monotonic) { self.health=health;self.clock=clock;lastPresent=clock();connect=source;health.created() }
    var diagnostics:[String:Any] { lock.withLock{stats} }
    private var stopped:Bool {lock.withLock{cancelled}}
    private func count(_ key:String) { lock.withLock{stats[key]=(stats[key] as? Int ?? 0)+1} }
    // Compatibility helper: returned pixels retain their own immutable lease.
    static func snapshot(_ surface:IOSurface)throws->Pixels? {
        switch try NativeSnapshotReader().read(surface) {
        case .pixels(let pixels,_):return pixels
        case .busy:return nil
        }
    }
    private func publishStorage() {
        let values=snapshots.diagnostics
        lock.withLock {for (key,value) in values {stats[key]=value}}
    }
    private func invalidate() {
        cached=nil;lastLayout=nil;lastScale=nil;generation &+= 1;recovery=true
        snapshots.reset()
        lock.withLock{stats["cached_image_available"]=false;stats["owned_snapshot_bytes"]=0}
    }
    private func readableDeadline()throws {
        if clock()-lastPresent>8 {throw WispError("Native framebuffer produced no readable image for8s; reopen this view or choose Mac window")}
    }
    private func emit(quality:Int,fps:Int,forceKeyframe:Bool,dataSaver:Bool,changed:Bool,sourceWidth:Int,sourceHeight:Int,busy:Bool=false)throws->Video? {
        guard !stopped,let cached,changed || !dataSaver || forceKeyframe || recovery else{return nil}
        let frame=try encoder!.encode(cached,quality:quality,fps:fps,forceKeyframe:forceKeyframe || recovery)
        guard !stopped else{return nil}
        recovery=false;count("h264_encodes");if !changed {count("cached_image_encodes")};if busy {count("busy_cached_image_encodes")}
        return Video(frame:frame,generation:generation,sourceWidth:sourceWidth,sourceHeight:sourceHeight)
    }
    func h264(quality:Int,fps:Int,forceKeyframe:Bool,dataSaver:Bool,scaling:IOSCaptureScale = .full)throws->Video? {
        try encodeLock.withLock{try autoreleasepool {
            defer {publishStorage()}
            do {
                guard !stopped else{return nil}
                if source==nil {source=try connect()}
                guard !stopped else{return nil}
                count("polls")
                guard let surface=try source!.surface() else {
                    count("dropped_snapshots");count("inactive_surfaces");invalidate();try readableDeadline();return nil
                }
                guard !stopped else{return nil}
                let pixels:Pixels,layout:NativeSnapshotReader.Layout,changed:Bool
                switch try snapshots.readReference(surface) {
                case .busy(let current,let reason):
                    count("dropped_snapshots");count("busy_snapshots")
                    count(reason == .seed ? "busy_seed_snapshots":"busy_storage_snapshots")
                    try readableDeadline() // Cached encodes must never extend this deadline.
                    if current==lastLayout,lastScale==scaling,cached != nil {
                        // Only same-layout, still-present busy reads retain the
                        // last OWNED image. NEW encode/PTS, no epoch/input churn.
                        return try emit(quality:quality,fps:fps,forceKeyframe:forceKeyframe,dataSaver:dataSaver,changed:false,sourceWidth:current.width,sourceHeight:current.height,busy:true)
                    }
                    count("busy_without_cached_image")
                    if cached != nil || lastLayout != nil {count("busy_geometry_changes");invalidate()}
                    return nil
                case .pixels(let image,let current,let different):pixels=image;layout=current;changed=different
                }
                guard !stopped else{return nil}
                lastPresent=clock()
                let scale=min(scaling.factor,4096/Double(max(pixels.width,pixels.height)))
                let w=max(1,Int((Double(pixels.width)*scale).rounded(.down))),h=max(1,Int((Double(pixels.height)*scale).rounded(.down)))
                let sourceResized=lastLayout.map{$0.width != layout.width || $0.height != layout.height} ?? false
                if sourceResized || encoder?.width != w || encoder?.height != h {
                    cached=nil;encoder?.close();encoder=try H264Encoder(width:w,height:h);generation &+= 1;recovery=true;count("encoder_creations")
                }
                if changed || cached==nil {
                    let image=CIImage(bitmapData:pixels.bytes,bytesPerRow:pixels.width*4,size:CGSize(width:pixels.width,height:pixels.height),format:.BGRA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
                    cached=try encoder!.prepare(image.transformed(by:CGAffineTransform(scaleX:Double(w)/Double(pixels.width),y:Double(h)/Double(pixels.height))),waitForCompletion:true)
                    count("source_frames");count("prepared_pixel_buffers")
                }
                lastLayout=layout;lastScale=scaling
                lock.withLock{stats["cached_image_available"]=true;stats["video_width"]=w;stats["video_height"]=h;stats["native_scale"]=scaling.rawValue;stats["source_width"]=pixels.width;stats["source_height"]=pixels.height;stats["owned_snapshot_bytes"]=pixels.bytes.count;stats["hardware_encoder"]=encoder!.hardware}
                return try emit(quality:quality,fps:fps,forceKeyframe:forceKeyframe,dataSaver:dataSaver,changed:changed,sourceWidth:pixels.width,sourceHeight:pixels.height)
            } catch {invalidate();throw error}
        }}
    }
    // Cancellation is immediate; the worker joins any synchronous private API /
    // encoder work BEFORE release and before StreamSession.stop completes.
    func cancel() { lock.withLock{cancelled=true} }
    func stop() { cancel();encodeLock.withLock{guard !ended else{return};ended=true;source?.close();source=nil;invalidate();encoder?.close();encoder=nil;publishStorage();health.released()} }
    deinit {stop()}
}
