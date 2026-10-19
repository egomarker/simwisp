import Foundation

// Independent of capture and Quartz. Only StreamSession's serial input worker
// calls perform/close; invalidate is the sole cross-queue operation. No timer,
// capture callback, helper process, clipboard, host focus or global HID input.
enum IOSInputMode: String {
    case quartz = "current", native
    static func selected(_ value: String?, platform: String) -> Self {
        platform == "ios" && value == "native" ? .native : .quartz
    }
}
struct NativeInputGeometry: Equatable {
    let width: Int, height: Int
    init?(_ width: Int, _ height: Int) {
        guard (1...8192).contains(width), (1...8192).contains(height) else { return nil }
        self.width=width;self.height=height
    }
}
enum NativeInputError: LocalizedError {
    case invalid(String), unavailable(String), cancelled
    var errorDescription: String? {
        switch self {
        case .invalid(let text), .unavailable(let text): return text
        case .cancelled: return "Native input session ended"
        }
    }
}
enum NativeTouchPhase: Equatable { case down, move, up
    var mask: UInt32 { self == .up ? 0x06 : 0x07 }
    var touching: Bool { self != .up }
}
enum NativeTouchEdge: UInt8 { case none=0, bottom=1, left=2, right=4, top=8 }
struct NativeTouch: Equatable {
    let phase: NativeTouchPhase, identifier: UInt32
    let point: CGPoint, edge: NativeTouchEdge
}
enum NativeHIDEvent: Equatable {
    case touch(NativeTouch), key(UInt32, Bool), home(Bool)
}
protocol NativeInputTransport: AnyObject {
    func send(_ event: NativeHIDEvent) throws
    func close() throws
}

struct NativeKeyStroke: Equatable {
    let usage: UInt32, shift: Bool
    // USB HID keyboard page 7, US layout; reject an entire text request before
    // sending its first character. Unicode is never silently pasted via Quartz.
    static func ascii(_ value: UInt8) -> Self? {
        if (97...122).contains(value) { return .init(usage: UInt32(value-97)+4, shift: false) }
        if (65...90).contains(value) { return .init(usage: UInt32(value-65)+4, shift: true) }
        if (49...57).contains(value) { return .init(usage: UInt32(value-49)+30, shift: false) }
        let map: [UInt8:(UInt32,Bool)] = [
            48:(39,false),9:(43,false),10:(40,false),13:(40,false),32:(44,false),
            33:(30,true),34:(52,true),35:(32,true),36:(33,true),37:(34,true),
            38:(36,true),39:(52,false),40:(38,true),41:(39,true),42:(37,true),
            43:(46,true),44:(54,false),45:(45,false),46:(55,false),47:(56,false),
            58:(51,true),59:(51,false),60:(54,true),61:(46,false),62:(55,true),
            63:(56,true),64:(31,true),91:(47,false),92:(49,false),93:(48,false),
            94:(35,true),95:(45,true),96:(53,false),123:(47,true),124:(49,true),
            125:(48,true),126:(53,true)]
        return map[value].map { .init(usage:$0.0,shift:$0.1) }
    }
    static func named(_ value: String) -> Self? {
        let map: [String:UInt32] = ["enter":40,"return":40,"escape":41,"delete":42,"backspace":42,"tab":43,"space":44,"home":74,"end":77,"pageup":75,"pagedown":78,"arrowright":79,"arrowleft":80,"arrowdown":81,"arrowup":82]
        if let usage=map[value.lowercased()] { return .init(usage:usage,shift:false) }
        let bytes=Array(value.utf8)
        return bytes.count == 1 ? ascii(bytes[0]) : nil
    }
}

