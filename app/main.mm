#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <NodeMobile/NodeMobile.h>
#include <sys/socket.h>
#include "session-lock.h"
#include <netinet/in.h>
#include <limits.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static BOOL sendLine(int socket, NSDictionary *message) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (!json) return NO;
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    const char *bytes = (const char *)line.bytes;
    size_t remaining = line.length;
    while (remaining > 0) {
        ssize_t count = send(socket, bytes, remaining, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        bytes += count;
        remaining -= (size_t)count;
    }
    return YES;
}

@interface HarnessController : UIViewController <WKNavigationDelegate>
@property(nonatomic,strong) WKWebView *web;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIButton *startButton;
@property(nonatomic,strong) UIButton *stopButton;
@property(nonatomic,copy) NSString *directory;
@property(nonatomic,copy) NSString *nonce;
@property(nonatomic,copy) NSString *origin;
@property(atomic) BOOL stopping;
@property(atomic) int listener;
@property(atomic) int client;
@end

@implementation HarnessController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.listener = -1; self.client = -1;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    self.directory = [base stringByAppendingPathComponent:@"MobileRuntimeProbe"];
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:self.directory withIntermediateDirectories:YES
        attributes:@{NSFileProtectionKey:NSFileProtectionComplete} error:&error];
    UILabel *title = [UILabel new]; title.text = @"DeepSeek Harness";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    self.status = [UILabel new]; self.status.numberOfLines = 0;
    self.status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.status.text = error ? @"无法创建工作目录。" : @"前台运行 · 手机操作工具尚未接入";
    self.startButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.startButton setTitle:@"启动助手" forState:UIControlStateNormal];
    [self.startButton addTarget:self action:@selector(startHarness) forControlEvents:UIControlEventTouchUpInside];
    self.startButton.enabled = error == nil;
    self.stopButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.stopButton setTitle:@"停止" forState:UIControlStateNormal]; self.stopButton.enabled = NO;
    [self.stopButton addTarget:self action:@selector(stopHarness) forControlEvents:UIControlEventTouchUpInside];
    UIButton *share = [UIButton buttonWithType:UIButtonTypeSystem];
    [share setTitle:@"导出状态" forState:UIControlStateNormal];
    [share addTarget:self action:@selector(shareResults) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[self.startButton,self.stopButton,share]];
    buttons.distribution = UIStackViewDistributionFillEqually;
    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title,self.status,buttons]];
    header.axis = UILayoutConstraintAxisVertical; header.spacing = 6;
    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    config.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    NSString *compatPath = [NSBundle.mainBundle pathForResource:@"web-compat" ofType:@"js"];
    NSString *compat = compatPath ? [NSString stringWithContentsOfFile:compatPath encoding:NSUTF8StringEncoding error:nil] : nil;
    if (compat) {
        [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:compat
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
    } else {
        self.startButton.enabled = NO;
        self.status.text = @"界面兼容组件缺失，请重新安装。";
    }
    self.web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    self.web.navigationDelegate = self;
    header.translatesAutoresizingMaskIntoConstraints = NO; self.web.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header]; [self.view addSubview:self.web];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [header.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [header.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [self.web.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:4],
        [self.web.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.web.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.web.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor]
    ]];
}

