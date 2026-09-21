// Persistent, stdin/stdout-only PDF raster worker for local macOS sessions.
// Requests and responses are one JSON object per line. No terminal graphics
// are emitted here: every output is an independent RGBA or PNG raster.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static void reply(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

@interface PixelTile : NSObject
@property(nonatomic, strong) NSData *pixels;
@property(nonatomic) NSUInteger width;
@property(nonatomic) NSUInteger height;
@property(nonatomic) uint64_t used;
@property(nonatomic, strong) id<MTLTexture> texture;
@end
@implementation PixelTile
@end

// This cache is independent of terminal placements. Fixed source-pixel tiles
// survive changes in the terminal-cell crop and, at the raster cap, in zoom.
// Surface entries retain textures only; raster entries retain CPU pixels.
// Their logical pixel costs share one LRU budget, independently of outputs.
static NSMutableDictionary<NSString *, PixelTile *> *pixelCache;
static NSUInteger cacheCost, cacheHits, cacheMisses;
static uint64_t cacheTick;
static const NSUInteger cacheLimit = 128 * 1024 * 1024;
static const NSInteger pixelTileSize = 2048;
static CGColorSpaceRef rasterColorSpace;

static NSData *allocatePixels(NSUInteger bytes) {
    void *data = malloc(bytes);
    return data ? [NSData dataWithBytesNoCopy:data length:bytes freeWhenDone:YES] : nil;
}

// Unmap the upload staging pixels explicitly: malloc can keep these large
// freed allocations resident after their contents have moved into a texture.
static NSData *allocateTransientPixels(NSUInteger bytes) {
    void *data = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (data == MAP_FAILED) return nil;
    return [[NSData alloc] initWithBytesNoCopy:data length:bytes deallocator:^(void *pointer, NSUInteger length) {
        munmap(pointer, length);
    }];
}

static NSData *mapOutput(NSString *file, NSUInteger bytes) {
    int descriptor = open(file.fileSystemRepresentation, O_RDWR | O_CREAT | O_TRUNC, 0600);
    if (descriptor < 0) return nil;
    if (ftruncate(descriptor, (off_t)bytes) != 0) {
        close(descriptor);
        return nil;
    }
    void *mapping = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0);
    if (mapping == MAP_FAILED) {
        close(descriptor);
        return nil;
    }
    // File readers share the same VM pages. No intermediate output buffer or
    // second pixel copy is needed before the terminal can read the raster.
    return [[NSData alloc] initWithBytesNoCopy:mapping length:bytes deallocator:^(void *data, NSUInteger length) {
        munmap(data, length);
        close(descriptor);
    }];
}

static NSString *draw(CGPDFPageRef page, NSInteger px, NSInteger py,
                      NSInteger x, NSInteger y, NSInteger width, NSInteger height, NSData *pixels) {
    CGContextRef context = CGBitmapContextCreate((void *)pixels.bytes, width, height, 8, width * 4,
                                                rasterColorSpace,
                                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!context) return @"Could not allocate raster";
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGContextTranslateCTM(context, -x, -(py - y - height));
    CGRect box = CGRectIntersection(CGPDFPageGetBoxRect(page, kCGPDFCropBox),
                                    CGPDFPageGetBoxRect(page, kCGPDFMediaBox));
    CGFloat pageWidth = box.size.width, pageHeight = box.size.height;
    if (CGRectIsEmpty(box) || !isfinite(pageWidth) || !isfinite(pageHeight)) {
        CGContextRelease(context);
        return @"Invalid PDF crop box";
    }
    if (CGPDFPageGetRotationAngle(page) % 180 != 0) {
        pageWidth = box.size.height;
        pageHeight = box.size.width;
    }
    // CGPDFPageGetDrawingTransform only scales down. Explicit scale preserves
    // the requested dimensions above the PDF's point size.
    CGContextScaleCTM(context, px / pageWidth, py / pageHeight);
    CGContextConcatCTM(context, CGPDFPageGetDrawingTransform(page, kCGPDFCropBox,
                          CGRectMake(0, 0, pageWidth, pageHeight), 0, false));
    CGContextClipToRect(context, CGPDFPageGetBoxRect(page, kCGPDFCropBox));
    CGContextDrawPDFPage(context, page);
    CGContextRelease(context);
    return nil;
}

