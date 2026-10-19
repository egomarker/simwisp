import Foundation
import ObjectiveC
import Darwin

// Original device-bound bridge, informed by SimKit's IOHID parent+finger
// recipe (Apache2; Resources/Native/NOTICE). No mouse-NSEvent ABI guessing.
// C signatures/layout are private: validate constructed messages and ObjC ABI
// before handing anything to the client. This is not runtime certification.
final class NativeHIDMessage {
    private(set) var pointer: UnsafeMutableRawPointer?
    let count: Int
    init(taking raw: UnsafeMutableRawPointer) throws {
        let capacity=malloc_size(raw)
        guard capacity>=0xc0, capacity<=4096, raw.load(fromByteOffset:0x18,as:UInt32.self)==0xa0 else {
            free(raw);throw WispError("Native HID message layout is incompatible with this Xcode")
        }
        let records=Int(raw.load(fromByteOffset:0x1c,as:UInt8.self))
        guard (1...2).contains(records), capacity>=0x20+records*0xa0 else { free(raw);throw WispError("Native HID message record count is incompatible") }
        pointer=raw;count=records
    }
    deinit { if let pointer { free(pointer) } }
    func take() -> UnsafeMutableRawPointer {
        let raw=pointer!;pointer=nil;return raw // ownership transfers exactly once
    }
    func validateTouch(edge: NativeTouchEdge) throws {
        guard count==2, let raw=pointer else { throw WispError("Native HID digitizer requires a parent and one finger") }
        // Never patch an unknown-sized allocation or a non-digitizer record.
        for base in [0x20,0xc0] {
            guard raw.load(fromByteOffset:base,as:UInt32.self)==11,
                  raw.load(fromByteOffset:base+0x4c,as:UInt32.self)==0x32 else { throw WispError("Native HID digitizer layout/target changed") }
        }
        for base in [0x20,0xc0] {
            raw.storeBytes(of:UInt8(edge == .none ? 0 : 4),toByteOffset:base+0x1a,as:UInt8.self)
            raw.storeBytes(of:edge.rawValue,toByteOffset:base+0x1b,as:UInt8.self)
        }
    }
}

