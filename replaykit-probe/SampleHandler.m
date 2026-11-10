#import <ReplayKit/ReplayKit.h>
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>
#import <CoreMedia/CoreMedia.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <stdatomic.h>
#import <unistd.h>
#import "ProbeStatus.h"

@interface SampleHandler : RPBroadcastSampleHandler
@end

@implementation SampleHandler {
    dispatch_source_t _listener;
    _Atomic(uint8_t) _status;
    NSTimeInterval _startedAt;
    NSTimeInterval _nextFrameAt;
}

- (void)broadcastStartedWithSetupInfo:(NSDictionary<NSString *, NSObject *> *)setupInfo {
    (void)setupInfo;
    int socketFD = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in endpoint = {
        .sin_len = sizeof(endpoint), .sin_family = AF_INET,
        .sin_port = htons(ReplayProbePort), .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };
    if (socketFD < 0 || fcntl(socketFD, F_SETFL, O_NONBLOCK) < 0 ||
        bind(socketFD, (struct sockaddr *)&endpoint, sizeof(endpoint)) < 0) {
        if (socketFD >= 0) close(socketFD);
        [self finishBroadcastWithError:[NSError errorWithDomain:@"ReplayScreenProbe" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"无法启动本机读屏测试，请停止其他录屏后重试。"}]];
        return;
    }
    _startedAt = NSProcessInfo.processInfo.systemUptime;
    _nextFrameAt = _startedAt + 3;
    atomic_store(&_status, ReplayProbeWaiting);
    _listener = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, socketFD, 0,
                                       dispatch_queue_create("local.replayprobe.status", DISPATCH_QUEUE_SERIAL));
    __weak SampleHandler *weakSelf = self;
    dispatch_source_set_event_handler(_listener, ^{
        SampleHandler *handler = weakSelf;
        if (!handler) return;
        struct sockaddr_in peer = {0};
        socklen_t length = sizeof(peer);
        char query[2];
        ssize_t received = recvfrom(socketFD, query, sizeof(query), 0, (struct sockaddr *)&peer, &length);
        if (received == 1 && query[0] == ReplayProbeQuery && peer.sin_addr.s_addr == htonl(INADDR_LOOPBACK)) {
            uint8_t status = atomic_load(&handler->_status);
            sendto(socketFD, &status, sizeof(status), 0, (struct sockaddr *)&peer, length);
        }
    });
    dispatch_source_set_cancel_handler(_listener, ^{ close(socketFD); });
    dispatch_resume(_listener);
}

- (void)broadcastFinished {
    if (_listener) {
        dispatch_source_cancel(_listener);
        _listener = nil;
    }
}

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer withType:(RPSampleBufferType)sampleType {
    if (!_listener || sampleType != RPSampleBufferTypeVideo ||
        atomic_load(&_status) >= ReplayProbeMatchedChinese) return;
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixels) return;
    if (atomic_load(&_status) == ReplayProbeWaiting) atomic_store(&_status, ReplayProbeFrames);
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now < _nextFrameAt || now - _startedAt > 35) return;
    _nextFrameAt = now + 2;
    @autoreleasepool {
        VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
        request.revision = VNRecognizeTextRequestRevision3;
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        request.recognitionLanguages = @[@"zh-Hans", @"en-US"];
        request.minimumTextHeight = 0.012;
        NSNumber *rotation = (__bridge NSNumber *)CMGetAttachment(
            sampleBuffer, (__bridge CFStringRef)RPVideoSampleOrientationKey, NULL);
        unsigned int orientation = rotation.unsignedIntValue;
        if (orientation < 1 || orientation > 8) orientation = kCGImagePropertyOrientationUp;
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixels
            orientation:(CGImagePropertyOrientation)orientation options:@{}];
        if (![handler performRequests:@[request] error:NULL]) {
            if (atomic_load(&_status) != ReplayProbeNoMatch) atomic_store(&_status, ReplayProbeVisionError);
            return;
        }

        NSMutableSet<NSString *> *lines = [NSMutableSet set];
        for (VNRecognizedTextObservation *observation in request.results) {
            NSString *line = [[[observation topCandidates:1].firstObject.string
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
            if (line.length) [lines addObject:line];
        }
        ReplayProbeStatus status = ReplayProbeNoMatch;
        if ([lines containsObject:@"通用"] && [lines containsObject:@"关于本机"]) status = ReplayProbeMatchedChinese;
        if ([lines containsObject:@"general"] && [lines containsObject:@"about"]) status = ReplayProbeMatchedEnglish;
        atomic_store(&_status, status);
    }
}
@end
