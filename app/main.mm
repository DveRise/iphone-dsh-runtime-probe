#import <UIKit/UIKit.h>
#import <NodeMobile/NodeMobile.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

@interface ProbeController : UIViewController
@property(nonatomic, strong) UITextView *logView;
@property(nonatomic, strong) UIButton *startButton;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) NSString *dataDirectory;
@property(nonatomic, copy) NSString *logPath;
@end

@implementation ProbeController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    self.dataDirectory = [base stringByAppendingPathComponent:@"MobileRuntimeProbe"];
    NSError *directoryError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:self.dataDirectory withIntermediateDirectories:YES attributes:nil error:&directoryError];
    self.logPath = [self.dataDirectory stringByAppendingPathComponent:@"runtime.log"];

    UILabel *title = [UILabel new];
    BOOL harness = [[NSBundle mainBundle] pathForResource:@"dsh-worker" ofType:@"mjs"] != nil;
    title.text = harness ? @"DeepSeek Harness 启动检查" : @"iPhone 运行环境检查";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    UILabel *description = [UILabel new];
    description.text = harness ? @"检查官方 Harness 的启动和本机界面服务。尚不调用模型或操控其他 App。请保持页面在前台。" : @"检查手机本机的 Node 24、文件读写及网络能力。此包尚不运行 DeepSeek 任务。请保持页面在前台。";
    description.numberOfLines = 0;
    description.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.startButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.startButton setTitle:@"开始检查" forState:UIControlStateNormal];
    [self.startButton addTarget:self action:@selector(startProbe) forControlEvents:UIControlEventTouchUpInside];
    UIButton *share = [UIButton buttonWithType:UIButtonTypeSystem];
    [share setTitle:@"导出结果" forState:UIControlStateNormal];
    [share addTarget:self action:@selector(shareResults) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[self.startButton, share]];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.distribution = UIStackViewDistributionFillEqually;
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, description, buttons]];
    header.axis = UILayoutConstraintAxisVertical;
    header.spacing = 12;
    self.logView = [UITextView new];
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.logView.text = directoryError ? directoryError.localizedDescription : @"点击“开始检查”。每次启动应用只运行一次。";
    self.startButton.enabled = directoryError == nil;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];
    [self.view addSubview:self.logView];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [header.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [header.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.logView.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:12],
        [self.logView.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [self.logView.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [self.logView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12]
    ]];
}

- (void)refreshLog {
    NSString *text = [NSString stringWithContentsOfFile:self.logPath encoding:NSUTF8StringEncoding error:nil];
    if (text.length) self.logView.text = text;
}

- (void)startProbe {
    self.startButton.enabled = NO;
    self.logView.text = @"正在检查，请保持应用在前台……";
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(refreshLog) userInfo:nil repeats:YES];
    NSString *script = [NSBundle.mainBundle pathForResource:@"probe" ofType:@"mjs"];
    NSString *directory = self.dataDirectory;
    NSString *logPath = self.logPath;
    NSString *installRoot = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"dsh-runtime"];
    BOOL harness = [[NSBundle mainBundle] pathForResource:@"dsh-worker" ofType:@"mjs"] != nil;
    __weak ProbeController *weakSelf = self;
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        @autoreleasepool {
            int file = open(logPath.fileSystemRepresentation, O_CREAT | O_TRUNC | O_WRONLY, 0600);
            int oldOut = dup(STDOUT_FILENO), oldErr = dup(STDERR_FILENO);
            int result = -1;
            if (file >= 0 && script != nil) {
                dup2(file, STDOUT_FILENO);
                dup2(file, STDERR_FILENO);
                close(file);
                setvbuf(stdout, NULL, _IOLBF, 0);
                setvbuf(stderr, NULL, _IOLBF, 0);
                setenv("DSH_HOME", directory.fileSystemRepresentation, 1);
                char *args[5];
                int count = 0;
                args[count++] = strdup("node");
                if (harness) args[count++] = strdup("--expose-internals");
                args[count++] = strdup(script.fileSystemRepresentation);
                args[count++] = strdup(directory.fileSystemRepresentation);
                if (harness) args[count++] = strdup(installRoot.fileSystemRepresentation);
                result = node_start(count, args);
                for (int i = 0; i < count; i++) free(args[i]);
                fprintf(stdout, "Native host: node_start returned %d\n", result);
                fflush(stdout);
                fflush(stderr);
            } else if (file >= 0) {
                close(file);
            }
            if (oldOut >= 0) { dup2(oldOut, STDOUT_FILENO); close(oldOut); }
            if (oldErr >= 0) { dup2(oldErr, STDERR_FILENO); close(oldErr); }
            dispatch_async(dispatch_get_main_queue(), ^{
                ProbeController *controller = weakSelf;
                [controller.timer invalidate];
                controller.timer = nil;
                [controller refreshLog];
                if (result == -1) controller.logView.text = @"测试脚本或日志文件无法打开。";
            });
        }
    }];
    thread.stackSize = 8 * 1024 * 1024;
    [thread start];
}

- (void)shareResults {
    NSMutableArray *items = [NSMutableArray new];
    for (NSString *name in @[@"runtime-report.json", @"runtime.log"]) {
        NSString *path = [self.dataDirectory stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) [items addObject:[NSURL fileURLWithPath:path]];
    }
    if (items.count == 0) {
        self.logView.text = @"请先运行检查，再导出结果。";
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:share animated:YES completion:nil];
}
@end

@interface ProbeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation ProbeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [ProbeController new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeDelegate.class));
    }
}
