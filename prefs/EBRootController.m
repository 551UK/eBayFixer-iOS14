#import <UIKit/UIKit.h>

@interface PSViewController : UIViewController
@end

static NSString *const EBPrefsPath = @"/var/mobile/Library/Preferences/com.551.ebayfixer.plist";

static BOOL EBEnabled(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:EBPrefsPath];
    id value = prefs[@"enabled"];
    return value ? [value boolValue] : YES;
}

static void EBSetEnabled(BOOL enabled) {
    NSMutableDictionary *prefs = [[NSDictionary dictionaryWithContentsOfFile:EBPrefsPath] mutableCopy] ?: [NSMutableDictionary dictionary];
    prefs[@"enabled"] = @(enabled);
    [prefs writeToFile:EBPrefsPath atomically:YES];
}

@interface EBTableController : UITableViewController
@end

@implementation EBTableController

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return 1; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"Enable or disable eBayFixer. Fully close and reopen eBay after changing this setting.";
    return @"eBayFixer for eBay 6.96.0 on rootful iOS 14.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (indexPath.section == 0) {
        cell.textLabel.text = @"Enabled";
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.on = EBEnabled();
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = @"GitHub Repository";
        cell.textLabel.textColor = self.view.tintColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)toggleChanged:(UISwitch *)toggle {
    EBSetEnabled(toggle.on);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        NSURL *url = [NSURL URLWithString:@"https://github.com/551UK/eBayFixer-iOS14"];
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }
}

@end

@interface EBRootController : PSViewController
@property(nonatomic, strong) EBTableController *settingsTable;
@end

@implementation EBRootController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"eBayFixer iOS 14";
    self.settingsTable = [[EBTableController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    [self addChildViewController:self.settingsTable];
    self.settingsTable.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.settingsTable.view];
    [NSLayoutConstraint activateConstraints:@[
        [self.settingsTable.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.settingsTable.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.settingsTable.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.settingsTable.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    [self.settingsTable didMoveToParentViewController:self];
}

@end