static PixelTile *sourceTile(CGPDFDocumentRef document, NSInteger pageNumber, NSInteger px, NSInteger py,
                             NSInteger x, NSInteger y, NSInteger limit, BOOL forComposition, NSString **error) {
    NSString *key = [NSString stringWithFormat:@"%c:%ld:%ld:%ld:%ld:%ld:%ld",
                     forComposition ? 's' : 't', (long)pageNumber, (long)px, (long)py, (long)x, (long)y, (long)limit];
    PixelTile *tile = pixelCache[key];
    if (tile) {
        cacheHits++;
        tile.used = ++cacheTick;
        return tile;
    }
    cacheMisses++;
    tile = [PixelTile new];
    tile.width = MIN(limit, px - x);
    tile.height = MIN(limit, py - y);
    NSUInteger bytes = tile.width * tile.height * 4;
    tile.pixels = forComposition ? allocateTransientPixels(bytes) : allocatePixels(bytes);
    if (!tile.pixels) {
        *error = @"Could not allocate source tile";
        return nil;
    }
    *error = draw(CGPDFDocumentGetPage(document, pageNumber), px, py, x, y, tile.width, tile.height, tile.pixels);
    if (*error) return nil;
    tile.used = ++cacheTick;
    while (cacheCost + tile.pixels.length > cacheLimit && pixelCache.count) {
        NSString *oldest;
        uint64_t oldestTick = UINT64_MAX;
        for (NSString *candidate in pixelCache) {
            if (pixelCache[candidate].used < oldestTick) {
                oldest = candidate;
                oldestTick = pixelCache[candidate].used;
            }
        }
        PixelTile *evicted = pixelCache[oldest];
        cacheCost -= evicted.width * evicted.height * 4;
        [pixelCache removeObjectForKey:oldest];
    }
    pixelCache[key] = tile;
    cacheCost += tile.pixels.length;
    return tile;
}

static NSString *render(CGPDFDocumentRef document, NSDictionary *request) {
    for (NSString *key in @[@"page", @"px", @"py", @"x", @"y", @"width", @"height"]) {
        id value = request[key];
        if (![value isKindOfClass:[NSNumber class]] || !isfinite([value doubleValue]) ||
            [value doubleValue] != [value longLongValue]) return @"Invalid raster dimensions";
    }
    NSInteger pageNumber = [request[@"page"] integerValue];
    NSInteger px = [request[@"px"] integerValue], py = [request[@"py"] integerValue];
    NSInteger x = [request[@"x"] integerValue], y = [request[@"y"] integerValue];
    NSInteger width = [request[@"width"] integerValue], height = [request[@"height"] integerValue];
    NSString *file = request[@"file"];
    if (pageNumber < 1 || (size_t)pageNumber > CGPDFDocumentGetNumberOfPages(document) ||
        px < 1 || py < 1 || px > 16384 || py > 16384 || x < 0 || y < 0 ||
        width < 1 || height < 1 || width > px || height > py || x > px - width || y > py - height ||
        (uint64_t)width * height > 64 * 1024 * 1024 ||
        ![file isKindOfClass:[NSString class]] || !file.isAbsolutePath) return @"Invalid raster request";

    BOOL raw = [request[@"format"] isEqual:@32];
    NSData *pixels = raw ? mapOutput(file, (NSUInteger)width * height * 4)
                        : allocatePixels((NSUInteger)width * height * 4);
    if (!pixels) return @"Could not allocate output raster";
    // A direct path is useful for pixel-fidelity checks and renderer profiling.
    if ([request[@"cache"] isEqual:@NO]) {
        NSString *error = draw(CGPDFDocumentGetPage(document, pageNumber), px, py, x, y, width, height, pixels);
        if (error) return error;
    } else {
        for (NSInteger tileY = y / pixelTileSize * pixelTileSize; tileY < y + height; tileY += pixelTileSize) {
            for (NSInteger tileX = x / pixelTileSize * pixelTileSize; tileX < x + width; tileX += pixelTileSize) {
                @autoreleasepool {
                    NSString *error;
                    PixelTile *tile = sourceTile(document, pageNumber, px, py, tileX, tileY, pixelTileSize, NO, &error);
                    if (!tile) return error;
                    NSInteger left = MAX(x, tileX), top = MAX(y, tileY);
                    NSInteger right = MIN(x + width, tileX + (NSInteger)tile.width);
                    NSInteger bottom = MIN(y + height, tileY + (NSInteger)tile.height);
                    for (NSInteger row = top; row < bottom; row++) {
                        const unsigned char *source = (const unsigned char *)tile.pixels.bytes +
                            ((row - tileY) * tile.width + left - tileX) * 4;
                        unsigned char *target = (unsigned char *)pixels.bytes +
                            ((row - y) * width + left - x) * 4;
                        memcpy(target, source, (right - left) * 4);
                    }
                }
            }
        }
    }
    if (raw) return nil;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    if (!provider) return @"Could not create raster provider";
    CGImageRef image = CGImageCreate(width, height, 8, 32, width * 4, rasterColorSpace,
                        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big,
                        provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (!image) return @"Could not create raster image";
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:file], CFSTR("public.png"), 1, NULL);
    BOOL ok = NO;
    if (destination) {
        CGImageDestinationAddImage(destination, image, NULL);
        ok = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CGImageRelease(image);
    return ok ? nil : @"Could not write PNG";
}

