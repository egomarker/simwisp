import Foundation
import Darwin

// Emulator-host API only. Never accept a browser-supplied URL, port or token.
struct EmulatorRawEndpoint: CustomStringConvertible, CustomDebugStringConvertible {
    let port: Int
    let token: String
    var description: String { "Emulator raw loopback endpoint (credentials redacted)" }
    var debugDescription: String { description }
    init(port: Int, token: String) throws {
        guard (1024...65535).contains(port), !token.isEmpty, token.utf8.count <= 8192,
              token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw WispError("Invalid emulator raw credentials or port") }
        self.port=port;self.token=token
    }
    static var discoveryRoots: [URL] {
        let fm=FileManager.default
        return [fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/TemporaryItems/avd/running"),
                fm.temporaryDirectory.appendingPathComponent("avd/running")]
    }
    static func privateFile(_ url: URL) throws -> Data {
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else { throw WispError("Emulator raw discovery file is not readable") }
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        var s=stat()
        guard fstat(fd,&s)==0, s.st_mode & S_IFMT == S_IFREG, s.st_uid==geteuid(),
              s.st_mode & 0o022 == 0, (1...65536).contains(s.st_size),
              let data=try handle.read(upToCount:65537),data.count==Int(s.st_size) else {
            throw WispError("Unsafe emulator raw discovery file")
        }
        return data
    }
    static func parse(_ data: Data, serial: String, pid: Int32, process: (Int32)->Bool) throws -> EmulatorRawEndpoint? {
        guard serial.hasPrefix("emulator-"), let console=Int(serial.dropFirst(9)),
              serial=="emulator-\(console)", (1024...65534).contains(console),console%2==0,
              pid>0,data.count<=65536,let text=String(data:data,encoding:.utf8) else { throw WispError("Invalid emulator identity for raw capture") }
        var values=[String:String]()
        for line in text.components(separatedBy:.newlines) {
            let line=line.trimmingCharacters(in:.whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";"){continue}
            guard let equal=line.firstIndex(of:"=") else{continue}
            let key=String(line[..<equal]).trimmingCharacters(in:.whitespaces),value=String(line[line.index(after:equal)...]).trimmingCharacters(in:.whitespaces)
            guard values[key]==nil else{throw WispError("Duplicate emulator discovery field")};values[key]=value
        }
        guard Int(values["port.serial"] ?? "")==console else{return nil}
        guard process(pid) else{return nil}
        guard let port=Int(values["grpc.port"] ?? ""),let token=values["grpc.token"] else {
            throw WispError("Selected emulator has no live authenticated raw API")
        }
        return try EmulatorRawEndpoint(port:port,token:token)
    }
    static func discover(_ serial: String) throws -> EmulatorRawEndpoint {
        var matches=[EmulatorRawEndpoint](),seen=Set<String>()
        for root in discoveryRoots {
            guard let files=try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) else{continue}
            guard files.count<=256 else{throw WispError("Too many emulator discovery records")}
            for file in files {
                let name=file.lastPathComponent
                guard name.hasPrefix("pid_"),name.hasSuffix(".ini"),let pid=Int32(name.dropFirst(4).dropLast(4)),pid>0 else{continue}
                let identity=file.resolvingSymlinksInPath().path
                if !seen.insert(identity).inserted{continue}
                guard let data=try? privateFile(file) else{continue}
                if let match=try parse(data,serial:serial,pid:pid,process:{ pid in
                    guard kill(pid,0)==0,let p=try? command("/bin/ps",["-p",String(pid),"-o","comm="],timeout:2),p.status==0 else{return false}
                    return URL(fileURLWithPath:p.text.trimmingCharacters(in:.whitespacesAndNewlines)).lastPathComponent.hasPrefix("qemu-system-")
                }){matches.append(match)}
            }
        }
        guard matches.count==1 else{throw WispError(matches.isEmpty ? "Authenticated emulator raw API not found for this serial" : "Ambiguous emulator raw API identity")}
        return matches[0]
    }
}

