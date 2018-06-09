/*
 *   This tweak notifies a user when a snapchat streak with another friend is running down in time.
 *   It also tells a user how much time is remanining in their feed. Customizable with a bunch of settings,
 *   custom time, custom friends, and even preset values that you can enable with a switch in preferences.
 *   Auto-send snap will [*not*] be implemented soon so that the streak is kept with a person
 *
 */

#import <rocketbootstrap/rocketbootstrap.h>
#import "Interfaces.h"

#ifdef DEBUG
#define SNLog(...) NSLog(__VA_ARGS__)
#else
#define SNLog(...) void(0)
#endif

static NSString *snapchatVersion = nil;
static NSDictionary *prefs = nil;
static NSMutableArray *customFriends = nil;

/* Load Preferences and other relevant data */
static void LoadPreferences() {
    if(!snapchatVersion){
        NSDictionary* infoDict = [[NSBundle mainBundle] infoDictionary];
        snapchatVersion = [infoDict objectForKey:@"CFBundleVersion"];
    }
    if(!prefs){
        prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.YungRaj.streaknotify.plist"];
    }
    if(!customFriends){
        NSDictionary *friendmojiList = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.YungRaj.friendmoji.plist"];
        customFriends = [[NSMutableArray alloc] init];
        for(NSString *name in [friendmojiList allKeys]){
            if([friendmojiList[name] boolValue]){
                [customFriends addObject:name];
            }
        }
    }
}

static void ReconfigureCells();

static NSDictionary* GetFriendmojis(){
    SNLog(@"StreakNotify:: Getting Friendmojis...");
    NSMutableDictionary *dictionary = [[NSMutableDictionary alloc] init];
    
    NSMutableDictionary *friendsWithStreaks = [[NSMutableDictionary alloc] init];
    NSMutableDictionary *friendsWithoutStreaks = [[NSMutableDictionary alloc] init];
    
    Manager *manager = [objc_getClass("Manager") shared];
    User *user = [manager user];
    Friends *friends = [user friends];

    for(Friend *f in [friends getAllFriends]){
        
        NSString *displayName = [f display];
        SNLog(@"StreakNotify:: Getting friendmoji for %@", displayName);
        NSString *count = [NSString stringWithFormat:@"🔥%lld", [f snapStreakCount]];

        if(displayName && ![displayName isEqual:@""]){
            if([f snapStreakCount] > 2){
                [friendsWithStreaks setObject:count forKey:displayName];
            } else {
                [friendsWithoutStreaks setObject:@"" forKey:displayName];
            }
        }
        else {
            NSString *username = [f name];
            if(username && ![username isEqual:@""]){
                if([f snapStreakCount] > 2){
                    [friendsWithStreaks setObject:count forKey:username];
                }else {
                    [friendsWithoutStreaks setObject:@"" forKey:username];
                }
            }
        }
    }

    SNLog(@"StreakNotify:: Got Friendmojis");
    
    [dictionary setObject:friendsWithStreaks forKey:@"friendsWithStreaks"];
    [dictionary setObject:friendsWithoutStreaks forKey:@"friendsWithoutStreaks"];
    
    return dictionary;
}

/* Sends a Mach message to the daemon using Distributed Notifications via the bootstrap server */
static void SendFriendmojisToDaemon(){
    SNLog(@"StreakNotify::Sending friendmojis to Daemon");
    
    CPDistributedMessagingCenter *c = [CPDistributedMessagingCenter centerNamed:@"com.YungRaj.streaknotifyd"];
    rocketbootstrap_unlock("com.YungRaj.streaknotifyd");
    rocketbootstrap_distributedmessagingcenter_apply(c);
    [c sendMessageName:@"friendmojis"
              userInfo:GetFriendmojis()];
}

SOJUFriendmoji* FindOnFireEmoji(NSArray *friendmojis){
    for(NSObject *obj in friendmojis){
        if([obj isKindOfClass:objc_getClass("SOJUFriendmoji")]){
            SOJUFriendmoji *friendmoji = (SOJUFriendmoji*)obj;
            if([[friendmoji categoryName] isEqual:@"on_fire"]){
                return friendmoji;
            }
        }
    }
    return nil;
}

