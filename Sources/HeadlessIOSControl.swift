import Foundation
import ObjectiveC
import Darwin

// On-demand, device-scoped actions. No window, timer, background polling, cached
// port or orientation inferred from browser scaling. See Resources/Native/NOTICE.
enum HeadlessIOSControl {
    typealias Runner = (String, String, NativeInputGeometry, () throws -> Void) throws -> Void
    typealias Command = (String, [String], Double) throws -> CommandResult
    static let shakeNotification = "com.apple.UIKit.SimulatorShake"
    static func perform(_ action: String, id: String, geometry: NativeInputGeometry,
                        admission: () throws -> Void = {},
                        resolve: (String) throws -> NSObject = NativeSimulatorDevice.resolve,
                        run: Command = { try command($0,$1,timeout:$2) }) throws {
        guard UUID(uuidString:id) != nil, ["rotate","shake"].contains(action) else {
            throw WispError("Headless iOS control requires an exact Simulator UUID and supported action")
        }
        try admission()
        if action == "shake" {
            let result=try run("/usr/bin/xcrun",["simctl","notify_post",id,shakeNotification],5)
            guard result.status == 0 else {
                throw WispError("Headless Shake failed: \(String(decoding:result.error.prefix(500),as:UTF8.self))")
            }
        } else {
            let device=try resolve(id)
            try admission()
            try rotate(device,orientation:geometry.width>geometry.height ? 1:3,admission:admission)
        }
    }
    static func lookupSignature(_ cls: AnyClass) throws -> (Selector,IMP) {
        try NativeInvoke.method(cls,"lookup:error:",returns:"I",arguments:["@","^@"])
    }
    static func orientationMessage(_ orientation: UInt32, port: UInt32) throws -> Data {
        guard (1...4).contains(orientation), port != 0, port != UInt32.max,
              MemoryLayout<mach_msg_header_t>.size == 24 else {throw WispError("Incompatible headless orientation message")}
        // Pinned SimKit/baguette workspace-event recipe.112B backing allocation,
        //108B wire message; this is NOT a HID/Indigo message or a display rewrite.
        var data=Data(repeating:0,count:112)
        let fields: [(Int,UInt32)] = [(0,0x13),(4,108),(8,port),(0x14,0x7b),(0x18,50|0x20000),(0x48,4),(0x4c,orientation)]
        for (offset,value) in fields {
            var little=value.littleEndian
            withUnsafeBytes(of:&little) { data.replaceSubrange(offset..<offset+4,with:$0) }
        }
        return data
    }
    static func rotate(_ device: NSObject, orientation: UInt32, admission: () throws -> Void = {},
                       send: (Data) throws -> Void = sendOrientation,
                       release: (UInt32) -> Void = { _ = mach_port_deallocate(mach_task_self_,$0) }) throws {
        guard (1...4).contains(orientation),let cls=object_getClass(device) else {throw WispError("Invalid headless orientation")}
        let (selector,imp)=try lookupSignature(cls)
        typealias Lookup = @convention(c) (AnyObject,Selector,NSString,AutoreleasingUnsafeMutablePointer<NSError?>)->UInt32
        var error: NSError?
        try admission()
        let port=unsafeBitCast(imp,to:Lookup.self)(device,selector,"PurpleWorkspacePort",&error)
        guard port != 0,port != UInt32.max else {throw WispError("Headless orientation workspace unavailable: \(error?.localizedDescription ?? "guest is not ready")")}
        // lookup supplies an owned send right. Never leak it on send/cancel/error.
        defer {release(port)}
        if let error {throw WispError("Headless orientation lookup failed: \(error.localizedDescription)")}
        try admission()
        try send(orientationMessage(orientation,port:port))
    }
    static func sendOrientation(_ data: Data) throws {
        guard data.count == 112 else {throw WispError("Invalid headless orientation buffer")}
        let raw=UnsafeMutableRawPointer.allocate(byteCount:112,alignment:MemoryLayout<mach_msg_header_t>.alignment)
        defer {raw.deallocate()}
        data.copyBytes(to:raw.assumingMemoryBound(to:UInt8.self),count:112)
        // Only a bounded send on the active stream input worker. No receive,
        // retry or simulated success event; real framebuffer geometry is truth.
        let result=mach_msg(raw.assumingMemoryBound(to:mach_msg_header_t.self),MACH_SEND_MSG|MACH_SEND_TIMEOUT,108,0,0,100,0)
        guard result == KERN_SUCCESS else {throw WispError("Headless orientation send failed (\(result))")}
    }
}
