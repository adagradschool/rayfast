// Test helper for scripts' image icons: write a solid-colour PNG, or count pixels of one colour in a snapshot PNG.
//   px make <out.png> <size> <r> <g> <b>      px count <in.png> <r> <g> <b>   (prints how many pixels are within 40 of it)
#import <Cocoa/Cocoa.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 7 && !strcmp(argv[1], "make")) {
            int n = atoi(argv[3]);
            NSBitmapImageRep *r = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:n pixelsHigh:n bitsPerSample:8 samplesPerPixel:4
                hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
            for (int y = 0; y < n; y++) for (int x = 0; x < n; x++) { NSUInteger p[4] = {atoi(argv[4]), atoi(argv[5]), atoi(argv[6]), 255}; [r setPixel:p atX:x y:y]; }
            return ![[r representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[2]) atomically:YES];
        }
        if (argc == 6 && !strcmp(argv[1], "count")) {
            NSBitmapImageRep *r = [NSBitmapImageRep imageRepWithData:[NSData dataWithContentsOfFile:@(argv[2])]];
            if (!r) return 1;
            int want[3] = {atoi(argv[3]), atoi(argv[4]), atoi(argv[5])}; long hits = 0;
            for (NSInteger y = 0; y < r.pixelsHigh; y++) for (NSInteger x = 0; x < r.pixelsWide; x++) {
                NSColor *c = [[r colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                int v[3] = {(int)(c.redComponent * 255), (int)(c.greenComponent * 255), (int)(c.blueComponent * 255)};
                if (abs(v[0] - want[0]) < 40 && abs(v[1] - want[1]) < 40 && abs(v[2] - want[2]) < 40) hits++;
            }
            printf("%ld\n", hits);
            return 0;
        }
        fprintf(stderr, "usage: px make out.png size r g b | px count in.png r g b\n");
        return 2;
    }
}