static NSString* GetTimeRemaining(NSDate *expirationDate){
    
    /* In the new chat 2.0 update to snapchat, the SOJUFriend and SOJUFriendBuilder class now sets a property called snapStreakExpiration/snapStreakExpiryTime which is basically a long long value that describes the time in seconds since 1970 of when the snap streak should end when that expiration date arrives.
     */
    /* Note: January 10, 2017
     In the newest versions of Snapchat, not sure which version this started, a class named SOJUFriendmoji contains data related to the friendmoji's. Since the fire emoji is a friendmoji, the SOJUFriendmoji class is what we were always looking for. There is a memeber of the class named categoryName and expirationTime. After some exploration, if the categoryName's value is @"on_fire", then the expirationTime is the exact time when the friendmoji is valid until. We can now use this for retrieving the time remaining */
    
    NSDate *date = [NSDate date];
    
    NSCalendar *gregorianCal = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
    NSUInteger unitFlags = NSSecondCalendarUnit | NSMinuteCalendarUnit |NSHourCalendarUnit | NSDayCalendarUnit;
    NSDateComponents *components = [gregorianCal components:unitFlags
                                                   fromDate:date
                                                     toDate:expirationDate
                                                    options:0];
    NSInteger day = [components day];
    NSInteger hour = [components hour];
    NSInteger minute = [components minute];
    NSInteger second = [components second];
    
    if([prefs[@"kExactTime"] boolValue]){
        if(day){
            return [NSString stringWithFormat:@"%ldd %ldh %ldm",(long)day,long(hour),(long)minute];
        }else if(!day && hour){
            return [NSString stringWithFormat:@"%ldh %ldm",(long)hour,(long)minute];
        }
    }

    if(day){
        return [NSString stringWithFormat:@"%ld d",(long)day];
    }else if(hour){
        return [NSString stringWithFormat:@"%ld hr",(long)hour];
    }else if(minute){
        return [NSString stringWithFormat:@"%ld m",(long)minute];
    }else if(second){
        return [NSString stringWithFormat:@"%ld s",(long)second];
    }
    /* Shouldn't happen but to shut the compiler up this is needed */
    return @"Unknown";
}

static NSDictionary* SetUpNotification(NSDate *expirationDate,
                                       Friend *f,
                                       float seconds,
                                       float minutes,
                                       float hours){
    NSString *friendName = f.name;
    NSString *displayName = f.display;
    if([customFriends count] && ![customFriends containsObject:displayName]){
        SNLog(@"StreakNotify:: Not scheduling notification for %@, not enabled in custom friends",displayName);
        return nil;
    }
    SNLog(@"Using streaknotifyd helper service to schedule notification for %@",displayName);
    float t = hours ? hours : minutes ? minutes : seconds;
    NSString *time = hours ? @"hours" : minutes ? @"minutes" : @"seconds";
    NSDate *notificationDate = nil;
    if(objc_getClass("SOJUFriendmoji")){
        notificationDate = [[NSDate alloc] initWithTimeInterval:-60*60*hours - 60*minutes - seconds
                                                  sinceDate:expirationDate];
    }else{
        notificationDate = [[NSDate alloc] initWithTimeInterval:60*60*24 - 60*60*hours - 60*minutes - seconds
                                                  sinceDate:expirationDate];
    }
    NSString *notificationMessage = [NSString stringWithFormat:@"Keep streak with %@. %ld %@ left!",displayName,(long)t,time];
    
    if([notificationDate laterDate:[NSDate date]] == notificationDate)
        return @{@"kNotificationFriendName" : friendName,
                  @"kNotificationMessage" : notificationMessage,
                  @"kNotificationDate" : notificationDate };
    else {
        SNLog(@"Not setting up notification at %@ for friend %@",notificationDate,friendName);
        return nil;
    }
}

