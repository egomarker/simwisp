import Foundation
import CoreImage

// Synthetic bytes only. Exercise slab ownership independently of HTTP/2 timing.
func runRawStorageTests()throws->Int {
    var checks=0
    func check(_ ok:Bool,_ name:String)throws {guard ok else{throw WispError("Raw ownership: "+name)};checks+=1}
    func reject(_ name:String,_ body:()throws->Void)throws {do{try body()}catch{checks+=1;return};throw WispError("Raw ownership accepted "+name)}
    func packet(_ data:Data)->Data {var p=Data([0]);p.scrcpyAppend(UInt32(data.count));p.append(data);return p}
    func feed(_ parser:EmulatorRawWire.Messages,_ data:Data,_ size:Int=65536,_ emit:(EmulatorRawWire.Bytes)throws->Void)throws {
        try data.withUnsafeBytes { bytes in
            for offset in stride(from:0,to:bytes.count,by:size) {
                try parser.append(UnsafeRawBufferPointer(rebasing:bytes[offset..<min(bytes.count,offset+size)]),emit)
            }
        }
    }
    for chunk in [1,2,3,4,5,7,17,65536] {
        let parser=EmulatorRawWire.Messages()
        for n in 0..<40 {
            let bytes=Data(repeating:UInt8(n),count:257+(n%3)),p=packet(bytes)
            var count=0
            try feed(parser,p,chunk) { message in
                try check(message.data==bytes,"fragmented exact bytes \(chunk)/\(n)");count+=1
            }
            try check(count==1,"one message per packet")
        }
        try check(parser.storageCounters.0==1 && parser.storageCounters.1==39,"stable rounded slab reuse, including variable message sizes")
    }
    // A payload Data view survives both its message and later receive reuse.
    let parser=EmulatorRawWire.Messages()
    var held:Data?,heldSlice:EmulatorRawWire.Bytes?
    try feed(parser,packet(Data(repeating:41,count:200_000))) { message in
        held=message.data;heldSlice=message.slice(19..<199_999)
    }
    for _ in 0..<120 {
        try autoreleasepool {
            try feed(parser,packet(Data(repeating:82,count:200_000))) { message in
                try check(message[0]==82 && message[199_999]==82,"newly written slab contents")
            }
            try check(held?.first==41 && held?.last==41 && heldSlice?[0]==41,"retained views never overwritten")
        }
    }
    try check(parser.storageCounters.0==2 && parser.storageCounters.1==119,"held owner plus one reusable receive slab")
    held=nil;heldSlice=nil
    try feed(parser,packet(Data(repeating:99,count:300_000))) {_ in}
    try check(parser.storageCounters.0==3,"growth replaces an undersized free block")
    var survivor:Data?
    do {let temporary=EmulatorRawWire.Messages();try feed(temporary,packet(Data(repeating:123,count:1000))){survivor=$0.data}}
    try check(survivor==Data(repeating:123,count:1000),"payload owns storage after parser teardown");survivor=nil
    let bounded=EmulatorRawWire.Messages();var retained=[Data]()
    for n in 0..<4 {try feed(bounded,packet(Data(repeating:UInt8(n),count:1000))){retained.append($0.data)}}
    try reject("fifth checked-out slab") {try feed(bounded,packet(Data(repeating:255,count:1000))){_ in}}
    try check(retained.enumerated().allSatisfy{$0.element==Data(repeating:UInt8($0.offset),count:1000)},"bound failure does not overwrite existing owners")
    retained=[]
    let throwing=EmulatorRawWire.Messages()
    try reject("consumer failure") {try feed(throwing,packet(Data(repeating:1,count:1000))){_ in throw WispError("owned test consumer")}}
    try feed(throwing,packet(Data(repeating:2,count:1000))){try check($0[999]==2,"consumer error releases lease")}
    try check(throwing.storageCounters.0==1 && throwing.storageCounters.1==1,"error path returns slab")
    try reject("oversized read chunk") {try throwing.append(Data(repeating:0,count:65537)){_ in}}
    let empty=EmulatorRawWire.Messages();var empties=0
    try feed(empty,packet(Data())+packet(Data())+packet(Data()),1){try check($0.isEmpty,"empty frame");empties+=1}
    try check(empties==3 && empty.storageCounters.0==0,"inactive messages need no slab")
    // Last-release may occur on the encode queue, concurrent with acquisition.
    let concurrent=EmulatorRawWire.Messages(),group=DispatchGroup(),q=DispatchQueue(label:"raw-owned-release",attributes:.concurrent)
    for _ in 0..<50 {
        for value in 0..<3 {
            try feed(concurrent,packet(Data(repeating:UInt8(value),count:4096))) { bytes in
                let owned=bytes.data
                group.enter();q.async { withExtendedLifetime(owned) { _ = owned.last };group.leave() }
            }
        }
        try check(group.wait(timeout:.now()+2) == .success,"cross-queue last release joins")
    }
    try check(concurrent.storageCounters.0<=4 && concurrent.storageCounters.1>100,"cross-queue pool remains bounded")
    // Video buffers are immutable, encoder-scoped, bounded and independently owned.
    let e=try H264Encoder(width:9,height:11),other=try H264Encoder(width:9,height:11)
    defer{e.close();other.close()}
    let red=CIImage(color:CIColor(red:1,green:0,blue:0)).cropped(to:CGRect(x:0,y:0,width:9,height:11))
    var buffers=[H264Encoder.PreparedFrame]()
    for _ in 0..<3 {buffers.append(try e.prepare(red))}
    try withExtendedLifetime(buffers) {try reject("fourth live prepared pixel") {_ = try e.prepare(red)}}
    buffers=[]
    let cached=try e.prepare(red)
    try reject("foreign encoder prepared pixel") {_ = try other.encode(cached,quality:20,fps:60,forceKeyframe:true)}
    var last:UInt64=0
    for n in 0..<90 {
        let f=try e.encode(cached,quality:n%2==0 ? 1:20,fps:n%2==0 ? 60:30,forceKeyframe:n==0 || n==45)
        try check(f.timestamp>last && !f.payload.isEmpty,"new H264/PTS from one prepared buffer");last=f.timestamp
        try check(f.width==9 && f.height==11 && f.codedWidth==10 && f.codedHeight==12,"odd geometry/padding")
        if n==0 || n==45 {try check(f.keyframe,"cached-buffer recovery keyframe")}
    }
    e.close()
    try reject("closed encoder prepared pixel") {_ = try e.encode(cached,quality:20,fps:60,forceKeyframe:false)}
    try reject("closed encoder preparation") {_ = try e.prepare(red)}
    return checks
}
