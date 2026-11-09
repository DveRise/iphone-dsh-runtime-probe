// SPDX-License-Identifier: GPL-3.0-only
// Screen capture approach derived from ZXTouch Rootless v1.0.1 (GPL-3.0).
#import <UIKit/UIKit.h>
#import <IOSurface/IOSurface.h>
#import <Vision/Vision.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include "ProbeProtocol.h"

@interface UIApplication (HarnessFrontmostApplication)
- (id)_accessibilityFrontMostApplication;
- (int)_frontMostAppOrientation;
@end

@interface NSObject (HarnessFrontmostBundle)
- (NSString *)bundleIdentifier;
@end

typedef void (*RenderDisplay)(int, CFStringRef, IOSurfaceRef, int, int);
typedef CGImageRef (*ImageFromSurface)(IOSurfaceRef);

// Capture only the portrait Settings screen. Check before and after the capture
// on SpringBoard's main queue so a switch cannot be interleaved with the request.
static CGImageRef CopySettingsFrame(void) {
    __block CGImageRef frame = NULL;
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIApplication *springBoard = UIApplication.sharedApplication;
        if (![springBoard respondsToSelector:@selector(_accessibilityFrontMostApplication)]
            || ![springBoard respondsToSelector:@selector(_frontMostAppOrientation)]
            || [springBoard _frontMostAppOrientation] != UIInterfaceOrientationPortrait) return;
        id front = [springBoard _accessibilityFrontMostApplication];
        if (![front respondsToSelector:@selector(bundleIdentifier)]
            || ![[front bundleIdentifier] isEqualToString:@"com.apple.Preferences"]) return;

        RenderDisplay render = (RenderDisplay)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        ImageFromSurface makeImage = (ImageFromSurface)dlsym(RTLD_DEFAULT, "UICreateCGImageFromIOSurface");
        if (!render || !makeImage) return;

        CGSize native = UIScreen.mainScreen.nativeBounds.size;
        size_t width = (size_t)native.width, height = (size_t)native.height;
        if (!width || height <= width || width > 2048 || height > 4096) return;
        size_t rowBytes = (width * 4 + 31) & ~(size_t)31;
        NSDictionary *properties = @{
            (__bridge NSString *)kIOSurfaceWidth: @(width),
            (__bridge NSString *)kIOSurfaceHeight: @(height),
            (__bridge NSString *)kIOSurfaceBytesPerElement: @4,
            (__bridge NSString *)kIOSurfaceBytesPerRow: @(rowBytes),
            (__bridge NSString *)kIOSurfaceAllocSize: @(rowBytes * height),
            (__bridge NSString *)kIOSurfacePixelFormat: @((uint32_t)0x42475241),
            @"IOSurfaceIsGlobal": @YES,
        };
        IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
        if (!surface) return;
        if (IOSurfaceLock(surface, 0, NULL) == 0) {
            render(0, CFSTR("LCD"), surface, 0, 0);
            id stillFront = [springBoard _accessibilityFrontMostApplication];
            if ([stillFront respondsToSelector:@selector(bundleIdentifier)]
                && [[stillFront bundleIdentifier] isEqualToString:@"com.apple.Preferences"]
                && [springBoard _frontMostAppOrientation] == UIInterfaceOrientationPortrait) {
                frame = makeImage(surface);
            }
            IOSurfaceUnlock(surface, 0, NULL);
        }
        CFRelease(surface);
    });
    return frame;
}

static NSData *RecognizeSettings(CGImageRef image) {
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.recognitionLanguages = @[@"zh-Hans", @"en-US"];
    request.usesLanguageCorrection = YES;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    if (![handler performRequests:@[request] error:nil]) return nil;

    // Report recognition of known labels only. Do not return account names or
    // other text that may be visible in Settings.
    NSArray<NSString *> *labels = @[@"设置", @"通用", @"关于本机", @"显示与亮度",
                                    @"Settings", @"General", @"About", @"Display & Brightness"];
    NSMutableOrderedSet<NSString *> *matches = [NSMutableOrderedSet orderedSet];
    for (VNRecognizedTextObservation *item in request.results) {
        NSString *candidate = [item topCandidates:1].firstObject.string;
        if (candidate && [labels containsObject:candidate]) [matches addObject:candidate];
    }
    return [NSJSONSerialization dataWithJSONObject:@{@"recognizedLabels":matches.array} options:0 error:nil];
}

static BOOL SendBytes(int fd, const void *data, size_t length) {
    const char *bytes = data;
    while (length) {
        ssize_t written = send(fd, bytes, length, 0);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return NO;
        bytes += written;
        length -= (size_t)written;
    }
    return YES;
}

static void Reply(int fd, const char *contentType, NSData *data) {
    if (!data || data.length > 4 * 1024 * 1024) {
        const char error[] = "-1;;Capture or encoding unavailable\r\n";
        SendBytes(fd, error, sizeof(error) - 1);
        return;
    }
    char header[96];
    int count = snprintf(header, sizeof(header), "0;;%s;;%zu\r\n", contentType, (size_t)data.length);
    if (count > 0 && (size_t)count < sizeof(header) && SendBytes(fd, header, (size_t)count)) {
        SendBytes(fd, data.bytes, data.length);
    }
}

static void ServeOnce(int fd) {
    char request[4];
    size_t offset = 0;
    while (offset < sizeof(request)) {
        ssize_t count = recv(fd, request + offset, sizeof(request) - offset, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return;
        offset += (size_t)count;
    }
    enum ProbeCommand command = ProbeParse(request, sizeof(request));
    if (command == ProbeStatus) {
        Reply(fd, "application/json", [@"{\"ready\":true,\"captureScope\":\"portrait Settings\"}"
             dataUsingEncoding:NSUTF8StringEncoding]);
        return;
    }
    if (command == ProbeInvalid) return;

    CGImageRef frame = CopySettingsFrame();
    if (!frame) {
        const char error[] = "-1;;Open Settings in portrait, or screen capture is unavailable\r\n";
        SendBytes(fd, error, sizeof(error) - 1);
        return;
    }
    @try {
        NSData *result = command == ProbeRecognize ? RecognizeSettings(frame)
            : [NSJSONSerialization dataWithJSONObject:@{
                @"width": @(CGImageGetWidth(frame)), @"height": @(CGImageGetHeight(frame))
            } options:0 error:nil];
        Reply(fd, "application/json", result);
    } @finally {
        CGImageRelease(frame);
    }
}

static void RunProbe(void) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) return;
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(PROBE_PORT);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(listener, 2) != 0) {
        close(listener);
        return;
    }
    for (;;) {
        struct sockaddr_in peer = {0};
        socklen_t peerSize = sizeof(peer);
        int client = accept(listener, (struct sockaddr *)&peer, &peerSize);
        if (client < 0) { if (errno == EINTR) continue; break; }
        if (peer.sin_family == AF_INET && peer.sin_addr.s_addr == htonl(INADDR_LOOPBACK)) {
            struct timeval timeout = { 2, 0 };
            int yes = 1;
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
            @autoreleasepool {
                @try { ServeOnce(client); }
                @catch (NSException *exception) { (void)exception; }
            }
        }
        close(client);
    }
    close(listener);
}

__attribute__((constructor))
static void StartProbe(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        dispatch_async(dispatch_queue_create("local.iphoneharness.readscreen", DISPATCH_QUEUE_SERIAL), ^{
            RunProbe();
        });
    }
}