static void ScheduleNotifications(){
    Manager *manager = [objc_getClass("Manager") shared];
    User *user = [manager user];
    Friends *friends = [user friends];
    SCChats *chats = [user chats];
    
    NSMutableDictionary *notificationsInfo = [[NSMutableDictionary alloc] init];
    NSMutableArray *notifications = [[NSMutableArray alloc] init];
    SNLog(@"SCChats allChats %@",[chats allChats]);
    
    if([[chats allChats] count]){
        for(SCChat *chat in [chats allChats]){
            
            Friend *f = [friends friendForName:[chat recipient]];
            NSArray *friendmojis = f.friendmojis;
            SOJUFriendmoji *friendmoji = FindOnFireEmoji(friendmojis);
            long long expirationTimeValue = [friendmoji expirationTimeValue];
            NSDate *expirationDate = [NSDate dateWithTimeIntervalSince1970:expirationTimeValue/1000];
            SNLog(@"StreakNotify:: Name and date %@ for %@",expirationDate,[chat recipient]);
            
            if([f snapStreakCount]>2){
                if([prefs[@"kTwelveHours"] boolValue]){
                    SNLog(@"Scheduling for 12 hours %@",[f name]);
                    NSDictionary *twelveHours = SetUpNotification(expirationDate,f,0,0,12);
                    if(twelveHours){
                        [notifications addObject:twelveHours];
                    }
                    
                } if([prefs[@"kFiveHours"] boolValue]){
                    SNLog(@"Scheduling for 5 hours %@",[f name]);
                    NSDictionary *fiveHours = SetUpNotification(expirationDate,f,0,0,5);
                    if(fiveHours){
                        [notifications addObject:fiveHours];
                    }
                    
                } if([prefs[@"kOneHour"] boolValue]){
                    SNLog(@"Scheduling for 1 hour %@",[f name]);
                    NSDictionary *oneHour = SetUpNotification(expirationDate,f,0,0,1);
                    if(oneHour){
                        [notifications addObject:oneHour];
                    }
                    
                } if([prefs[@"kTenMinutes"] boolValue]){
                    SNLog(@"Scheduling for 10 minutes %@",[f name]);
                    NSDictionary *tenMinutes = SetUpNotification(expirationDate,f,0,10,0);
                    if(tenMinutes){
                        [notifications addObject:tenMinutes];
                    }
                }
                
                float seconds = [prefs[@"kCustomSeconds"] floatValue];
                float minutes = [prefs[@"kCustomMinutes"] floatValue];
                float hours = [prefs[@"kCustomHours"] floatValue] ;
                if(hours || minutes || seconds){
                    SNLog(@"Scheduling for custom time %@",[f name]);
                    NSDictionary *customTime = SetUpNotification(expirationDate,f,seconds,minutes,hours);
                    if(customTime){
                        [notifications addObject:customTime];
                    }
                }
            }
        }
    }
    [notificationsInfo setObject:notifications forKey:@"kNotifications"];
    SNLog(@"StreakNotify::Sending request to streaknotifyd");
    
    // Send a message with name notifications to streaknotifyd to handle dictionary data
    CPDistributedMessagingCenter *c = [CPDistributedMessagingCenter centerNamed:@"com.YungRaj.streaknotifyd"];
    rocketbootstrap_unlock("com.YungRaj.streaknotifyd");
    rocketbootstrap_distributedmessagingcenter_apply(c);
    [c sendMessageName:@"notifications"
                  userInfo:notificationsInfo];
}

static UILabel* GetLabelFromCell(UITableViewCell *cell, NSMutableArray *instances, NSMutableArray *labels) {
    UILabel *label;
    if (![instances containsObject:cell]) {
        SNLog(@"StreakNotify::Trying to add label to the cell");
        // UIView *feedView = cell.feedComponentView;
        CGSize size = cell.frame.size;
        CGRect rect = CGRectMake(size.width*.75,
                                 size.height*.7,
                                 size.width/5,
                                 size.height/4);
        
        label = [[UILabel alloc] initWithFrame:rect];
        label.textAlignment = NSTextAlignmentRight;
        label.font = [UIFont fontWithName:label.font.fontName size:11];
        [instances addObject:cell];
        [labels addObject:label];
        [cell addSubview:label];
    } else {
        label = [labels objectAtIndex:[instances indexOfObject:cell]];
    }
    return label;
}

static NSDate* GetExpirationDate(Friend *f){
    NSArray *friendmojis = f.friendmojis;
    SOJUFriendmoji *friendmoji = FindOnFireEmoji(friendmojis);
    long long expirationTimeValue = [friendmoji expirationTimeValue];
    return [NSDate dateWithTimeIntervalSince1970:expirationTimeValue/1000];
}

static NSString *TextForLabel(Friend *f, SCChat *chat){
    NSDate *expirationDate = GetExpirationDate(f);
    if ([expirationDate laterDate:[NSDate date]]!=expirationDate){
        return @"";
    } else if ([f snapStreakCount]>2 && objc_getClass("SOJUFriendmoji") && [[chat lastSnap] sender]){
        return [NSString stringWithFormat:@"⏰ %@", GetTimeRemaining(expirationDate)];
    } else if ([f snapStreakCount]>2){
        return [NSString stringWithFormat:@"⌛️ %@", GetTimeRemaining(expirationDate)];
    }
    return @"";
}