final class NativeIOSInput {
    typealias Factory = (String) throws -> NativeInputTransport
    private let id: String, makeTransport: Factory, sleep: (TimeInterval) -> Void
    private let admission=NSLock()
    private var invalidated=false
    private var transport: NativeInputTransport?
    private var contact: (identifier:UInt32, point:CGPoint, edge:NativeTouchEdge, geometry:NativeInputGeometry, attempted:Bool)?
    private var identifier: UInt32
    private var heldKeys: [UInt32] = []
    private var heldHome=false, closed=false
    private var cleanupFailure: String?
    private(set) var failure: String?
    var connected: Bool { transport != nil } // read only on the serial input worker
    init(id: String, makeTransport: @escaping Factory = { try NativeHIDTransport(udid:$0) }, sleep: @escaping (TimeInterval)->Void = { Thread.sleep(forTimeInterval:$0) }, identifierSeed: UInt32 = 0) {
        self.id=id;self.makeTransport=makeTransport;self.sleep=sleep;identifier=identifierSeed
    }
    func invalidate() { admission.withLock { invalidated=true } }
    private func checkAdmission() throws {
        guard !closed, !admission.withLock({invalidated}) else { throw NativeInputError.cancelled }
    }
    private func emit(_ event: NativeHIDEvent) throws {
        try checkAdmission()
        if transport == nil { transport=try makeTransport(id) }
        // Cancellation during a slow factory cannot admit its first down.
        try checkAdmission()
        switch event {
        case .touch(let touch) where touch.phase == .down: contact?.attempted=true
        case .key(let usage,true): heldKeys.append(usage)
        case .home(true): heldHome=true
        default: break
        }
        try transport!.send(event)
    }
    private func releaseTouch() throws {
        guard let state=contact else { return }
        guard state.attempted else {contact=nil;return}
        try transport?.send(.touch(.init(phase:.up,identifier:state.identifier,point:state.point,edge:state.edge)))
        contact=nil
    }
    // Returns cleanup errors instead of pretending an unacknowledged UP worked.
    // All releases are attempted; per-session references are always dropped.
    @discardableResult func close() -> String? {
        invalidate();guard !closed else { return cleanupFailure };closed=true
        var first: String?
        func attempt(_ body: () throws -> Void) { do { try body() } catch { if first == nil { first=error.localizedDescription } } }
        attempt { try releaseTouch() };contact=nil
        for usage in heldKeys.reversed() { attempt { try transport?.send(.key(usage,false)) } };heldKeys.removeAll()
        if heldHome { attempt { try transport?.send(.home(false)) };heldHome=false }
        attempt { try transport?.close() };transport=nil
        cleanupFailure=first;return first
    }
    private func down(_ point: CGPoint, _ geometry: NativeInputGeometry) throws {
        try releaseTouch()
        identifier &+= 1;if identifier == 0 { identifier=1 }
        let edge: NativeTouchEdge
        // Freeze routing at DOWN, including genuine screen-edge drags. The
        // point is normalized exactly once; video scaling is not applied here.
        if point.y >= 1-10/Double(geometry.height) { edge = .bottom }
        else if point.y <= 10/Double(geometry.height) { edge = .top }
        else if point.x <= 10/Double(geometry.width) { edge = .left }
        else if point.x >= 1-10/Double(geometry.width) { edge = .right }
        else { edge = .none }
        contact=(identifier,point,edge,geometry,false)
        try emit(.touch(.init(phase:.down,identifier:identifier,point:point,edge:edge)))
    }
    private func move(_ point: CGPoint, _ geometry: NativeInputGeometry, up: Bool) throws {
        try checkAdmission()
        guard var state=contact else { return } // no orphan MOVE/UP can create input
        guard state.geometry == geometry else {
            try releaseTouch();throw NativeInputError.invalid("Native display geometry changed; start a new gesture")
        }
        state.point=point;contact=state
        if up { try releaseTouch() }
        else { try emit(.touch(.init(phase:.move,identifier:state.identifier,point:point,edge:state.edge))) }
    }
    private func key(_ stroke: NativeKeyStroke) throws {
        if stroke.shift { try emit(.key(0xe1,true)) }
        try emit(.key(stroke.usage,true))
        try emit(.key(stroke.usage,false));heldKeys.removeLast()
        if stroke.shift { try emit(.key(0xe1,false));heldKeys.removeLast() }
    }
    private func home() throws {
        try emit(.home(true));sleep(0.04)
        try emit(.home(false));heldHome=false
    }
    // System actions share this stream's cancellation/admission and retirement
    // barrier, but do not create a HID peer merely to rotate or shake an idle view.
    func performAction(_ action: (_ admission: () throws -> Void) throws -> Void) throws {
        do {
            try checkAdmission();try releaseTouch();try checkAdmission()
            try action(checkAdmission)
        } catch NativeInputError.cancelled {
            _ = close();throw NativeInputError.cancelled
        } catch {
            failure=error.localizedDescription;_ = close()
            throw NativeInputError.unavailable(failure!)
        }
    }
    func perform(_ message: [String:Any], geometry: NativeInputGeometry) throws {
        do {
            try checkAdmission()
            func point(_ x: String="x", _ y: String="y") throws -> CGPoint {
                guard let px=(message[x] as? NSNumber)?.doubleValue, let py=(message[y] as? NSNumber)?.doubleValue,
                      px.isFinite, py.isFinite, (0...1).contains(px), (0...1).contains(py),
                      CFGetTypeID(message[x] as CFTypeRef) != CFBooleanGetTypeID(), CFGetTypeID(message[y] as CFTypeRef) != CFBooleanGetTypeID() else {
                    throw NativeInputError.invalid("Native touch coordinates must be finite fractions between 0 and 1")
                }
                return CGPoint(x:px,y:py)
            }
            switch message["type"] as? String {
            case "touch_down": try down(point(),geometry)
            case "touch_move": try move(point(),geometry,up:false)
            case "touch_up": try move(point(),geometry,up:true)
            case "tap":
                let p=try point();try down(p,geometry);sleep(0.04);try move(p,geometry,up:true)
            case "drag":
                let from=try point("x1","y1"), to=try point("x2","y2")
                try down(from,geometry)
                for step in 1...12 {
                    sleep(0.016);try checkAdmission()
                    let t=Double(step)/12
                    try move(CGPoint(x:from.x+(to.x-from.x)*t,y:from.y+(to.y-from.y)*t),geometry,up:false)
                }
                try move(to,geometry,up:true)
            case "key":
                guard let name=message["key"] as? String, let stroke=NativeKeyStroke.named(name) else { throw NativeInputError.invalid("Unsupported Native keyboard key") }
                try key(stroke)
            case "text":
                guard let text=message["text"] as? String, text.utf8.count<=1024 else { throw NativeInputError.invalid("Native text is limited to 1024 US-layout ASCII characters") }
                let strokes=text.utf8.compactMap(NativeKeyStroke.ascii)
                guard strokes.count == text.utf8.count else { throw NativeInputError.invalid("Native typing supports US-layout ASCII; choose Quartz for Unicode paste") }
                for stroke in strokes { try key(stroke) }
            case "home": try releaseTouch();try home()
            case "app_switcher": try releaseTouch();try home();sleep(0.12);try home()
            default: throw NativeInputError.invalid("Unsupported Native input control")
            }
        } catch NativeInputError.cancelled {
            _ = close();throw NativeInputError.cancelled
        } catch NativeInputError.invalid(let reason) {
            // Invalid input cannot leave a previously pressed pointer behind.
            do { try releaseTouch() } catch { failure=error.localizedDescription;_ = close();throw NativeInputError.unavailable(failure!) }
            throw NativeInputError.invalid(reason)
        } catch {
            failure=error.localizedDescription;_ = close()
            throw NativeInputError.unavailable(failure!)
        }
    }
}