struct NativeHIDSymbols {
    typealias Parent = @convention(c) (CFAllocator?,UInt64,UInt32,UInt32,UInt32,UInt32,UInt32,Double,Double,Double,Double,Double,Bool,Bool,UInt32)->Unmanaged<CFTypeRef>?
    typealias Finger = @convention(c) (CFAllocator?,UInt64,UInt32,UInt32,UInt32,Double,Double,Double,Double,Double,Bool,Bool,UInt32)->Unmanaged<CFTypeRef>?
    typealias Append = @convention(c) (CFTypeRef,CFTypeRef,UInt32)->Void
    // Xcode16.4 reads argument2 into BOTH record routing targets. SimKit's
    // one-argument declaration omits it; do not copy that uninitialized ABI.
    typealias Wrap = @convention(c) (UnsafeRawPointer,UInt32)->UnsafeMutableRawPointer?
    typealias Key = @convention(c) (UInt32,UInt32,UInt32,UInt32)->UnsafeMutableRawPointer?
    typealias Button = @convention(c) (UInt32,UInt32,UInt32)->UnsafeMutableRawPointer?
    typealias Service = @convention(c) ()->UnsafeMutableRawPointer?
    let parent: Parent, finger: Finger, append: Append, wrap: Wrap, key: Key, button: Button
    let createPointer: Service, removePointer: Service, createMouse: Service, removeMouse: Service
    init() throws {
        _ = try NativeSimulatorDevice.load()
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let pointer=dlsym(UnsafeMutableRawPointer(bitPattern:-2),name) else { throw WispError("Native input API unavailable: \(name)") }
            return unsafeBitCast(pointer,to:type)
        }
        parent=try symbol("IOHIDEventCreateDigitizerEvent",Parent.self)
        finger=try symbol("IOHIDEventCreateDigitizerFingerEvent",Finger.self)
        append=try symbol("IOHIDEventAppendEvent",Append.self)
        wrap=try symbol("IndigoHIDMessageForTrackpadEventFromHIDEventRef",Wrap.self)
        key=try symbol("IndigoHIDMessageForHIDArbitrary",Key.self)
        button=try symbol("IndigoHIDMessageForButton",Button.self)
        createPointer=try symbol("IndigoHIDMessageToCreatePointerService",Service.self)
        removePointer=try symbol("IndigoHIDMessageToRemovePointerService",Service.self)
        createMouse=try symbol("IndigoHIDMessageToCreateMouseService",Service.self)
        removeMouse=try symbol("IndigoHIDMessageToRemoveMouseService",Service.self)
    }
    func message(_ raw: UnsafeMutableRawPointer?) throws -> NativeHIDMessage {
        guard let raw else { throw WispError("Native HID message allocation failed") }
        return try NativeHIDMessage(taking:raw)
    }
    func build(_ event: NativeHIDEvent) throws -> NativeHIDMessage {
        switch event {
        case .touch(let touch):
            let time=mach_absolute_time(), phase=touch.phase
            guard let parent=parent(nil,time,2,0,touch.identifier,phase.mask,0,touch.point.x,touch.point.y,0,0,0,phase.touching,phase.touching,0)?.takeRetainedValue(),
                  let child=finger(nil,time,0,touch.identifier,phase.mask,touch.point.x,touch.point.y,0,0,0,phase.touching,phase.touching,0)?.takeRetainedValue() else { throw WispError("Native HID digitizer allocation failed") }
            append(parent,child,0)
            let raw=withExtendedLifetime((parent,child)) { wrap(Unmanaged.passUnretained(parent as AnyObject).toOpaque(),0x32) }
            let result=try message(raw);try result.validateTouch(edge:touch.edge);return result
        case .key(let usage,let down):
            let result=try message(key(0x32,7,usage,down ? 1:2)), raw=result.pointer!
            guard result.count==1,raw.load(fromByteOffset:0x20,as:UInt32.self)==2,
                  raw.load(fromByteOffset:0x34,as:UInt32.self)==(down ? 1:2),raw.load(fromByteOffset:0x38,as:UInt32.self)==0x32,
                  raw.load(fromByteOffset:0x3c,as:UInt32.self)==usage,raw.load(fromByteOffset:0x44,as:UInt32.self)==7 else { throw WispError("Native HID keyboard layout changed") }
            return result
        case .home(let down):
            let result=try message(button(0,down ? 1:2,0x33)),raw=result.pointer!
            guard result.count==1,raw.load(fromByteOffset:0x20,as:UInt32.self)==2,
                  raw.load(fromByteOffset:0x30,as:UInt32.self)==0,raw.load(fromByteOffset:0x34,as:UInt32.self)==(down ? 1:2),
                  raw.load(fromByteOffset:0x38,as:UInt32.self)==0x33 else { throw WispError("Native HID button layout changed") }
            return result
        }
    }
}

