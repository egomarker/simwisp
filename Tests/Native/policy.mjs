import fs from 'node:fs';
import assert from 'node:assert/strict';
const app=fs.readFileSync('Resources/Web/js/app.js','utf8'),stream=fs.readFileSync('Sources/Streams.swift','utf8');
assert.match(app,/IOSCapture/,'iOS has an explicit capture selector (Native / Mac window)');
assert.match(stream,/IOSCaptureMode/,'Native is admitted only by iOS policy, not Android fallback');
console.log('Native iOS integration policy checks passed');

const capture=fs.readFileSync('Sources/NativeCapture.swift','utf8');
assert(capture.indexOf('let lease=acquire(layout)')<capture.indexOf('IOSurfaceLock(surface,.readOnly'), 'owned allocation precedes producer read lock');
assert(capture.indexOf('IOSurfaceUnlock(surface,.readOnly')<capture.indexOf('if format==0x42475258'), 'alpha normalization touches owned bytes after unlock');
assert(!capture.includes('Data(count:'), 'Native does not zero-allocate a full Data on every poll');
assert.match(capture,/static let limit=3/, 'snapshot leases have a finite global per-capture limit');

// Owner23:02: no timed/background/per-frame metadata discovery while healthy.
const runtime=fs.readFileSync('Sources/NativeRuntime.swift','utf8');
assert(!/nextRefresh|portIdentities|clock\(|DispatchQueue|DispatchSource|Timer[.(]/.test(runtime),'discovery has no expiry clock, topology polling or background audit');
const acquisition=runtime.slice(runtime.indexOf('    func surface() throws -> IOSurface? {'));
assert.match(acquisition,/if !discovered \{/,'only an invalid discovery state resolves IO metadata');
const beforePlanes=acquisition.slice(0,acquisition.indexOf('// Xcode exposes main'));
assert.match(beforePlanes,/NativeInvoke\.update\(io\)/,'explicit discovery still updates ports');
assert.match(beforePlanes,/NativeInvoke\.objects\(io,"deviceIOPorts"\)/,'explicit discovery still admits checked inventory');
assert.match(acquisition,/for entry in portMetadata\.values/,'healthy acquisition uses only discovered bindings');
assert.match(acquisition,/NativeInvoke\.object\(descriptor,name\)/,'current surface remains checked and live');
assert.match(acquisition,/catch \{clearMetadata\(\);throw error\}/,'real errors release discovery and propagate without hidden retry');
assert.match(acquisition,/if largest == nil \{clearMetadata\(\)\}/,'true unavailability invalidates discovery');
assert.match(acquisition,/func close\(\) \{ closed=true;clearMetadata\(\);io=nil;device=nil \}/,'close releases source metadata and IO ownership');
console.log('Native error-driven/no-polling discovery policy checks passed');

// Finalized Native backend ships no temporary trace collectors or controls.
for (const file of ['Sources/NativeFrameTiming.swift','Resources/Web/js/browser-trace.js','Resources/Web/js/browser-trace-ui.js']) {
    assert(!fs.existsSync(file), `temporary diagnostic implementation removed: ${file}`);
}
for (const file of ['Sources/NativeCapture.swift','Sources/Streams.swift','Sources/Service.swift','Resources/Web/js/stream.js','Resources/Web/js/app.js','Resources/Web/index.html']) {
    assert(!/NativeFrameTiming|native-frame-times|browserTrace|TraceEvent|traceCapture|browser-trace|traceGeneration|latestTraceGeneration/.test(fs.readFileSync(file,'utf8')), `no diagnostic hooks remain in ${file}`);
}
assert(!/Native \(experimental\)/.test(fs.readFileSync('Resources/Web/js/ios-capture.js','utf8')), 'accepted Native backend is not labeled experimental');
console.log('Finalized Native diagnostic-removal policy checks passed');
