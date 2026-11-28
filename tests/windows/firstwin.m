// Prints "pid:windownumber" of the first window in the window list (read-only), for run.sh's restore liveness test.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
int main(void) {
    NSArray *a = (__bridge_transfer NSArray *)CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    NSDictionary *d = a.firstObject;
    if (!d) return 1;
    printf("%d:%d\n", [d[(id)kCGWindowOwnerPID] intValue], [d[(id)kCGWindowNumber] intValue]);
    return 0;
}
