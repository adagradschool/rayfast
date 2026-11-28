// A test window for run.sh item 9: one resizable window titled "rayfast-test-window", fully transparent and click-through
// (it never shows or takes a click), never activated (accessory app, orderFrontRegardless). Prints its pid when ready;
// quits by itself after 10 s so a broken test can't leave it behind.
#import <AppKit/AppKit.h>
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSRect v = NSScreen.screens[0].visibleFrame;
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(v.origin.x + 100, v.origin.y + 100, 400, 300)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        w.title = @"rayfast-test-window"; w.alphaValue = 0; w.ignoresMouseEvents = YES; w.releasedWhenClosed = NO;
        w.animationBehavior = NSWindowAnimationBehaviorNone;
        [w orderFrontRegardless];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ printf("%d\n", getpid()); fflush(stdout); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(0); });
        [NSApp run];
    }
    return 0;
}