- (BOOL)validLocalURL:(NSURL *)url {
    return [url.scheme isEqualToString:@"http"] && [url.host isEqualToString:@"127.0.0.1"]
        && url.port.integerValue > 0 && url.port.integerValue <= 65535 && !url.user && !url.password;
}
- (NSString *)originForURL:(NSURL *)url {
    return [NSString stringWithFormat:@"http://127.0.0.1:%@",url.port];
}
- (void)handleMessage:(NSDictionary *)message {
    NSString *type = message[@"type"];
    if ([type isEqual:@"ready"] && !self.stopping) {
        id value = message[@"url"];
        NSURL *url = [value isKindOfClass:NSString.class] ? [NSURL URLWithString:value] : nil;
        if (!url || ![self validLocalURL:url]) { [self stopHarness]; self.status.text = @"本机界面地址无效。"; return; }
        self.origin = [self originForURL:url];
        self.status.text = @"运行中 · 请保持 App 在前台";
        [self.web loadRequest:[NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30]];
    } else if ([type isEqual:@"error"]) {
        self.status.text = @"启动或运行失败，请导出状态。"; self.stopButton.enabled = NO;
        self.origin = nil; [self.web stopLoading]; self.web.hidden = YES;
    } else if ([type isEqual:@"stopped"]) {
        self.status.text = @"已停止。再次启动请从多任务界面关闭后重开 App。"; self.stopButton.enabled = NO;
    }
}

// Node's Worker and this host share descriptors in the same process.
// Only lock an already open regular file; the Worker owns and closes it.
- (BOOL)replyToFileLock:(NSDictionary *)message socket:(int)socket nonce:(NSString *)nonce {
    NSNumber *request = message[@"id"], *descriptor = message[@"fd"];
    if (![request isKindOfClass:NSNumber.class] || ![descriptor isKindOfClass:NSNumber.class]) return NO;
    long long value = descriptor.longLongValue;
    if (value < 3 || value > INT_MAX || descriptor.doubleValue != (double)value) return NO;
    int status = trySessionLock((int)value);
    @synchronized(self) {
        return self.client == socket && sendLine(socket,
            @{@"type":@"flock-result", @"id":request, @"errno":@(status), @"nonce":nonce});
    }
}

// A private loopback connection carries the launch URL; no token enters a file.
- (void)readBridge:(int)listener nonce:(NSString *)nonce {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:100];
    while (!self.stopping && [deadline timeIntervalSinceNow] > 0) {
        fd_set set; FD_ZERO(&set); FD_SET(listener,&set);
        struct timeval wait = {1,0};
        if (select(listener+1,&set,NULL,NULL,&wait) <= 0) continue;
        int fd = accept(listener,NULL,NULL);
        if (fd < 0) continue;
        struct timeval timeout = {1,0};
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
        setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
        int yes = 1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
        NSMutableData *pending = [NSMutableData data]; BOOL trusted = NO;
        while (!self.stopping) {
            char chunk[2048]; ssize_t count = recv(fd,chunk,sizeof(chunk),0);
            if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                if (!trusted && [deadline timeIntervalSinceNow] <= 0) break;
                continue;
            }
            if (count <= 0) break;
            [pending appendBytes:chunk length:(NSUInteger)count];
            if (pending.length > 8192) break;
            BOOL invalid = NO;
            while (YES) {
                const void *end = memchr(pending.bytes,'\n',pending.length);
                if (!end) break;
                NSUInteger size = (const char *)end - (const char *)pending.bytes;
                NSData *line = [pending subdataWithRange:NSMakeRange(0,size)];
                [pending replaceBytesInRange:NSMakeRange(0,size+1) withBytes:NULL length:0];
                id message = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
                if (![message isKindOfClass:NSDictionary.class] || ![message[@"nonce"] isEqual:nonce]) { invalid = YES; break; }
                if (!trusted) { trusted = YES; @synchronized(self) { self.client = fd; } }
                if ([message[@"type"] isEqual:@"flock"]) {
                    if (![self replyToFileLock:message socket:fd nonce:nonce]) { invalid = YES; break; }
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{ [self handleMessage:message]; });
                }
            }
            if (invalid) break;
        }
        @synchronized(self) { if (self.client == fd) self.client = -1; close(fd); }
        if (trusted) break;
    }
    @synchronized(self) { if (self.listener == listener) { close(listener); self.listener = -1; } }
}