// One acknowledged message in flight. Waiting is confined to an active input
// worker, never the network/capture queues; no retry, timer or idle watchdog.
final class NativeHIDChannel {
    private var client: NSObject?
    private let selector: Selector, implementation: IMP
    private let timeout: TimeInterval
    init(client: NSObject, timeout: TimeInterval = 1) throws {
        let (selector,implementation)=try Self.sender(type(of:client))
        self.client=client;self.selector=selector;self.implementation=implementation;self.timeout=timeout
    }
    static func sender(_ cls: AnyClass) throws -> (Selector,IMP) {
        let name="sendWithMessage:freeWhenDone:completionQueue:completion:"
        guard let method=class_getInstanceMethod(cls,NSSelectorFromString(name)) else { throw WispError("Native HID sender unavailable") }
        func type(_ index: UInt32) -> String {
            guard let value=method_copyArgumentType(method,index) else { return "" };defer { free(value) }
            return String(cString:value).drop(while:{"rnNoORV".contains($0)}).description
        }
        let pointer=type(2), boolean=type(3)
        guard pointer=="^v" || pointer.hasPrefix("^{IndigoHIDMessageStruct="), ["B","c"].contains(boolean) else { throw WispError("Native HID sender signature changed") }
        return try NativeInvoke.method(cls,name,returns:"v",arguments:[pointer,boolean,"@","@?"])
    }
    static func makeClient(_ cls: AnyClass, device: NSObject) throws -> NSObject {
        guard let meta=object_getClass(cls) else { throw WispError("Native HID class unavailable") }
        let (alloc,allocIMP)=try NativeInvoke.method(meta,"alloc",returns:"@",arguments:[])
        let (initialize,initializeIMP)=try NativeInvoke.method(cls,"initWithDevice:error:",returns:"@",arguments:["@","^@"])
        _ = try sender(cls) // reject ABI drift BEFORE allocating a client
        typealias Allocate = @convention(c) (AnyClass,Selector)->UnsafeMutableRawPointer?
        typealias Initialize = @convention(c) (UnsafeMutableRawPointer,Selector,AnyObject,AutoreleasingUnsafeMutablePointer<NSError?>)->UnsafeMutableRawPointer?
        guard let raw=unsafeBitCast(allocIMP,to:Allocate.self)(cls,alloc) else { throw WispError("Native HID client allocation failed") }
        // alloc's +1 is consumed by init and adopted once, with no intermediate
        // ARC owner that could over-release a failed/replaced initializer.
        var error: NSError?
        guard let initialized=unsafeBitCast(initializeIMP,to:Initialize.self)(raw,initialize,device,&error) else { throw WispError("Native HID connection failed: \(error?.localizedDescription ?? "unknown error")") }
        return Unmanaged<NSObject>.fromOpaque(initialized).takeRetainedValue()
    }
    private final class Reply {
        let lock=NSLock(), done=DispatchSemaphore(value:0)
        var error: String?
        func finish(_ error: NSError?) { lock.withLock { self.error=error?.localizedDescription };done.signal() }
    }
    func send(_ message: NativeHIDMessage) throws {
        guard let client else { throw WispError("Native HID input is closed") }
        let reply=Reply()
        let completion: @convention(block) (NSError?)->Void = { reply.finish($0) }
        typealias Send = @convention(c) (AnyObject,Selector,UnsafeMutableRawPointer,ObjCBool,AnyObject?,AnyObject?)->Void
        unsafeBitCast(implementation,to:Send.self)(client,selector,message.take(),ObjCBool(true),DispatchQueue.global(qos:.userInteractive) as AnyObject,completion as AnyObject)
        // freeWhenDone owns the message even on an error/late completion. Never
        // free it here, including the bounded timeout path.
        guard reply.done.wait(timeout:.now()+timeout) == .success else { throw WispError("Native HID input acknowledgement timed out; reopen this view") }
        if let error=reply.lock.withLock({reply.error}) { throw WispError("Native HID input failed: \(error)") }
    }
    func close() { client=nil }
}

final class NativeHIDTransport: NativeInputTransport {
    private let symbols: NativeHIDSymbols
    private var channel: NativeHIDChannel?
    private var removals: [NativeHIDSymbols.Service] = []
    init(udid: String) throws {
        guard UUID(uuidString:udid) != nil else { throw WispError("Native requires an iOS Simulator UUID") }
        symbols=try NativeHIDSymbols()
        let device=try NativeSimulatorDevice.resolve(udid:udid)
        guard let cls=NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") else { throw WispError("Native iOS input is unavailable in selected Xcode") }
        channel=try NativeHIDChannel(client:NativeHIDChannel.makeClient(cls,device:device))
        do {
            for (create,remove) in [(symbols.createPointer,symbols.removePointer),(symbols.createMouse,symbols.removeMouse)] {
                let message=try symbols.message(create())
                removals.append(remove) // even a failed ACK needs best-effort teardown
                try channel!.send(message)
            }
        } catch { try? close();throw error }
    }
    func send(_ event: NativeHIDEvent) throws {
        guard let channel else { throw WispError("Native iOS input is closed") }
        try channel.send(symbols.build(event))
    }
    func close() throws {
        guard let channel else { return };self.channel=nil
        var first: Error?
        for remove in removals.reversed() { do { try channel.send(symbols.message(remove())) } catch { if first == nil { first=error } } }
        removals.removeAll();channel.close()
        if let first { throw first }
    }
}