static void ConfigureCell(SCFeedSwipeableTableViewCell *cell,
                               NSMutableArray *instances,
                               NSMutableArray *labels){

    NSString *username = [(SCFeedChatCellViewModel*)[cell viewModel] identifier];

    if (username){
		Manager *manager = [objc_getClass("Manager") shared];
	    User *user = [manager user];
	    Friends *friends = [user friends];
        SCChats *chats = [user chats];
        SCChat *chat = [chats chatForUsername:username];
	    Friend *f = [friends friendForName:username];

	    UILabel *label = GetLabelFromCell(cell, instances, labels);
	    NSString *text = TextForLabel(f, chat);
	    // SNLog(@"StreakNotify::Label text %@", text);
	    label.text = text;

	    if([text isEqualToString:@""]){
	        label.hidden = YES;
	    }else{
	        label.hidden = NO;
	    }
	} else {
        SNLog(@"StreakNotify::username not found, Snapchat was updated and no selector was found");
	}
}


%group SnapchatHooks

%hook MainViewController
-(void)viewDidLoad{
    /* Setting up all the user specific data */
    
    %orig();

    @try {
        ScheduleNotifications();
    }
    @catch (NSException *exception) {
        SNLog(@"StreakNotify::ScheduleNotifications failed %@", exception.reason);
    }
    
    if(!prefs) {
        SNLog(@"StreakNotify:: No preferences found on file, letting user know");
        if([UIAlertController class]){
            UIAlertController *controller =
            [UIAlertController alertControllerWithTitle:@"StreakNotify"
                                                message:@"You haven't selected any preferences yet in Settings, use defaults?"
                                         preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction *cancel =
            [UIAlertAction actionWithTitle:@"Cancel"
                                     style:UIAlertActionStyleDefault
                                   handler:^(UIAlertAction* action){
                                       exit(0);
                                   }];
            UIAlertAction *ok =
            [UIAlertAction actionWithTitle:@"Ok"
                                     style:UIAlertActionStyleCancel
                                   handler:^(UIAlertAction* action){
                                       NSDictionary *preferences = @{@"kStreakNotifyDisabled" : @NO,
                                                                      @"kExactTime" : @YES,
                                                                      @"kTwelveHours" : @YES,
                                                                      @"kFiveHours" : @NO,
                                                                      @"kOneHour" : @NO,
                                                                      @"kTenMinutes" : @NO,
                                                                      @"kCustomHours" : @"0",
                                                                      @"kCustomMinutes" : @"0",
                                                                      @"kCustomSeconds" : @"0"};
                                       [preferences writeToFile:@"/var/mobile/Library/Preferences/com.YungRaj.streaknotify.plist" atomically:YES];
                                       prefs = preferences;
                                       SNLog(@"StreakNotify:: saved default preferences to file, default settings will now appear in the preferences bundle");
                                   }];
            [controller addAction:cancel];
            [controller addAction:ok];
            [[[[UIApplication sharedApplication] keyWindow] rootViewController] presentViewController:controller animated:YES completion:nil];
        } else{
            SNLog(@"StreakNotify:: UIAlertController class not available, iOS 9 and earlier");
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"StreakNotify"
                                                            message:@"You haven't selected any preferences yet in Settings, use defaults?"
                                                           delegate:self
                                                  cancelButtonTitle:nil
                                                  otherButtonTitles:@"Ok", @"Cancel", nil];
            [alert show];
        }
    }
}

-(void)didSendSnaps:(id)arg1{
// -(void)didSendSnap:(Snap*)snap{
    %orig();
    SNLog(@"StreakNotify::Snap to %@ has sent successfully", arg1);
    ReconfigureCells();
}

%new
-(void)alertView:(UIAlertView *)alertView
clickedButtonAtIndex:(NSInteger)buttonIndex{
    if(buttonIndex==0){
        SNLog(@"StreakNotify:: using default preferences");
        NSDictionary *preferences = @{@"kStreakNotifyDisabled" : @NO,
                                       @"kExactTime" : @YES,
                                       @"kTwelveHours" : @YES,
                                       @"kFiveHours" : @NO,
                                       @"kOneHour" : @NO,
                                       @"kTenMinutes" : @NO,
                                       @"kCustomHours" : @"0",
                                       @"kCustomMinutes" : @"0",
                                       @"kCustomSeconds" : @"0"};
        [preferences writeToFile:@"/var/mobile/Library/Preferences/com.YungRaj.streaknotify.plist" atomically:YES];
        prefs = preferences;
        SNLog(@"StreakNotify:: saved default preferences to file, default settings will now appear in the preferences bundle");
    }else {
        SNLog(@"StreakNotify:: exiting application - user denied default settings");
        exit(0);
    }
}
%end


