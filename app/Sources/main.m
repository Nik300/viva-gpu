#import "VMApp.h"

@interface VMAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation VMAppDelegate

static UINavigationController *VMNav(UIViewController *vc, NSString *title, NSString *symbol) {
    vc.title = title;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = YES;
    nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:title image:[UIImage systemImageNamed:symbol] tag:0];
    return nav;
}

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    UITabBarController *tabs = [UITabBarController new];
    tabs.viewControllers = @[
        VMNav([[VMMaliMetalViewController alloc] initWithStyle:UITableViewStyleInsetGrouped], @"MaliMetal", @"cpu"),
        VMNav([[VMBootArgsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped], @"Boot Args", @"power"),
        VMNav([[VMSpringBoardViewController alloc] initWithStyle:UITableViewStyleInsetGrouped], @"SpringBoard", @"apps.iphone"),
        VMNav([[VMStatsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped], @"Stat", @"chart.xyaxis.line"),
    ];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.tintColor = UIColor.systemIndigoColor;
    self.window.rootViewController = tabs;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(VMAppDelegate.class));
    }
}
