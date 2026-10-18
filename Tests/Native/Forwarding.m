#import <Foundation/Foundation.h>

// Inert stand-in for an Objective-C/XPC proxy. Its getters have no concrete
// Method/IMP on this class: dispatch is through a checked method signature and
// NSInvocation. No private frameworks, simulator connection or device access.
@interface NativeTestForwarder : NSObject
@property(nonatomic,strong) NSObject *target;
+ (NSObject *)wrap:(NSObject *)target;
@end
@implementation NativeTestForwarder
+ (NSObject *)wrap:(NSObject *)target {
    NativeTestForwarder *proxy = [self new]; proxy.target = target; return proxy;
}
- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.target respondsToSelector:selector];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    return [super methodSignatureForSelector:selector] ?: [self.target methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    [invocation invokeWithTarget:self.target];
}
@end