%hook SCAppDelegate
-(BOOL)application:(UIApplication*)application
didFinishLaunchingWithOptions:(NSDictionary*)launchOptions{
    
    /* Register for local notifications, and do what we normally do */
    snapchatVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    
    if ([application respondsToSelector:@selector(registerUserNotificationSettings:)]) {
        UIUserNotificationSettings* notificationSettings = [UIUserNotificationSettings settingsForTypes:UIUserNotificationTypeAlert | UIUserNotificationTypeBadge | UIUserNotificationTypeSound categories:nil];
        [[UIApplication sharedApplication] registerUserNotificationSettings:notificationSettings];
    } else {
        [[UIApplication sharedApplication] registerForRemoteNotificationTypes: (UIRemoteNotificationTypeBadge | UIRemoteNotificationTypeSound | UIRemoteNotificationTypeAlert)];
    }
    
    SNLog(@"StreakNotify:: Just launched application successfully running Snapchat version %@",snapchatVersion);
    
    
    CPDistributedMessagingCenter *c = [CPDistributedMessagingCenter centerNamed:@"com.YungRaj.streaknotifyd"];
    rocketbootstrap_distributedmessagingcenter_apply(c);
    [c sendMessageName:@"applicationLaunched" userInfo:nil];
    
    SNLog(@"StreakNotify:: Sending a Friendmoji to the Daemon :)");
    @try {
        SendFriendmojisToDaemon();
    }
    @catch (NSException *exception) {
        SNLog(@"StreakNotify::SendFriendmojisToDaemon failed %@", exception.reason);
    }

    return %orig();
}

-(void)application:(UIApplication *)application
didReceiveRemoteNotification:(NSDictionary *)userInfo
fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler{
    /* Update LocalNotifications when a RemoteNotification is received */
    LoadPreferences();
    %orig();
}

-(void)application:(UIApplication *)application
didReceiveLocalNotification:(UILocalNotification *)notification{
    LoadPreferences();
    %orig();
}
%end

static NSTimer *_labelTimer = nil;
static NSMutableArray *feedCells = nil;
static NSMutableArray *feedCellLabels = nil;

static void ReconfigureCells() {
    if (feedCells) {
	    dispatch_async(dispatch_get_main_queue(), ^{
	        for(SCFeedSwipeableTableViewCell *cell in feedCells){
	            ConfigureCell(cell, feedCells, feedCellLabels);
	        }
	    });
	}
}

%hook SCCheetahFeedViewController

-(void)viewDidLoad{
	%orig();

    if (!feedCells) {
        feedCells = [[NSMutableArray alloc] init];
    } 
    if (!feedCellLabels) {
        feedCellLabels = [[NSMutableArray alloc] init];
    }

	_labelTimer = [NSTimer scheduledTimerWithTimeInterval:20.0 target:[NSBlockOperation blockOperationWithBlock:^{
        SNLog(@"StreakNotify::Timer going off :)");
        ReconfigureCells();
	}] selector:@selector(main) userInfo:nil repeats:YES];

	SNLog(@"StreakNotify::Label timer scheduled: %@", _labelTimer);
}	


-(UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath{
    /*
     *  updating tableview and we want to make sure the feedCellLabels are updated too, if not
     *  created if the feed is now being populated
     */
    
    SCFeedSwipeableTableViewCell *cell = (SCFeedSwipeableTableViewCell*) %orig(tableView,indexPath);
    dispatch_async(dispatch_get_main_queue(), ^{
        /*
         *  Do this on the main thread because all UI updates should be done on the main
         *  thread
         *  This should already be on the main thread but we should make sure of this
         */

        ConfigureCell(cell, feedCells, feedCellLabels);
    });

    return cell;
}

-(void)pullToRefreshDidFinish:(id)arg{
    %orig();
    SNLog(@"StreakNotify::Finished reloading data");
    ReconfigureCells();
    ScheduleNotifications();
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig();
    SNLog(@"StreakNotify::View disappeared");

    // Stop the timer when we leave
    [_labelTimer invalidate];
    _labelTimer = nil;
}

- (void)dealloc {
	%orig();
    SNLog(@"StreakNotify::Deallocating label timer");

    [_labelTimer invalidate];
}

%end


%end // end group SnapchatHooks


%ctor
{
    /*
     *  Coming from MobileLoader, which loads into Snapchat via the DYLD_INSERT_LIBRARIES
     *  variable. Let's start doing some fun hooks into Snapchat to keep the streak going
     *  I don't know why I made this, I just found that people took streaks seriously, so
     *  might as well. A tweak like this isn't that serious so why not make it open source
     */
    
    LoadPreferences();
    if(![prefs[@"kStreakNotifyDisabled"] boolValue]){
        %init(SnapchatHooks);
    }
}