// Minimal bounded protobuf subset of installed emulator_controller.proto.
// No MMAP, shared-memory handle, PNG, arbitrary display, URL or input RPCs.
enum EmulatorRawWire {
    static let maxEdge=4096,maxPixelBytes=32*1024*1024,maxMessage=maxPixelBytes+65536
    // Each completed message owns its slab until all payload/CI views release it.
    // The pool stores blocks, not leases: no cycle, no reuse of in-flight bytes.
    fileprivate final class Block {
        let pointer: UnsafeMutableRawPointer, capacity: Int
        init(_ capacity: Int) { self.capacity=capacity; pointer = .allocate(byteCount:capacity,alignment:64) }
        deinit { pointer.deallocate() }
    }
    fileprivate final class Lease {
        let block: Block
        private let pool: SlabPool?
        init(_ block: Block, pool: SlabPool? = nil) { self.block=block; self.pool=pool }
        deinit { pool?.recycle(block) }
    }
    fileprivate final class SlabPool {
        private let lock=NSLock()
        private var spare=[Block](), slots=0, allocations:UInt64=0, reuses:UInt64=0
        private var preferredCapacity=0, smallerPeak=0, smallerRequests=0
        // Assembling + pending + current encode, with one spare. Bound includes
        // checked-out leases; a retaining consumer cannot grow memory forever.
        static let limit=4
        var counters:(UInt64,UInt64) { lock.withLock { (allocations,reuses) } }
        // Only sustained requests below half the previous capacity shrink the
        // spare set. Brief geometry changes keep CPU-saving reuse; no timer or
        // per-frame allocation. Checked-out leases are never touched.
        private var spareCeiling:Int { min(maxMessage,max(65536,preferredCapacity*2)) }
        private func demand(_ capacity:Int) {
            if capacity>preferredCapacity {
                preferredCapacity=capacity;smallerPeak=0;smallerRequests=0
            } else if capacity*2<preferredCapacity {
                smallerPeak=max(smallerPeak,capacity);smallerRequests+=1
                if smallerRequests>=64 {
                    preferredCapacity=smallerPeak;smallerPeak=0;smallerRequests=0
                    for i in spare.indices.reversed() where spare[i].capacity>spareCeiling {
                        spare.remove(at:i);slots-=1
                    }
                }
            } else { smallerPeak=0;smallerRequests=0 }
        }
        func take(_ count:Int)throws->Lease {
            try lock.withLock {
                let capacity=min(maxMessage,(count+65535) & ~65535)
                demand(capacity)
                if let i=spare.firstIndex(where:{$0.capacity>=count}) {
                    reuses &+= 1; return Lease(spare.remove(at:i),pool:self)
                }
                if !spare.isEmpty { spare.removeLast(); slots-=1 }
                guard slots<Self.limit else { throw WispError("Emulator raw message ownership exceeds bound") }
                let block=Block(capacity); slots+=1; allocations &+= 1
                return Lease(block,pool:self)
            }
        }
        func recycle(_ block:Block) {
            lock.withLock {
                // Last release can arrive from the encoder after downsizing.
                // Retire only that now-unused block, and release its slot.
                if block.capacity>spareCeiling { slots-=1 }
                else { spare.append(block) }
            }
        }
    }
    struct Bytes {
        fileprivate let lease:Lease?
        fileprivate let offset:Int
        let count:Int
        init() { lease=nil;offset=0;count=0 }
        fileprivate init(lease:Lease,offset:Int,count:Int) { self.lease=lease;self.offset=offset;self.count=count }
        // Convenience for small owned requests/fixtures. Production messages
        // arrive directly in pooled slabs and never take this copying path.
        fileprivate init(copying data:Data) {
            guard !data.isEmpty else { self.init();return }
            let block=Block(data.count)
            data.withUnsafeBytes { block.pointer.copyMemory(from:$0.baseAddress!,byteCount:data.count) }
            self.init(lease:Lease(block),offset:0,count:data.count)
        }
        var isEmpty:Bool { count==0 }
        subscript(_ i:Int)->UInt8 {
            precondition(i>=0 && i<count)
            return lease!.block.pointer.load(fromByteOffset:offset+i,as:UInt8.self)
        }
        func slice(_ range:Range<Int>)->Bytes {
            precondition(range.lowerBound>=0 && range.upperBound<=count)
            guard !range.isEmpty else { return Bytes() }
            return Bytes(lease:lease!,offset:offset+range.lowerBound,count:range.count)
        }
        // Data owns this lease through its deallocator. Never escape a pointer
        // from Data.withUnsafeBytes or assume a Foundation slice is zero-copy.
        var data:Data {
            guard let lease,!isEmpty else { return Data() }
            return Data(bytesNoCopy:lease.block.pointer.advanced(by:offset),count:count,
                        deallocator:.custom { [lease] _,_ in withExtendedLifetime(lease) {} })
        }
    }
    struct Frame { let bytes:Bytes,width:Int,height:Int,sequence:UInt64,timestampUS:UInt64;var active:Bool{!bytes.isEmpty} }
    struct Reader {
        let data:Bytes
        var offset=0,fields=0
        mutating func varint()throws->UInt64 {
            var result:UInt64=0
            for n in 0..<10 {
                guard offset<data.count else{throw WispError("Truncated emulator protobuf")}
                let b=data[offset];offset+=1
                guard n<9 || b<=1 else{throw WispError("Emulator protobuf integer overflow")}
                result |= UInt64(b&127) << (n*7)
                if b&128==0{return result}
            }
            throw WispError("Invalid emulator protobuf integer")
        }
        mutating func key()throws->(Int,Int) {
            fields+=1;guard fields<=128 else{throw WispError("Too many emulator protobuf fields")}
            let value=try varint();guard value>>3>0,value>>3<=0x1fffffff else{throw WispError("Invalid emulator protobuf tag")}
            return(Int(value>>3),Int(value&7))
        }
        mutating func bytes()throws->Bytes {
            let size=try varint();guard size<=UInt64(data.count-offset) else{throw WispError("Invalid emulator protobuf length")}
            let start=offset;offset+=Int(size);return data.slice(start..<offset)
        }
        mutating func skip(_ type:Int)throws {
            switch type {
            case 0:_ = try varint()
            case 1:guard offset+8<=data.count else{throw WispError("Truncated emulator fixed64")};offset+=8
            case 2:let size=try varint();guard size<=UInt64(data.count-offset) else{throw WispError("Truncated emulator field")};offset+=Int(size)
            case 5:guard offset+4<=data.count else{throw WispError("Truncated emulator fixed32")};offset+=4
            default:throw WispError("Unsupported emulator protobuf wire type")
            }
        }
    }
    static func uint(_ field:Int,_ value:UInt64)->Data {
        var result=Data(),n=UInt64(field<<3)
        repeat{let b=UInt8(n&127);n>>=7;result.append(b|(n>0 ? 128:0))}while n>0
        n=value;repeat{let b=UInt8(n&127);n>>=7;result.append(b|(n>0 ? 128:0))}while n>0
        return result
    }
    static func request(maxSize:Int)throws->Data {
        guard (8...maxEdge).contains(maxSize) else{throw WispError("Invalid raw capture size")}
        let proto=uint(1,1)+uint(3,UInt64(maxSize))+uint(4,UInt64(maxSize))
        var data=Data([0]);data.scrcpyAppend(UInt32(proto.count));data.append(proto);return data
    }
    static func image(_ data:Data,maxSize:Int)throws->Frame {
        guard data.count<=maxMessage else { throw WispError("Emulator raw message exceeds bounds") }
        return try image(Bytes(copying:data),maxSize:maxSize)
    }
    static func image(_ data:Bytes,maxSize:Int)throws->Frame {
        guard (8...maxEdge).contains(maxSize),data.count<=maxMessage else{throw WispError("Emulator raw message exceeds bounds")}
        var r=Reader(data:data),formatData:Bytes?,payload:Bytes?,sequence:UInt64=0,timestamp:UInt64=0,seen=Set<Int>()
        while r.offset<data.count {
            let(f,t)=try r.key()
            if [1,4,5,6].contains(f){guard seen.insert(f).inserted,(f==1 || f==4) ? t==2:t==0 else{throw WispError("Invalid or duplicate emulator image field")}}
            switch(f,t){case(1,2):formatData=try r.bytes();case(4,2):payload=try r.bytes();case(5,0):sequence=try r.varint();case(6,0):timestamp=try r.varint();default:try r.skip(t)}
        }
        guard sequence<=UInt64(UInt32.max) else{throw WispError("Invalid emulator raw sequence")}
        let pixels=payload ?? Bytes()
        guard pixels.isEmpty || formatData != nil else{throw WispError("Missing emulator raw format")}
        let format=formatData ?? Bytes()
        guard format.count<=65536 else{throw WispError("Emulator raw format exceeds bounds")}
        r=Reader(data:format);var kind:UInt64=0,width:UInt64=0,height:UInt64=0,display:UInt64=0;seen=[]
        while r.offset<format.count {
            let(f,t)=try r.key();if [1,3,4,5,6].contains(f){guard seen.insert(f).inserted,(f==6 ? t==2:t==0) else{throw WispError("Invalid or duplicate emulator format field")}}
            switch(f,t){case(1,0):kind=try r.varint();case(3,0):width=try r.varint();case(4,0):height=try r.varint();case(5,0):display=try r.varint();case(6,2):let transport=try r.bytes();guard transport.isEmpty || (transport.count==2 && transport[0]==8 && transport[1]==0) else{throw WispError("Emulator raw side channels are unsupported")};default:try r.skip(t)}
        }
        // Empty Image is the API inactivity notification, not cached pixels.
        if pixels.isEmpty{return Frame(bytes:Bytes(),width:0,height:0,sequence:sequence,timestampUS:timestamp)}
        guard kind==1,display==0,(8...UInt64(min(maxEdge,maxSize))).contains(width),(8...UInt64(min(maxEdge,maxSize))).contains(height),
              width*height*4<=UInt64(maxPixelBytes),pixels.count==Int(width*height*4),timestamp>0,timestamp<=UInt64(Int64.max) else{throw WispError("Invalid RGBA8888 emulator image dimensions or bytes")}
        return Frame(bytes:pixels,width:Int(width),height:Int(height),sequence:sequence,timestampUS:timestamp)
    }
    final class Messages {
        private let pool=SlabPool()
        private var header=[UInt8](repeating:0,count:5), headerCount=0
        private var expected:Int?, used=0, lease:Lease?
        private(set)var peakBytes=0
        var storageCounters:(UInt64,UInt64) { pool.counters }
        func append(_ data:Data,_ emit:(Bytes)throws->Void)throws {
            try data.withUnsafeBytes { try append($0,emit) }
        }
        func append(_ data:UnsafeRawBufferPointer,_ emit:(Bytes)throws->Void)throws {
            guard data.count<=65536 else { throw WispError("Emulator raw receive buffer exceeds bound") }
            var offset=0
            while offset<data.count {
                if expected==nil {
                    while headerCount<5 && offset<data.count {
                        header[headerCount]=data[offset];headerCount+=1;offset+=1
                    }
                    guard headerCount==5 else { break }
                    guard header[0]==0 else { throw WispError("Compressed gRPC raw images are unsupported") }
                    let n=header.dropFirst().reduce(0){($0<<8)|Int($1)}
                    guard n<=maxMessage else { throw WispError("Invalid gRPC raw image size") }
                    expected=n;used=0
                    if n==0 { expected=nil;headerCount=0;peakBytes=max(peakBytes,5);try emit(Bytes());continue }
                    lease=try pool.take(n)
                }
                let n=expected!, amount=min(n-used,data.count-offset)
                if amount>0 {
                    lease!.block.pointer.advanced(by:used).copyMemory(from:data.baseAddress!.advanced(by:offset),byteCount:amount)
                    used+=amount;offset+=amount;peakBytes=max(peakBytes,used+5)
                }
                if used==n {
                    let message=Bytes(lease:lease!,offset:0,count:n)
                    lease=nil;expected=nil;headerCount=0;used=0
                    try emit(message)
                }
            }
        }
    }
    struct Headers {
        private var pending=Data(),total=0
        private var status=false,contentType=false
        private(set)var ready=false
        mutating func append(_ data:Data)throws {
            total+=data.count;guard total<=65536,pending.count+data.count<=73728 else{throw WispError("Emulator raw headers exceed bounds")}
            pending.append(data)
            while let lf=pending.firstIndex(of:10) {
                let line=String(decoding:pending[..<lf],as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines);pending=Data(pending.suffix(from:pending.index(after:lf)))
                guard line.utf8.count<=8192 else{throw WispError("Emulator raw header line exceeds bound")}
                if line.hasPrefix("HTTP/"){guard line=="HTTP/2 200" else{throw WispError("Emulator raw HTTP/2 request rejected")};status=true}
                else if line.lowercased().hasPrefix("content-type:"){let value=line.dropFirst(13).trimmingCharacters(in:.whitespaces).lowercased();guard value=="application/grpc" || value.hasPrefix("application/grpc+") || value.hasPrefix("application/grpc;") else{throw WispError("Emulator raw content type rejected")};contentType=true}
                else if line.lowercased().hasPrefix("grpc-status:"){guard line.dropFirst(12).trimmingCharacters(in:.whitespaces)=="0" else{throw WispError("Emulator raw gRPC request rejected")}}
                if line.isEmpty && status && contentType{ready=true}
            }
            guard pending.count<=8192 else{throw WispError("Emulator raw header line exceeds bound")}
        }
    }
}