static id<MTLDevice> composeDevice;
static BOOL surfaceAvailable(void) {
    if (!composeDevice) composeDevice = MTLCreateSystemDefaultDevice();
    if (@available(macOS 10.15, *)) return composeDevice && composeDevice.hasUnifiedMemory;
    return NO;
}
static BOOL numberInRange(id value, double minimum, double maximum, BOOL integer) {
    return [value isKindOfClass:[NSNumber class]] && isfinite([value doubleValue]) &&
        [value doubleValue] >= minimum && [value doubleValue] <= maximum &&
        (!integer || [value doubleValue] == [value longLongValue]);
}
static BOOL validSelections(id selections) {
    if (!selections) return YES;
    if (![selections isKindOfClass:[NSArray class]] || [selections count] > 8192) return NO;
    for (id rect in selections) {
        if (![rect isKindOfClass:[NSDictionary class]]) return NO;
        for (NSString *key in @[@"x1", @"y1", @"x2", @"y2"])
            if (!numberInRange(rect[key],-1e9,1e9,NO)) return NO;
        if ([rect[@"x2"] doubleValue] < [rect[@"x1"] doubleValue] ||
            [rect[@"y2"] doubleValue] < [rect[@"y1"] doubleValue]) return NO;
    }
    return YES;
}

// Tint only the selected pixels after rendering. Both motion and refinement
// use the same viewport coordinates; no terminal cursor or image z-order is involved.
static void applySelections(NSData *pixels, NSInteger width, NSInteger height, double offset, NSArray *selections) {
    unsigned char *data = (unsigned char *)pixels.bytes;
    for (NSDictionary *rect in selections) {
        NSInteger left = MAX(0, (NSInteger)floor([rect[@"x1"] doubleValue] - offset));
        NSInteger right = MIN(width, (NSInteger)ceil([rect[@"x2"] doubleValue] - offset));
        NSInteger top = MAX(0, (NSInteger)floor([rect[@"y1"] doubleValue]));
        NSInteger bottom = MIN(height, (NSInteger)ceil([rect[@"y2"] doubleValue]));
        for (NSInteger y = top; y < bottom; y++) {
            for (NSInteger x = left; x < right; x++) {
                unsigned char *pixel = data + (y * width + x) * 4;
                pixel[0] = (pixel[0] * 165 + 64 * 90 + 127) / 255;
                pixel[1] = (pixel[1] * 165 + 140 * 90 + 127) / 255;
                pixel[2] = (pixel[2] * 165 + 255 * 90 + 127) / 255;
            }
        }
    }
}
static NSUInteger pixelCacheBytes(void) {
    NSUInteger total = 0;
    for (PixelTile *tile in pixelCache.allValues) total += tile.pixels.length;
    return total;
}
static NSUInteger gpuCacheBytes(void) {
    NSUInteger total = 0;
    for (PixelTile *tile in pixelCache.allValues) if (tile.texture) total += tile.width * tile.height * 4;
    return total;
}