- (void)startHarness {
    self.startButton.enabled = NO;
    self.status.text = @"正在启动，请保持 App 在前台……";
    self.nonce = [NSUUID UUID].UUIDString;
    int listener = socket(AF_INET,SOCK_STREAM,0);
    struct sockaddr_in address = {}; address.sin_family = AF_INET; address.sin_len = sizeof(address);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK); address.sin_port = 0;
    if (listener < 0 || bind(listener,(struct sockaddr *)&address,sizeof(address)) != 0 || listen(listener,4) != 0) {
        if (listener >= 0) close(listener); self.status.text = @"本机服务无法启动，请重新打开 App。"; return;
    }
    socklen_t length = sizeof(address); getsockname(listener,(struct sockaddr *)&address,&length);
    NSString *port = [NSString stringWithFormat:@"%u",ntohs(address.sin_port)];
    self.listener = listener; self.stopButton.enabled = YES;
    NSString *nonce = self.nonce;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{ [self readBridge:listener nonce:nonce]; });
    NSString *script = [NSBundle.mainBundle pathForResource:@"interactive" ofType:@"mjs"];
    NSString *install = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"dsh-runtime"];
    NSString *directory = self.directory;
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        @autoreleasepool {
            int file = open([[directory stringByAppendingPathComponent:@"runtime.log"] fileSystemRepresentation],O_CREAT|O_TRUNC|O_WRONLY,0600);
            int oldOut = dup(STDOUT_FILENO), oldErr = dup(STDERR_FILENO);
            int result = -1;
            if (file >= 0 && script) {
                dup2(file,STDOUT_FILENO); dup2(file,STDERR_FILENO); close(file);
                setvbuf(stdout,NULL,_IOLBF,0); setvbuf(stderr,NULL,_IOLBF,0);
                char *args[] = {strdup("node"),strdup("--expose-internals"),strdup(script.fileSystemRepresentation),
                    strdup(directory.fileSystemRepresentation),strdup(install.fileSystemRepresentation),strdup(port.UTF8String),strdup(nonce.UTF8String)};
                result = node_start(7,args);
                for (char *arg : args) free(arg);
                fflush(stdout); fflush(stderr);
            } else if (file >= 0) close(file);
            if (oldOut >= 0) { dup2(oldOut,STDOUT_FILENO); close(oldOut); }
            if (oldErr >= 0) { dup2(oldErr,STDERR_FILENO); close(oldErr); }
            self.stopping = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.stopButton.enabled = NO;
                self.origin = nil; [self.web stopLoading]; self.web.hidden = YES;
                self.status.text = result == 0 ? @"已停止。再次启动请从多任务界面关闭后重开 App。" : @"助手已退出，请导出状态。";
            });
        }
    }];
    thread.stackSize = 8 * 1024 * 1024; [thread start];
}

- (void)stopHarness {
    self.stopButton.enabled = NO; self.status.text = @"正在停止……";
    self.origin = nil; [self.web stopLoading]; self.web.hidden = YES;
    @synchronized(self) {
        if (self.client >= 0) {
            if (!sendLine(self.client, @{@"type":@"stop", @"nonce":self.nonce})) self.stopping = YES;
        } else { self.stopping = YES; }
    }
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    NSURL *url = action.request.URL;
    BOOL local = [self validLocalURL:url] && [[self originForURL:url] isEqual:self.origin];
    handler(local && action.targetFrame != nil ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (error.code != NSURLErrorCancelled) self.status.text = @"界面加载失败，可导出状态。";
}
- (void)shareResults {
    NSMutableArray *items = [NSMutableArray new];
    for (NSString *name in @[@"runtime-report.json",@"runtime.log"]) {
        NSString *path = [self.directory stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) [items addObject:[NSURL fileURLWithPath:path]];
    }
    if (!items.count) { self.status.text = @"请先启动助手。"; return; }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:share animated:YES completion:nil];
}
@end

@interface HarnessDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation HarnessDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [HarnessController new]; [self.window makeKeyAndVisible]; return YES;
}
@end
int main(int argc,char *argv[]) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(HarnessDelegate.class)); } }
