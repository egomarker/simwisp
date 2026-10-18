import Foundation
import ObjectiveC
import IOSurface
import Darwin

// Compatible, deliberately small CoreSimulator bridge. No private callbacks,
// simulator commands, boot/shutdown or input. Loaded only after explicit Native.
// Selector architecture: owner-supplied Xcode16 probes; see README attribution.
enum IOSCaptureMode: String {
    case window = "current", native
    static func selected(_ value: String?, platform: String) -> Self {
        platform == "ios" && value == "native" ? .native : .window
    }
}

enum NativeInvoke {
    // Reject a known-incompatible ABI BEFORE casting an IMP. This detects
    // signature drift, not all behavioral changes in Apple's private APIs.
    private static func compatible(_ value:String,_ wanted:String)->Bool {
        let bare=value.drop(while:{"rnNoORV".contains($0)})
        return wanted=="@" ? bare.hasPrefix("@") && !bare.hasPrefix("@?") : bare==wanted
    }
    private static func runtimeClass(_ target:NSObject)throws->AnyClass {
        guard let cls=object_getClass(target) else {throw WispError("Native object has no runtime class")};return cls
    }
    static func method(_ cls: AnyClass, _ name: String, returns: String, arguments: [String]) throws -> (Selector, IMP) {
        let sel = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, sel),
              method_getNumberOfArguments(method) == arguments.count + 2 else { throw WispError("Native API unavailable: \(name)") }
        func typeString(_ p: UnsafeMutablePointer<CChar>?) -> String {
            guard let p else { return "" }; defer { free(p) }; return String(cString:p)
        }
        guard compatible(typeString(method_copyReturnType(method)),returns), arguments.enumerated().allSatisfy({ compatible(typeString(method_copyArgumentType(method,UInt32($0.offset+2))),$0.element) }) else {
            throw WispError("Native API signature changed: \(name)")
        }
        return (sel, method_getImplementation(method))
    }
    static func object(_ target: NSObject, _ name: String) throws -> NSObject? {
        let cls:AnyClass=try runtimeClass(target)
        let sel=NSSelectorFromString(name)
        if class_getInstanceMethod(cls,sel) != nil {
            let (_,imp)=try method(cls,name,returns:"@",arguments:[])
            typealias F = @convention(c) (AnyObject,Selector)->AnyObject?
            return unsafeBitCast(imp,to:F.self)(target,sel) as? NSObject
        }
        // CoreSimulator IO objects may be ObjC/XPC proxies: responds(to:) can
        // be true with NO concrete Method/IMP. Validate their advertised ABI,
        // then use normal ObjC message dispatch so forwarding can run.
        guard target.responds(to:sel),try forwardedObjectGetter(target,cls:cls,selector:sel) else {
            throw WispError("Native API unavailable: \(name)")
        }
        return target.perform(sel)?.takeUnretainedValue() as? NSObject
    }
    private static func forwardedObjectGetter(_ target:NSObject,cls:AnyClass,selector:Selector)throws->Bool {
        // NSMethodSignature is unavailable to Swift's importer, but its public
        // ObjC interface is stable. Guard every reflection call's own ABI too.
        let (getSignature,signatureIMP)=try method(cls,"methodSignatureForSelector:",returns:"@",arguments:[":"])
        typealias Signature = @convention(c) (AnyObject,Selector,Selector)->AnyObject?
        guard let signature=unsafeBitCast(signatureIMP,to:Signature.self)(target,getSignature,selector) as? NSObject else{return false}
        let signatureClass:AnyClass=try runtimeClass(signature)
        let (getCount,countIMP)=try method(signatureClass,"numberOfArguments",returns:"Q",arguments:[])
        typealias Count = @convention(c) (AnyObject,Selector)->UInt
        guard unsafeBitCast(countIMP,to:Count.self)(signature,getCount)==2 else{return false}
        let (getReturn,returnIMP)=try method(signatureClass,"methodReturnType",returns:"*",arguments:[])
        typealias ReturnType = @convention(c) (AnyObject,Selector)->UnsafePointer<CChar>?
        guard let result=unsafeBitCast(returnIMP,to:ReturnType.self)(signature,getReturn),compatible(String(cString:result),"@") else{return false}
        let (getArgument,argumentIMP)=try method(signatureClass,"getArgumentTypeAtIndex:",returns:"*",arguments:["Q"])
        typealias Argument = @convention(c) (AnyObject,Selector,UInt)->UnsafePointer<CChar>?
        let argument=unsafeBitCast(argumentIMP,to:Argument.self)
        guard let receiver=argument(signature,getArgument,0),let command=argument(signature,getArgument,1) else{return false}
        return compatible(String(cString:receiver),"@") && compatible(String(cString:command),":")
    }
    static func optionalObject(_ target: NSObject, _ name: String) throws -> NSObject? {
        guard target.responds(to:NSSelectorFromString(name)) else { return nil }
        return try object(target,name)
    }
    static func objects(_ target: NSObject, _ name: String) throws -> [NSObject] {
        guard let value = try optionalObject(target,name) else { return [] }
        if let a=value as? [NSObject] { return a }
        if let d=value as? NSDictionary { return d.allValues.compactMap{$0 as? NSObject} }
        throw WispError("Native API returned invalid collection: \(name)")
    }
    static func update(_ target: NSObject) throws {
        let (sel,imp)=try method(try runtimeClass(target),"updateIOPorts",returns:"v",arguments:[])
        typealias F = @convention(c) (AnyObject,Selector)->Void
        unsafeBitCast(imp,to:F.self)(target,sel)
    }
    static func context(_ cls: AnyClass, developer: String) throws -> NSObject {
        guard let meta=object_getClass(cls) else { throw WispError("Native service class unavailable") }
        let (sel,imp)=try method(meta,"sharedServiceContextForDeveloperDir:error:",returns:"@",arguments:["@","^@"])
        typealias F = @convention(c) (AnyClass,Selector,AnyObject,AutoreleasingUnsafeMutablePointer<NSError?>)->AnyObject?
        var error:NSError?
        guard let value=unsafeBitCast(imp,to:F.self)(cls,sel,developer as NSString,&error) as? NSObject else { throw WispError("Native service context unavailable") }
        return value
    }
    static func deviceSet(_ target: NSObject) throws -> NSObject {
        if !target.responds(to:NSSelectorFromString("defaultDeviceSetWithError:")) {
            guard let value=try object(target,"defaultDeviceSet") else { throw WispError("Native default device set unavailable") }; return value
        }
        let (sel,imp)=try method(try runtimeClass(target),"defaultDeviceSetWithError:",returns:"@",arguments:["^@"])
        typealias F = @convention(c) (AnyObject,Selector,AutoreleasingUnsafeMutablePointer<NSError?>)->AnyObject?
        var error:NSError?
        guard let value=unsafeBitCast(imp,to:F.self)(target,sel,&error) as? NSObject else { throw WispError("Native default device set unavailable") }; return value
    }
}