// Keep one untinted, final-resolution viewport for selection-only updates.
// It shares the refinement's 64 MiB pixel limit and is released on motion
// cancellation (worker exit) or replaced by the next refined viewport.
static NSArray<NSData *> *selectionPixels;
static NSArray *selectionParts, *selectionPages;
static NSString *selectionKey;
static NSUInteger selectionHeight, selectionBytes;

// Draw vectors directly at the final viewport pixel scale. Only visible
// output pixels are allocated, even when the full page is much larger.
static NSString *refine(CGPDFDocumentRef document, NSDictionary *request) {
    NSArray *pages = request[@"pages"], *parts = request[@"parts"];
    NSString *key = request[@"selection_cache"];
    BOOL reuse = [request[@"reuse"] isEqual:@YES];
    if (key && (![key isKindOfClass:[NSString class]] || key.length == 0 || key.length > 512))
        return @"Invalid selection cache key";
    if (!validSelections(request[@"selections"])) return @"Invalid selection rectangles";
    if (!numberInRange(request[@"height"],1,8192,YES) ||
        ![pages isKindOfClass:[NSArray class]] || pages.count < 1 || pages.count > 16 ||
        ![parts isKindOfClass:[NSArray class]] || parts.count < 1 || parts.count > 64)
        return @"Invalid refinement request";
    NSUInteger height = [request[@"height"] unsignedIntegerValue];
    uint64_t total = 0;
    NSMutableSet *files = [NSMutableSet set];
    for (NSDictionary *part in parts) {
        if (![part isKindOfClass:[NSDictionary class]] || !numberInRange(part[@"width"],1,8192,YES) ||
            !numberInRange(part[@"offset"],0,8192,YES) || ![part[@"file"] isKindOfClass:[NSString class]] ||
            ![part[@"file"] isAbsolutePath] || [files containsObject:part[@"file"]])
            return @"Invalid refinement output";
        [files addObject:part[@"file"]];
        total += [part[@"width"] unsignedLongLongValue] * height;
    }
    if (total > 16 * 1024 * 1024) return @"Refinement exceeds the viewport pixel budget";
    for (NSDictionary *page in pages) {
        if (![page isKindOfClass:[NSDictionary class]] ||
            !numberInRange(page[@"page"],1,CGPDFDocumentGetNumberOfPages(document),YES) ||
            !numberInRange(page[@"left"],-1e9,1e9,NO) || !numberInRange(page[@"top"],-1e9,1e9,NO) ||
            !numberInRange(page[@"width"],0.001,1e9,NO) || !numberInRange(page[@"height"],0.001,1e9,NO))
            return @"Invalid refinement page";
    }
    if (reuse) {
        if (!key || ![selectionKey isEqual:key] || height != selectionHeight ||
            parts.count != selectionParts.count || ![pages isEqual:selectionPages])
            return @"Refined selection cache is unavailable";
        for (NSUInteger i = 0; i < parts.count; i++) {
            if (![parts[i][@"width"] isEqual:selectionParts[i][@"width"]] ||
                ![parts[i][@"offset"] isEqual:selectionParts[i][@"offset"]])
                return @"Refined selection geometry changed";
        }
    } else {
        selectionPixels = nil;
        selectionParts = selectionPages = nil;
        selectionKey = nil;
        selectionBytes = 0;
    }
    NSMutableArray<NSData *> *clean = [NSMutableArray array];
    for (NSUInteger index = 0; index < parts.count; index++) {
        NSDictionary *part = parts[index];
        NSUInteger width = [part[@"width"] unsignedIntegerValue];
        NSUInteger bytes = width * height * 4;
        NSData *output = mapOutput(part[@"file"], bytes);
        if (!output) return @"Could not allocate refinement output";
        if (reuse) {
            memcpy((void *)output.bytes, selectionPixels[index].bytes, bytes);
            applySelections(output,width,height,[part[@"offset"] doubleValue],request[@"selections"]);
            continue;
        }
        NSData *pixels = key ? allocateTransientPixels(bytes) : output;
        if (!pixels) return @"Could not allocate refinement output";
        CGContextRef context = CGBitmapContextCreate((void *)pixels.bytes, width, height, 8, width * 4,
            rasterColorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        if (!context) return @"Could not create refinement context";
        CGContextSetRGBFillColor(context,32.0/255,36.0/255,44.0/255,1);
        CGContextFillRect(context,CGRectMake(0,0,width,height));
        for (NSDictionary *item in pages) {
            CGPDFPageRef page = CGPDFDocumentGetPage(document,[item[@"page"] integerValue]);
            CGRect box = CGRectIntersection(CGPDFPageGetBoxRect(page,kCGPDFCropBox),
                                             CGPDFPageGetBoxRect(page,kCGPDFMediaBox));
            CGFloat pageWidth = box.size.width, pageHeight = box.size.height;
            if (CGRectIsEmpty(box) || !isfinite(pageWidth) || !isfinite(pageHeight)) {
                CGContextRelease(context);
                return @"Invalid refinement crop box";
            }
            if (CGPDFPageGetRotationAngle(page) % 180 != 0) {
                pageWidth = box.size.height;
                pageHeight = box.size.width;
            }
            CGFloat drawnWidth = [item[@"width"] doubleValue], drawnHeight = [item[@"height"] doubleValue];
            CGRect target = CGRectMake([item[@"left"] doubleValue] - [part[@"offset"] doubleValue],
                height - [item[@"top"] doubleValue] - drawnHeight, drawnWidth, drawnHeight);
            CGContextSaveGState(context);
            CGContextClipToRect(context,target);
            CGContextSetRGBFillColor(context,1,1,1,1);
            CGContextFillRect(context,target);
            CGContextTranslateCTM(context,target.origin.x,target.origin.y);
            CGContextScaleCTM(context,drawnWidth/pageWidth,drawnHeight/pageHeight);
            CGContextConcatCTM(context,CGPDFPageGetDrawingTransform(page,kCGPDFCropBox,
                CGRectMake(0,0,pageWidth,pageHeight),0,false));
            CGContextClipToRect(context,CGPDFPageGetBoxRect(page,kCGPDFCropBox));
            CGContextDrawPDFPage(context,page);
            CGContextRestoreGState(context);
        }
        CGContextRelease(context);
        if (key) {
            [clean addObject:pixels];
            memcpy((void *)output.bytes, pixels.bytes, bytes);
        }
        applySelections(output,width,height,[part[@"offset"] doubleValue],request[@"selections"]);
    }
    if (key && !reuse) {
        selectionPixels = clean;
        selectionParts = parts;
        selectionPages = pages;
        selectionKey = key;
        selectionHeight = height;
        selectionBytes = total * 4;
    }
    return nil;
}
static id<MTLCommandQueue> composeQueue;
static id<MTLComputePipelineState> composePipeline;


@interface CompositionTarget : NSObject
@property(nonatomic, strong) NSData *pixels;
@property(nonatomic, strong) id<MTLBuffer> buffer;
@property(nonatomic) dev_t device;
@property(nonatomic) ino_t inode;
@property(nonatomic) uint64_t used;
@end
@implementation CompositionTarget
@end
static NSMutableDictionary<NSString *, CompositionTarget *> *outputTargets;
static NSUInteger outputBytes;
static uint64_t outputTick;
static const NSUInteger outputLimit = 64 * 1024 * 1024;

static void forgetOutput(NSString *file) {
    CompositionTarget *target = outputTargets[file];
    if (target) {
        outputBytes -= target.buffer.length;
        [outputTargets removeObjectForKey:file];
    }
}

// The client owns paths and waits for terminal read confirmation before
// submitting another write to either retained output generation.
static CompositionTarget *outputTarget(NSString *file, NSUInteger bytes, NSSet *protected) {
    if (!outputTargets) outputTargets = [NSMutableDictionary dictionary];
    CompositionTarget *target = outputTargets[file];
    struct stat current;
    if (target && target.pixels.length == bytes && lstat(file.fileSystemRepresentation, &current) == 0 &&
        S_ISREG(current.st_mode) && current.st_size == (off_t)bytes &&
        current.st_dev == target.device && current.st_ino == target.inode) {
        target.used = ++outputTick;
        return target;
    }
    forgetOutput(file);
    NSUInteger pageSize = getpagesize(), capacity = (bytes + pageSize - 1) / pageSize * pageSize;
    while (outputBytes + capacity > outputLimit) {
        NSString *oldest = nil;
        uint64_t tick = UINT64_MAX;
        for (NSString *candidate in outputTargets) {
            if (![protected containsObject:candidate] && outputTargets[candidate].used < tick) {
                oldest = candidate;
                tick = outputTargets[candidate].used;
            }
        }
        if (!oldest) return nil;
        forgetOutput(oldest);
    }
    NSData *pixels = mapOutput(file, bytes);
    if (!pixels || lstat(file.fileSystemRepresentation, &current) != 0 || !S_ISREG(current.st_mode) ||
        current.st_size != (off_t)bytes) return nil;
    id<MTLBuffer> buffer = [composeDevice newBufferWithBytesNoCopy:(void *)pixels.bytes length:capacity
        options:MTLResourceStorageModeShared
        deallocator:^(void *pointer, NSUInteger length) { (void)pointer; (void)length; (void)[pixels bytes]; }];
    if (!buffer) return nil;
    target = [CompositionTarget new];
    target.pixels = pixels;
    target.buffer = buffer;
    target.device = current.st_dev;
    target.inode = current.st_ino;
    target.used = ++outputTick;
    outputTargets[file] = target;
    outputBytes += capacity;
    return target;
}

static NSString *compose(CGPDFDocumentRef document, NSDictionary *request) {
    // Validate the entire request before allocating files or encoding GPU work.
    NSArray *pages = request[@"pages"], *parts = request[@"parts"];
    if (!validSelections(request[@"selections"])) return @"Invalid selection rectangles";
    if (!numberInRange(request[@"height"], 1, 8192, YES) ||
        ![pages isKindOfClass:[NSArray class]] || pages.count < 1 || pages.count > 16 ||
        ![parts isKindOfClass:[NSArray class]] || parts.count < 1 || parts.count > 64)
        return @"Invalid viewport request";
    uint64_t pixelsTotal = 0;
    NSMutableSet *outputFiles = [NSMutableSet set];
    for (NSDictionary *part in parts) {
        if (![part isKindOfClass:[NSDictionary class]] || !numberInRange(part[@"width"],1,8192,YES) ||
            !numberInRange(part[@"offset"],0,8192,YES) ||
            ![part[@"file"] isKindOfClass:[NSString class]] || ![part[@"file"] isAbsolutePath])
            return @"Invalid viewport part";
        if ([outputFiles containsObject:part[@"file"]]) return @"Duplicate viewport output";
        [outputFiles addObject:part[@"file"]];
        pixelsTotal += [part[@"width"] unsignedLongLongValue] * [request[@"height"] unsignedLongLongValue];
    }
    if (pixelsTotal > 8 * 1024 * 1024) return @"Viewport exceeds the composition pixel budget";
    for (NSDictionary *page in pages) {
        if (![page isKindOfClass:[NSDictionary class]] ||
            !numberInRange(page[@"page"],1,CGPDFDocumentGetNumberOfPages(document),YES) ||
            !numberInRange(page[@"px"],1,4096,YES) || !numberInRange(page[@"py"],1,4096,YES) ||
            !numberInRange(page[@"left"],-1e9,1e9,NO) || !numberInRange(page[@"top"],-1e9,1e9,NO) ||
            !numberInRange(page[@"width"],0.001,1e9,NO) || !numberInRange(page[@"height"],0.001,1e9,NO))
            return @"Invalid viewport page";
    }
    if (!surfaceAvailable()) return @"Metal viewport composition is unavailable";
    if (!composePipeline) {
        composeQueue = [composeDevice newCommandQueue];
        if (!composeQueue) return @"Could not create a Metal command queue";
        NSError *error;
        NSString *code =
            @"#include <metal_stdlib>\n"
            @"using namespace metal;\n"
            @"struct Page { float2 origin; float2 size; };\n"
            @"struct Layout { uint width; uint height; uint count; uint padding; Page pages[16]; };\n"
            @"kernel void compose_main(device uchar4 *output [[buffer(0)]], constant Layout &layout [[buffer(1)]], array<texture2d<float>,16> sources [[texture(0)]], uint2 point [[thread_position_in_grid]]) {\n"
            @"    if (point.x >= layout.width || point.y >= layout.height) return;\n"
            @"    float4 color = float4(32.0/255,36.0/255,44.0/255,1);\n"
            @"    constexpr sampler filtering(coord::normalized,filter::linear,address::clamp_to_edge);\n"
            @"    for (uint i=0; i<layout.count; i++) {\n"
            @"        float2 uv=(float2(point)+0.5-layout.pages[i].origin)/layout.pages[i].size;\n"
            @"        if (all(uv>=0.0) && all(uv<1.0)) { color=sources[i].sample(filtering,uv); break; }\n"
            @"    }\n"
            @"    output[point.y*layout.width+point.x]=uchar4(round(clamp(color,0.0,1.0)*255.0));\n"
            @"}\n";
        id<MTLLibrary> library = [composeDevice newLibraryWithSource:code options:nil error:&error];
        if (!library) return error.localizedDescription;
        composePipeline = [composeDevice newComputePipelineStateWithFunction:[library newFunctionWithName:@"compose_main"] error:&error];
        if (!composePipeline) return error.localizedDescription;
    }
    NSInteger height = [request[@"height"] integerValue];
    if (height < 1 || height > 8192) return @"Invalid viewport height";
    NSMutableArray<PixelTile *> *sources = [NSMutableArray array];
    for (NSDictionary *page in request[@"pages"]) {
        NSInteger n = [page[@"page"] integerValue];
        NSInteger px = [page[@"px"] integerValue], py = [page[@"py"] integerValue];
        if (n < 1 || (size_t)n > CGPDFDocumentGetNumberOfPages(document) || px < 1 || py < 1 || px > 4096 || py > 4096) return @"Invalid source page";
        NSString *error;
        PixelTile *tile = sourceTile(document, n, px, py, 0, 0, MAX(px,py), YES, &error);
        if (!tile) return error;
        if (!tile.texture) {
            MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:tile.width height:tile.height mipmapped:NO];
            desc.storageMode = MTLStorageModeShared;
            desc.usage = MTLTextureUsageShaderRead;
            tile.texture = [composeDevice newTextureWithDescriptor:desc];
            if (!tile.texture) return @"Could not allocate source texture";
            [tile.texture replaceRegion:MTLRegionMake2D(0,0,tile.width,tile.height) mipmapLevel:0 withBytes:tile.pixels.bytes bytesPerRow:tile.width*4];
            // The texture owns the copied pixels. Keep one source backing per
            // cache entry; raster tiles use a separate key and retain CPU data.
            tile.pixels = nil;
        }
        [sources addObject:tile];
    }

    if (sources.count < 1 || sources.count > 16) return @"Composition supports 1 to 16 visible pages";
    id<MTLCommandBuffer> command = [composeQueue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    if (!command || !encoder) return @"Could not create a Metal command encoder";
    [encoder setComputePipelineState:composePipeline];
    for (NSUInteger i=0; i<16; i++) [encoder setTexture:sources[MIN(i,sources.count-1)].texture atIndex:i];
    NSString *failure;
    for (NSDictionary *part in request[@"parts"]) {
        NSInteger width = [part[@"width"] integerValue];
        CGFloat offset = [part[@"offset"] doubleValue];
        NSUInteger bytes = width * height * 4, pageSize = getpagesize();
        CompositionTarget *output = outputTarget(part[@"file"], bytes, outputFiles);
        if (!output) { failure = @"Could not allocate bounded composition output"; break; }
        NSData *pixels = output.pixels;
        id<MTLBuffer> target = output.buffer;
        // CPU-dirty every VM page before each GPU write, including reuse.
        for (NSUInteger i=0; i<bytes; i+=pageSize) ((volatile unsigned char *)pixels.bytes)[i]=0;
        struct Page { vector_float2 origin, size; };
        struct { uint32_t width, height, count, padding; struct Page pages[16]; } layout = {0};
        layout.width=(uint32_t)width; layout.height=(uint32_t)height; layout.count=(uint32_t)sources.count;
        for (NSUInteger i=0; i<sources.count; i++) {
            NSDictionary *page=request[@"pages"][i];
            layout.pages[i].origin=(vector_float2){[page[@"left"] floatValue]-offset,[page[@"top"] floatValue]};
            layout.pages[i].size=(vector_float2){[page[@"width"] floatValue],[page[@"height"] floatValue]};
        }
        [encoder setBuffer:target offset:0 atIndex:0];
        [encoder setBytes:&layout length:sizeof(layout) atIndex:1];
        [encoder dispatchThreads:MTLSizeMake(width,height,1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];
    }
    [encoder endEncoding];
    if (failure) return failure;
    [command commit];
    [command waitUntilCompleted];
    if (command.status==MTLCommandBufferStatusError) return command.error.localizedDescription;
    for (NSDictionary *part in parts)
        applySelections(outputTargets[part[@"file"]].pixels,[part[@"width"] integerValue],height,
                        [part[@"offset"] doubleValue],request[@"selections"]);
    return nil;
}

static NSArray *pageGeometry(CGPDFDocumentRef document) {
    size_t count = CGPDFDocumentGetNumberOfPages(document);
    if (count == 0 || count > 100000) return nil;
    NSMutableArray *pages = [NSMutableArray arrayWithCapacity:count];
    for (size_t index = 1; index <= count; index++) {
        CGPDFPageRef page = CGPDFDocumentGetPage(document, index);
        if (!page) return nil;
        CGRect box = CGRectIntersection(CGPDFPageGetBoxRect(page, kCGPDFCropBox),
                                        CGPDFPageGetBoxRect(page, kCGPDFMediaBox));
        CGFloat width = box.size.width, height = box.size.height;
        if (CGRectIsEmpty(box) || !isfinite(width) || !isfinite(height)) return nil;
        if (CGPDFPageGetRotationAngle(page) % 180 != 0) {
            width = box.size.height;
            height = box.size.width;
        }
        [pages addObject:@{ @"width": @(width), @"height": @(height) }];
    }
    return pages;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--version") == 0) {
            puts("pdfpreview-native protocol 3");
            return 0;
        }
        if (argc != 2) {
            fputs("Usage: pdfpreview-native /absolute/path/to/document.pdf\n", stderr);
            return 2;
        }
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        CGPDFDocumentRef document = CGPDFDocumentCreateWithURL((__bridge CFURLRef)url);
        if (!document || !CGPDFDocumentIsUnlocked(document)) {
            fputs("Could not open PDF, or a password is required\n", stderr);
            if (document) CGPDFDocumentRelease(document);
            return 1;
        }
        pixelCache = [NSMutableDictionary dictionary];
        rasterColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        char *line = NULL;
        size_t capacity = 0;
        ssize_t length;
        while ((length = getline(&line, &capacity, stdin)) > 0) {
            @autoreleasepool {
                NSData *data = [NSData dataWithBytes:line length:length];
                id request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (![request isKindOfClass:[NSDictionary class]] ||
                    ![request[@"id"] isKindOfClass:[NSNumber class]]) {
                    reply(@{ @"id": @0, @"error": @"Invalid JSON request" });
                    continue;
                }
                CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
                if ([request[@"action"] isEqual:@"info"]) {
                    NSArray *pages = pageGeometry(document);
                    if (pages) reply(@{ @"id": request[@"id"], @"protocol": @3, @"pages": pages, @"surface": @(surfaceAvailable()), @"cache_bytes": @(pixelCacheBytes()), @"gpu_cache_bytes": @(gpuCacheBytes()), @"output_cache_bytes": @(outputBytes), @"selection_cache_bytes": @(selectionBytes) });
                    else reply(@{ @"id": request[@"id"], @"error": @"Invalid or excessive PDF page geometry" });
                    continue;
                }
                NSUInteger hits = cacheHits, misses = cacheMisses;
                BOOL composition = [request[@"action"] isEqual:@"compose"];
                if (!composition) { [outputTargets removeAllObjects]; outputBytes = 0; }
                NSString *error = composition ? compose(document, request) :
                    [request[@"action"] isEqual:@"refine"] ? refine(document, request) : render(document, request);
                if (error) reply(@{ @"id": request[@"id"], @"error": error });
                else reply(@{ @"id": request[@"id"], @"render_ms": @((CFAbsoluteTimeGetCurrent() - start) * 1000),
                              @"cache_hits": @(cacheHits - hits), @"cache_misses": @(cacheMisses - misses),
                              @"cache_bytes": @(pixelCacheBytes()), @"gpu_cache_bytes": @(gpuCacheBytes()), @"output_cache_bytes": @(outputBytes), @"selection_cache_bytes": @(selectionBytes) });
            }
        }
        free(line);
        outputTargets = nil;
        pixelCache = nil;
        selectionPixels = nil;
        CGColorSpaceRelease(rasterColorSpace);
        CGPDFDocumentRelease(document);
    }
    return 0;
}
