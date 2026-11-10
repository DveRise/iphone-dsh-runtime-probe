// SPDX-License-Identifier: GPL-3.0-only
#import <UIKit/UIKit.h>
#include <arpa/inet.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include "ProbeProtocol.h"

static NSDictionary *RequestProbe(const char request[4]) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    NSDictionary *result = nil;
    @try {
        struct sockaddr_in address = {0};
        address.sin_len = sizeof(address);
        address.sin_family = AF_INET;
        address.sin_port = htons(PROBE_PORT);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        struct timeval timeout = {5, 0};
        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
        if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) return nil;
        size_t offset = 0;
        while (offset < 4) {
            ssize_t count = send(fd, request + offset, 4 - offset, 0);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) return nil;
            offset += (size_t)count;
        }

        NSMutableData *bytes = [NSMutableData data];
        for (;;) {
            char chunk[512];
            ssize_t count = recv(fd, chunk, sizeof(chunk), 0);
            if (count < 0 && errno == EINTR) continue;
            if (count < 0 || bytes.length + (NSUInteger)count > 4096) return nil;
            if (count == 0) break;
            [bytes appendBytes:chunk length:(NSUInteger)count];
        }
        NSData *separator = [@"\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        NSRange split = [bytes rangeOfData:separator options:0 range:NSMakeRange(0, bytes.length)];
        if (split.location == NSNotFound) return nil;
        NSUInteger start = NSMaxRange(split);
        NSUInteger length = bytes.length - start;
        NSString *header = [[NSString alloc] initWithData:[bytes subdataWithRange:NSMakeRange(0, split.location)]
                                                encoding:NSUTF8StringEncoding];
        if (![header isEqualToString:[NSString stringWithFormat:@"0;;application/json;;%lu", (unsigned long)length]]) {
            return nil;
        }
        id value = [NSJSONSerialization JSONObjectWithData:[bytes subdataWithRange:NSMakeRange(start, length)]
                                                   options:0 error:nil];
        if ([value isKindOfClass:NSDictionary.class]) result = value;
    } @finally {
        close(fd);
    }
    return result;
}

@interface ProbeViewController : UIViewController
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) UIButton *check;
@property(nonatomic, strong) UIButton *start;
@property(nonatomic) UIBackgroundTaskIdentifier background;
@property(nonatomic) NSUInteger attempt;
@end

@implementation ProbeViewController
- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = UIButtonConfiguration.filledButtonConfiguration;
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.background = UIBackgroundTaskInvalid;
    UILabel *title = [UILabel new];
    title.text = @"iPhone 读屏测试";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    self.status = [UILabel new];
    self.status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.status.numberOfLines = 0;
    self.status.text = @"先检测本机探针。探针就绪后，点「开始」并在 7 秒内切换到系统设置。";
    self.check = [self button:@"检测探针" action:@selector(checkProbe)];
    self.start = [self button:@"开始读屏测试" action:@selector(startProbe)];
    self.start.enabled = NO;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, self.status, self.check, self.start]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *area = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:area.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:area.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:area.trailingAnchor constant:-20],
    ]];
}

- (void)checkProbe {
    self.check.enabled = NO;
    self.start.enabled = NO;
    self.status.text = @"正在检测本机探针…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *reply = RequestProbe("00\r\n");
        BOOL ready = [reply[@"ready"] isEqual:@YES] && [reply[@"captureScope"] isEqual:@"portrait Settings"];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.status.text = ready ? @"探针已就绪。开始后请切到竖屏的系统设置。"
                                     : @"未检测到本机读屏探针。";
            self.check.enabled = YES;
            self.start.enabled = ready;
        });
    });
}

- (void)finishProbe:(NSUInteger)attempt message:(NSString *)message {
    if (attempt != self.attempt) return;
    ++self.attempt;
    self.status.text = message;
    self.check.enabled = YES;
    self.start.enabled = YES;
    if (self.background != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:self.background];
        self.background = UIBackgroundTaskInvalid;
    }
}

- (void)startProbe {
    self.check.enabled = NO;
    self.start.enabled = NO;
    NSUInteger attempt = ++self.attempt;
    self.status.text = @"请在 7 秒内切到系统「设置」，保持竖屏。等待几秒后回来查看结果。";
    self.background = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"ReadScreenProbe"
        expirationHandler:^{
            [self finishProbe:attempt message:@"后台测试时间已用完。请打开测试 App 重试。"];
        }];
    if (self.background == UIBackgroundTaskInvalid) {
        [self finishProbe:attempt message:@"系统未能启动后台测试。请重新试一次。"];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 7 * NSEC_PER_SEC),
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *frame = RequestProbe("30\r\n");
            NSDictionary *text = frame ? RequestProbe("27\r\n") : nil;
            NSNumber *width = frame[@"width"], *height = frame[@"height"];
            NSArray *recognized = text[@"recognizedLabels"];
            NSString *message = @"未读到设置页面。请打开系统设置，保持竖屏后再试。";
            if ([width isKindOfClass:NSNumber.class] && [height isKindOfClass:NSNumber.class]
                && width.integerValue > 0 && height.integerValue > width.integerValue) {
                NSArray *allowed = @[@"设置", @"通用", @"关于本机", @"显示与亮度",
                                     @"Settings", @"General", @"About", @"Display & Brightness"];
                NSMutableArray *labels = [NSMutableArray array];
                for (NSString *label in allowed) {
                    if ([recognized isKindOfClass:NSArray.class] && [recognized containsObject:label]) [labels addObject:label];
                }
                NSString *summary = labels.count ? [labels componentsJoinedByString:@"、"] : @"未识别到预设菜单词";
                message = [NSString stringWithFormat:@"已截取 %@ × %@ 的画面。\n识别结果：%@", width, height, summary];
            }
            dispatch_async(dispatch_get_main_queue(), ^{ [self finishProbe:attempt message:message]; });
        });
}
@end

@interface ProbeAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation ProbeAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [ProbeViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeAppDelegate.class));
    }
}