protocol NativeSurfaceSource: AnyObject {
    func surface() throws -> IOSurface?
    func close()
}

final class NativeFramebufferSource: NativeSurfaceSource {
    // Keep framework handles process-wide. dlclose while another stream holds
    // private ObjC objects/classes is unsafe. Device/IO refs remain per capture.
    private static let loadLock=NSLock()
    private static var handles:[String:UnsafeMutableRawPointer]=[:]
    private static var loadedDeveloper:String?
    private var device:NSObject?, io:NSObject?
    private var closed=false,discovered=false
    static let maxPorts=256
    private struct PortMetadata {
        // Own the key object: an ObjectIdentifier must not outlive its owner.
        let owner:NSObject, descriptor:NSObject?
        let surfaceGetter:String?
    }
    private var portMetadata:[ObjectIdentifier:PortMetadata]=[:]
    init(udid:String) throws {
        guard UUID(uuidString:udid) != nil else { throw WispError("Native requires an iOS Simulator UUID") }
        let result=try command("/usr/bin/xcode-select",["-p"],timeout:5)
        let developer=String(data:result.output,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        guard result.status==0,developer.hasPrefix("/"),!developer.contains("\n") else { throw WispError("Native requires a selected Xcode developer directory") }
        try Self.loadLock.withLock {
            guard Self.loadedDeveloper == nil || Self.loadedDeveloper == developer else {throw WispError("Native selected Xcode changed; reopen Simwisp before using Native")}
            func load(_ paths:[String],required:Bool)throws {
                if paths.contains(where:{Self.handles[$0] != nil}) { return }
                for path in paths where FileManager.default.fileExists(atPath:path) {
                    if let handle=dlopen(path,RTLD_NOW|RTLD_GLOBAL) { Self.handles[path]=handle;return }
                }
                if required { throw WispError("Native CoreSimulator framework unavailable in selected Xcode") }
            }
            try load(["\(developer)/Library/PrivateFrameworks/CoreSimulator.framework/CoreSimulator","/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"],required:true)
            try load(["\(developer)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit","\(developer)/../SharedFrameworks/SimulatorKit.framework/SimulatorKit"],required:false)
            Self.loadedDeveloper=developer
        }
        guard let cls=NSClassFromString("SimServiceContext") else { throw WispError("Native CoreSimulator service class unavailable") }
        let set=try NativeInvoke.deviceSet(NativeInvoke.context(cls,developer:developer))
        var devices=try NativeInvoke.objects(set,"availableDevices")
        if devices.isEmpty { devices=try NativeInvoke.objects(set,"devices") }
        guard let selected=try devices.first(where:{
            let raw=try NativeInvoke.object($0,"UDID")
            return ((raw as? NSUUID)?.uuidString ?? raw?.description ?? "").caseInsensitiveCompare(udid) == .orderedSame
        }) else { throw WispError("Native could not find selected simulator in default device set") }
        guard let client=try NativeInvoke.object(selected,"io") else { throw WispError("Native simulator IO unavailable") }
        device=selected;io=client
    }
    // Injection exercises the SAME selector/port/surface path without loading
    // frameworks, enumerating real devices or opening a simulator connection.
    init(testIO:NSObject) { io=testIO }
    private func clearMetadata() { portMetadata.removeAll();discovered=false }
    private func metadata(_ port:NSObject)throws->PortMetadata {
        let key=ObjectIdentifier(port)
        if let cached=portMetadata[key],cached.owner === port {return cached}
        let id=try NativeInvoke.optionalObject(port,"portIdentifier") ?? NativeInvoke.optionalObject(port,"identifier")
        let descriptor:NSObject?,getter:String?
        if id?.description == "com.apple.framebuffer.display" {
            descriptor=try NativeInvoke.optionalObject(port,"descriptor") ?? port
            getter=descriptor!.responds(to:NSSelectorFromString("framebufferSurface")) ? "framebufferSurface":"ioSurface"
        } else { descriptor=nil;getter=nil }
        let value=PortMetadata(owner:port,descriptor:descriptor,surfaceGetter:getter)
        portMetadata[key]=value;return value
    }
    func surface() throws -> IOSurface? {
        guard !closed, let io else { throw WispError("Native framebuffer source closed") }
        do {
        if !discovered {
            // Owner-selected session lifetime: no timer, periodic audit or live
            // inventory polling. Read-only metadata RPCs can block for tens of
            // milliseconds; resolve once while this source remains usable.
            if io.responds(to:NSSelectorFromString("updateIOPorts")) { try NativeInvoke.update(io) }
            var ports=try NativeInvoke.objects(io,"deviceIOPorts")
            if ports.isEmpty { ports=try NativeInvoke.objects(io,"ioPorts") }
            guard ports.count<=Self.maxPorts else {throw WispError("Native simulator IO exceeds 256 ports")}
            for port in ports {_ = try metadata(port)}
            discovered=true
        }
        // Silent topology/descriptor changes behind still-readable bindings
        // are deliberately NOT detected. Unavailability/error clears discovery;
        // only a later explicit read/reopen rediscovers, never a hidden retry.
        // Xcode exposes main + secondary framebuffer planes, not necessarily
        // one port per simulator screen. Follow the supplied/upstream policy:
        // largest live surface area, not port order. Distinct tied winners are
        // still ambiguous; aliases of the SAME kernel IOSurface are not.
        var matchingPorts=0,largestArea=0,ambiguous=false
        var largest:IOSurface?
        for entry in portMetadata.values {
            guard let descriptor=entry.descriptor,let name=entry.surfaceGetter else {continue}
            matchingPorts+=1
            // Never cache an IOSurface or a getter IMP: fresh surfaces and
            // checked ordinary ObjC/forwarded dispatch remain per-poll.
            guard let value=try NativeInvoke.object(descriptor,name) else {continue}
            guard let surface=value as? IOSurface else {throw WispError("Native framebuffer returned an unsupported surface type")}
            let width=IOSurfaceGetWidth(surface),height=IOSurfaceGetHeight(surface)
            guard width>0,height>0 else {continue}
            let (area,overflow)=width.multipliedReportingOverflow(by:height)
            guard !overflow else {throw WispError("Native framebuffer geometry overflow")}
            if area>largestArea {
                largest=surface;largestArea=area;ambiguous=false
            } else if area==largestArea,let previous=largest {
                let previousID=IOSurfaceGetID(previous),currentID=IOSurfaceGetID(surface)
                if !(previous === surface || (previousID != 0 && previousID==currentID)) {ambiguous=true}
            }
        }
        guard matchingPorts>0 else {throw WispError("Native simulator has no framebuffer display ports")}
        if ambiguous,let largest {
            throw WispError("Native has distinct equally sized largest framebuffer surfaces (\(IOSurfaceGetWidth(largest))x\(IOSurfaceGetHeight(largest)); \(matchingPorts) matching ports)")
        }
        // No live plane is inactivity: discard cached pixels in NativeCapture,
        // retaining its existing bounded first-readable-image deadline.
        if largest == nil {clearMetadata()}
        return largest
        } catch {clearMetadata();throw error}
    }
    func close() { closed=true;clearMetadata();io=nil;device=nil }
}
