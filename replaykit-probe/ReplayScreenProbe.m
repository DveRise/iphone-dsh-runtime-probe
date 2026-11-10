#import <UIKit/UIKit.h>
#import <ReplayKit/ReplayKit.h>
#import <arpa/inet.h>
#import <unistd.h>
#import "ProbeStatus.h"

static ReplayProbeStatus QueryProbe(void) {
    int socketFD = socket(AF_INET, SOCK_DGRAM, 0);
    if (socketFD < 0) return ReplayProbeIdle;
    struct timeval timeout = {.tv_usec = 200000};
    struct sockaddr_in endpoint = {
        .sin_len = sizeof(endpoint), .sin_family = AF_INET,
        .sin_port = htons(ReplayProbePort), .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };
    char query = ReplayProbeQuery;
    uint8_t reply[2];
    ssize_t received = -1;
    if (setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0 &&
        connect(socketFD, (struct sockaddr *)&endpoint, sizeof(endpoint)) == 0 &&
        send(socketFD, &query, sizeof(query), 0) == sizeof(query)) {
        received = recv(socketFD, reply, sizeof(reply), 0);
    }
    close(socketFD);
    return received == 1 && reply[0] <= ReplayProbeMatchedEnglish ? (ReplayProbeStatus)reply[0] : ReplayProbeIdle;
}

@interface ProbeViewController : UIViewController
@end

@implementation ProbeViewController {
    UILabel *_statusLabel;
    NSTimer *_timer;
    BOOL _queryInFlight;
    ReplayProbeStatus _lastResult;
}

- (UILabel *)label:(NSString *)text style:(UIFontTextStyle)style {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    return label;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *title = [self label:@"录屏读屏测试" style:UIFontTextStyleLargeTitle];
    UILabel *instructions = [self label:@"① 点下方录屏图标，再点「开始直播」。\n② 在 35 秒内切到系统「设置 → 通用」，停留约 5 秒。\n③ 回到这里看结果。测试后点屏幕顶部的红色录屏标记，停止录屏。" style:UIFontTextStyleBody];
    RPSystemBroadcastPickerView *picker = [[RPSystemBroadcastPickerView alloc] initWithFrame:CGRectZero];
    picker.showsMicrophoneButton = NO;
    NSURL *pluginURL = [NSBundle.mainBundle.builtInPlugInsURL URLByAppendingPathComponent:@"ScreenReader.appex"];
    NSString *extensionID = pluginURL ? [NSBundle bundleWithURL:pluginURL].bundleIdentifier : nil;
    picker.preferredExtension = extensionID;
    picker.accessibilityLabel = @"打开系统录屏选择器";
    [picker.heightAnchor constraintEqualToConstant:56].active = YES;
    _statusLabel = [self label:extensionID ? @"等待开始录屏" : @"测试包缺少录屏扩展" style:UIFontTextStyleHeadline];
    picker.hidden = extensionID.length == 0;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, instructions, picker, _statusLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 22;
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48],
    ]];
    if (extensionID.length) {
        __weak ProbeViewController *weakSelf = self;
        _timer = [NSTimer scheduledTimerWithTimeInterval:0.75 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            [weakSelf refreshStatus];
        }];
    }
}

- (void)dealloc {
    [_timer invalidate];
}

- (void)refreshStatus {
    if (_queryInFlight || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    _queryInFlight = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ReplayProbeStatus status = QueryProbe();
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_queryInFlight = NO;
            [self showStatus:status];
        });
    });
}

- (void)showStatus:(ReplayProbeStatus)status {
    if (status != ReplayProbeIdle) _lastResult = status;
    switch (_lastResult) {
        case ReplayProbeIdle: _statusLabel.text = @"等待录屏扩展响应"; break;
        case ReplayProbeWaiting: _statusLabel.text = @"录屏已启动，等待第一帧画面"; break;
        case ReplayProbeFrames: _statusLabel.text = @"已收到画面，等待识别"; break;
        case ReplayProbeVisionError: _statusLabel.text = @"已收到画面，文字识别出错"; break;
        case ReplayProbeNoMatch: _statusLabel.text = @"已读取画面，暂未识别到测试菜单"; break;
        case ReplayProbeMatchedChinese: _statusLabel.text = @"读屏成功 · 已识别「通用」和「关于本机」"; break;
        case ReplayProbeMatchedEnglish: _statusLabel.text = @"读屏成功 · 已识别 General 和 About"; break;
    }
    if (status == ReplayProbeIdle && _lastResult != ReplayProbeIdle) {
        _statusLabel.text = [_statusLabel.text stringByAppendingString:@"\n当前录屏扩展无响应，上方为最近一次结果。"];
    }
}
@end

@interface ProbeAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation ProbeAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[ProbeViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeAppDelegate.class));
    }
}
