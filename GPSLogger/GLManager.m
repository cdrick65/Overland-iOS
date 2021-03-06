//
//  GLManager.m
//  GPSLogger
//
//  Created by Aaron Parecki on 9/17/15.
//  Copyright © 2015 Esri. All rights reserved.
//  Copyright © 2017 Aaron Parecki. All rights reserved.
//

#import "GLManager.h"
#import "AFHTTPSessionManager.h"
#import "LOLDatabase.h"
#import "FMDatabase.h"
#import "SystemConfiguration/CaptiveNetwork.h"
@import UserNotifications;

@interface GLManager()

@property (strong, nonatomic) CLLocationManager *locationManager;
@property (strong, nonatomic) CMMotionActivityManager *motionActivityManager;
@property (strong, nonatomic) CMPedometer *pedometer;

@property BOOL trackingEnabled;
@property BOOL sendInProgress;
@property BOOL batchInProgress;
@property (strong, nonatomic) CLLocation *lastLocation;
@property (strong, nonatomic) CMMotionActivity *lastMotion;
@property (strong, nonatomic) NSDate *lastSentDate;
@property (strong, nonatomic) NSString *lastLocationName;

@property (strong, nonatomic) NSDictionary *lastLocationDictionary;
@property (strong, nonatomic) NSDictionary *tripStartLocationDictionary;

@property (strong, nonatomic) LOLDatabase *db;
@property (strong, nonatomic) FMDatabase *tripdb;

@property (strong, nonatomic) NSTimer *flightTrackerTimer;

@end

@implementation GLManager

static NSString *const GLLocationQueueName = @"GLLocationQueue";

NSNumber *_sendingInterval;
NSArray *_tripModes;
bool _currentTripHasNewData;
bool _storeNextLocationAsTripStart = NO;
int _pointsPerBatch;
long _currentPointsInQueue;
NSString *_deviceId;
CLLocationDistance _currentTripDistanceCached;
AFHTTPSessionManager *_httpClient;

const double FEET_TO_METERS = 0.304;
const double MPH_to_METERSPERSECOND = 0.447;

// Keep track of whether location updates were stopped by the in-flight tracker
bool _stoppedFromInFlightTracker = NO;
AFHTTPSessionManager *_flightHTTPClient;

+ (GLManager *)sharedManager {
    static GLManager *_instance = nil;
    
    @synchronized (self) {
        if (_instance == nil) {
            _instance = [[self alloc] init];
            
            _instance.db = [[LOLDatabase alloc] initWithPath:[self cacheDatabasePath]];
            _instance.db.serializer = ^(id object){
                return [self dataWithJSONObject:object error:NULL];
            };
            _instance.db.deserializer = ^(NSData *data) {
                return [self objectFromJSONData:data error:NULL];
            };
            
            _instance.tripdb = [FMDatabase databaseWithPath:[self tripDatabasePath]];
            [_instance setUpTripDB];
            
            [_instance setupHTTPClient];
            [_instance restoreTrackingState];
            [_instance initializeNotifications];
            [_instance startFlightTrackerTimer];
        }
    }
    
    return _instance;
}

#pragma mark - GLManager control (public)

- (void)saveNewAPIEndpoint:(NSString *)endpoint {
    [[NSUserDefaults standardUserDefaults] setObject:endpoint forKey:GLAPIEndpointDefaultsName];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self setupHTTPClient];
}

- (NSString *)apiEndpointURL {
    return [[NSUserDefaults standardUserDefaults] stringForKey:GLAPIEndpointDefaultsName];
}

- (void)saveNewDeviceId:(NSString *)deviceId {
    _deviceId = deviceId;
    [[NSUserDefaults standardUserDefaults] setObject:deviceId forKey:GLDeviceIdDefaultsName];
    // Always call saveNewAPIEndpoint after saveNewDeviceId to synchronize changes
}

- (NSString *)deviceId {
    NSString *d = [[NSUserDefaults standardUserDefaults] stringForKey:GLDeviceIdDefaultsName];
    if(d == nil) {
        d = @"";
    }
    return d;
}

- (void)startAllUpdates {
    [self enableTracking];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:GLTrackingStateDefaultsName];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)stopAllUpdates {
    [self disableTracking];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:GLTrackingStateDefaultsName];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)refreshLocation {
    NSLog(@"Trying to update location now");
    [self.locationManager stopUpdatingLocation];
    [self.locationManager performSelector:@selector(startUpdatingLocation) withObject:nil afterDelay:1.0];
}

- (void)sendQueueNow {
    NSMutableSet *syncedUpdates = [NSMutableSet set];
    NSMutableArray *locationUpdates = [NSMutableArray array];
    
    NSString *endpoint = [[NSUserDefaults standardUserDefaults] stringForKey:GLAPIEndpointDefaultsName];
    
    if(endpoint == nil) {
        NSLog(@"No API endpoint is set, not sending data");
        return;
    }
    
    __block long _numInQueue = 0;
    
    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        
        [accessor enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *object) {
            if(key && object) {
                [syncedUpdates addObject:key];
                [locationUpdates addObject:object];
            } else if(key) {
                // Remove nil objects
                [accessor removeDictionaryForKey:key];
            }
            return (BOOL)(locationUpdates.count >= _pointsPerBatch);
        }];
        
        [accessor countObjectsUsingBlock:^(long num) {
            _numInQueue = num;
        }];
    }];
    
    NSMutableDictionary *postData = [NSMutableDictionary dictionaryWithDictionary:@{@"locations": locationUpdates}];

    // If there are still more in the queue, then send the current location as a separate property.
    // This allows the server to know where the user is immediately even if there are many thousands of points in the backlog.
    if(_numInQueue > self.pointsPerBatch && self.lastLocation) {
        NSDictionary *currentLocation = [self currentDictionaryFromLocation:self.lastLocation];
        [postData setObject:currentLocation forKey:@"current"];
    }
    
    if(self.tripInProgress) {
        NSDictionary *currentTripInfo = [self currentTripDictionary];
        [postData setObject:currentTripInfo forKey:@"trip"];
    }

    NSLog(@"Endpoint: %@", endpoint);
    NSLog(@"Updates in post: %lu", (unsigned long)locationUpdates.count);
    
    if(locationUpdates.count == 0) {
        self.batchInProgress = NO;
        return;
    }
    
    [self sendingStarted];
    
    [_httpClient POST:endpoint parameters:postData progress:NULL success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSLog(@"Response: %@", responseObject);
        
        if([responseObject objectForKey:@"result"] && [[responseObject objectForKey:@"result"] isEqualToString:@"ok"]) {
            self.lastSentDate = NSDate.date;
            NSDictionary *geocode = [responseObject objectForKey:@"geocode"];
            if(geocode && ![geocode isEqual:[NSNull null]]) {
                self.lastLocationName = [geocode objectForKey:@"full_name"];
            } else {
                self.lastLocationName = @"";
            }
            
            [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
                for(NSString *key in syncedUpdates) {
                    [accessor removeDictionaryForKey:key];
                }
            }];

            [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
                [accessor countObjectsUsingBlock:^(long num) {
                    _currentPointsInQueue = num;
                    NSLog(@"Number remaining: %ld", num);
                    if(num >= _pointsPerBatch) {
                        self.batchInProgress = YES;
                    } else {
                        self.batchInProgress = NO;
                    }
                }];

                [self sendingFinished];
            }];
            
        } else {
            
            self.batchInProgress = NO;
            
            if([responseObject objectForKey:@"error"]) {
                [self notify:[responseObject objectForKey:@"error"] withTitle:@"HTTP Error"];
                [self sendingFinished];
            } else {
                [self notify:@"Server did not acknowledge the data was received, and did not return an error message" withTitle:@"HTTP Error"];
                [self sendingFinished];
            }
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        self.batchInProgress = NO;
        [self notify:error.localizedDescription withTitle:@"HTTP Error"];
        [self sendingFinished];
    }];
    
}

- (void)logAction:(NSString *)action {
    if(!self.includeTrackingStats) {
        return;
    }

    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        NSString *timestamp = [GLManager iso8601DateStringFromDate:[NSDate date]];
        NSMutableDictionary *update = [NSMutableDictionary dictionaryWithDictionary:@{
                                                                                      @"type": @"Feature",
                                                                                      @"properties": @{
                                                                                              @"timestamp": timestamp,
                                                                                              @"action": action,
                                                                                              @"battery_state": [self currentBatteryState],
                                                                                              @"battery_level": [self currentBatteryLevel],
                                                                                              @"wifi": [GLManager currentWifiHotSpotName],
                                                                                              @"device_id": _deviceId
                                                                                              }
                                                                                      }];
        if(self.lastLocation) {
            [update setObject:@{
                                @"type": @"Point",
                                @"coordinates": @[
                                        [NSNumber numberWithDouble:self.lastLocation.coordinate.longitude],
                                        [NSNumber numberWithDouble:self.lastLocation.coordinate.latitude]
                                        ]
                                } forKey:@"geometry"];
        }
        [accessor setDictionary:update forKey:[NSString stringWithFormat:@"%@-log", timestamp]];
    }];
}

- (void)accountInfo:(void(^)(NSString *name))block {
    NSString *endpoint = [[NSUserDefaults standardUserDefaults] stringForKey:GLAPIEndpointDefaultsName];
    [_httpClient GET:endpoint parameters:nil progress:NULL success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        NSDictionary *dict = (NSDictionary *)responseObject;
        block((NSString *)[dict objectForKey:@"name"]);
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        NSLog(@"Failed to get account info");
    }];
}

- (void)numberOfLocationsInQueue:(void(^)(long num))callback {
    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        [accessor countObjectsUsingBlock:^(long num) {
            _currentPointsInQueue = num;
            callback(num);
        }];
    }];
}

- (void)numberOfObjectsInQueue:(void(^)(long locations, long trips, long stats))callback {
    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        __block long locations = 0;
        __block long trips = 0;
        __block long stats = 0;
        [accessor enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *object) {
            NSDictionary *properties = [object objectForKey:@"properties"];
            if([properties objectForKey:@"action"]) {
                stats++;
            } else if([[properties objectForKey:@"type"] isEqualToString:@"trip"]) {
                trips++;
            } else {
                locations++;
            }
            return NO;
        }];
        //NSLog(@"Queue stats: %ld %ld %ld", locations, trips, stats);
        callback(locations, trips, stats);
    }];
}

#pragma mark - GLManager control (private)

- (void)setupHTTPClient {
    NSURL *endpoint = [NSURL URLWithString:[[NSUserDefaults standardUserDefaults] stringForKey:GLAPIEndpointDefaultsName]];
    
    if(endpoint) {
        _httpClient = [[AFHTTPSessionManager manager] initWithBaseURL:[NSURL URLWithString:[NSString stringWithFormat:@"%@://%@", endpoint.scheme, endpoint.host]]];
        _httpClient.requestSerializer = [AFJSONRequestSerializer serializer];
        _httpClient.responseSerializer = [AFJSONResponseSerializer serializer];
    }
    
    _flightHTTPClient = [[AFHTTPSessionManager manager] init];
    _flightHTTPClient.responseSerializer = [AFJSONResponseSerializer serializer];
    
    _deviceId = [self deviceId];
}

- (void)restoreTrackingState {
    if([[NSUserDefaults standardUserDefaults] boolForKey:GLTrackingStateDefaultsName]) {
        [self enableTracking];
        if(self.tripInProgress) {
            // If a trip is in progress, open the trip DB now
            [self.tripdb open];
        }
    } else {
        [self disableTracking];
    }
}

- (void)enableTracking {
    self.trackingEnabled = YES;
    [self.locationManager requestAlwaysAuthorization];
    [self.locationManager startUpdatingLocation];
    [self.locationManager startUpdatingHeading];
    [self.locationManager startMonitoringVisits];
    if(self.significantLocationMode != kGLSignificantLocationDisabled) {
        [self.locationManager startMonitoringSignificantLocationChanges];
        NSLog(@"Monitoring significant location changes");
    }
    
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    
    if(CMMotionActivityManager.isActivityAvailable) {
        [self.motionActivityManager startActivityUpdatesToQueue:[NSOperationQueue mainQueue] withHandler:^(CMMotionActivity *activity) {
            self.lastMotion = activity;
            [[NSNotificationCenter defaultCenter] postNotificationName:GLNewDataNotification object:self];
        }];
    }
    
    _pointsPerBatch = self.pointsPerBatch;
    
    // Set the last location if location manager has a last location.
    // This will be set for example when the app launches due to a signification location change,
    // the locationmanager has a location already before a location event is delivered to the delegate.
    if(self.locationManager.location) {
        self.lastLocation = self.locationManager.location;
    }
}

- (void)disableTracking {
    self.trackingEnabled = NO;
    [UIDevice currentDevice].batteryMonitoringEnabled = NO;
    [self.locationManager stopMonitoringVisits];
    [self.locationManager stopUpdatingHeading];
    [self.locationManager stopUpdatingLocation];
    [self.locationManager stopMonitoringSignificantLocationChanges];
    if(CMMotionActivityManager.isActivityAvailable) {
        [self.motionActivityManager stopActivityUpdates];
        self.lastMotion = nil;
    }
}

- (void)sendingStarted {
    self.sendInProgress = YES;
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSendingStartedNotification object:self];
}

- (void)sendingFinished {
    self.sendInProgress = NO;
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSendingFinishedNotification object:self];
}

- (void)sendQueueIfTimeElapsed {
    BOOL sendingEnabled = [self.sendingInterval integerValue] > -1;
    if(!sendingEnabled) {
        return;
    }
    
    if(self.sendInProgress) {
        NSLog(@"Send is already in progress");
        return;
    }
    
    BOOL timeElapsed = [(NSDate *)[self.lastSentDate dateByAddingTimeInterval:[self.sendingInterval doubleValue]] compare:NSDate.date] == NSOrderedAscending;

    // Send if time has elapsed,
    // or if we're in the middle of flushing
    if(timeElapsed || self.batchInProgress) {
        NSLog(@"Sending a batch now");
        [self sendQueueNow];
        self.lastSentDate = NSDate.date;
    }
}

- (void)sendQueueIfNotInProgress {
    if(self.sendInProgress) {
        return;
    }
    
    [self sendQueueNow];
    self.lastSentDate = NSDate.date;
}

#pragma mark - Trips

+ (NSArray *)GLTripModes {
    if(!_tripModes) {
        _tripModes = @[GLTripModeWalk, GLTripModeRun, GLTripModeBicycle,
                       GLTripModeCar, GLTripModeCar2go, GLTripModeTaxi,
                       GLTripModeBus, GLTripModeTrain, GLTripModePlane,
                       GLTripModeTram, GLTripModeMetro, GLTripModeBoat];
        }
    return _tripModes;
}

- (BOOL)tripInProgress {
    return [[NSUserDefaults standardUserDefaults] objectForKey:GLTripStartTimeDefaultsName] != nil;
}

- (NSString *)currentTripMode {
    NSString *mode = [[NSUserDefaults standardUserDefaults] stringForKey:GLTripModeDefaultsName];
    if(!mode) {
        mode = @"bicycle";
    }
    return mode;
}

- (void)setCurrentTripMode:(NSString *)mode {
    [[NSUserDefaults standardUserDefaults] setObject:mode forKey:GLTripModeDefaultsName];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSDate *)currentTripStart {
    if(!self.tripInProgress) {
        return nil;
    }
    return (NSDate *)[[NSUserDefaults standardUserDefaults] objectForKey:GLTripStartTimeDefaultsName];
}

- (NSTimeInterval)currentTripDuration {
    if(!self.tripInProgress) {
        return -1;
    }
    
    NSDate *startDate = self.currentTripStart;
    return [startDate timeIntervalSinceNow] * -1.0;
}

- (CLLocationDistance)currentTripDistance {
    if(!self.tripInProgress) {
        return -1;
    }
    
    if(!_currentTripHasNewData) {
        return _currentTripDistanceCached;
    }

    CLLocationDistance distance = 0;
    CLLocation *lastLocation;
    CLLocation *loc;
    
    FMResultSet *s = [self.tripdb executeQuery:@"SELECT latitude, longitude FROM trips ORDER BY timestamp"];
    while([s next]) {
        loc = [[CLLocation alloc] initWithLatitude:[s doubleForColumnIndex:0] longitude:[s doubleForColumnIndex:1]];
        
        if(lastLocation) {
            distance += [lastLocation distanceFromLocation:loc];
        }
        
        lastLocation = loc;
    }
    
    return distance;
}

- (NSDictionary *)currentTripStartLocationDictionary {
    if(!self.tripInProgress) {
        self.tripStartLocationDictionary = nil;
        return nil;
    }
    if(self.tripStartLocationDictionary == nil) {
        NSDictionary *startLocation = (NSDictionary *)[[NSUserDefaults standardUserDefaults] objectForKey:GLTripStartLocationDefaultsName];
        self.tripStartLocationDictionary = startLocation;
    }
    return self.tripStartLocationDictionary;
}

- (NSDictionary *)currentTripDictionary {
    return @{
            @"mode": self.currentTripMode,
            @"start": [GLManager iso8601DateStringFromDate:self.currentTripStart],
            @"distance": [NSNumber numberWithDouble:self.currentTripDistance],
            @"start_location": (self.currentTripStartLocationDictionary ?: [NSNull null]),
            @"current_location": (self.lastLocationDictionary ?: [NSNull null]),
    };
}

- (void)startTrip {
    if(self.tripInProgress) {
        return;
    }
    
    NSDate *startDate = [NSDate date];
    [[NSUserDefaults standardUserDefaults] setObject:startDate forKey:GLTripStartTimeDefaultsName];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    _storeNextLocationAsTripStart = YES;
    NSLog(@"Store next location as trip start. Current trip start: %@", self.tripStartLocationDictionary);

    [self.tripdb open];
    _currentTripDistanceCached = 0;
    _currentTripHasNewData = NO;
    
    NSLog(@"Started a trip");
}

- (void)endTrip {
    [self endTripFromAutopause:NO];
}

- (void)endTripFromAutopause:(BOOL)autopause {
    _storeNextLocationAsTripStart = NO;

    if(!self.tripInProgress) {
        return;
    }

    /*
    if((false) && [CMPedometer isStepCountingAvailable]) {
        [self.pedometer queryPedometerDataFromDate:self.currentTripStart toDate:[NSDate date] withHandler:^(CMPedometerData *pedometerData, NSError *error) {
            if(pedometerData) {
                [self writeTripToDB:autopause steps:[pedometerData.numberOfSteps integerValue]];
            } else {
                [self writeTripToDB:autopause steps:0];
            }
        }];
    } else {
     */
        [self writeTripToDB:autopause steps:0];
    // }
    
    self.tripStartLocationDictionary = nil;
    [[NSUserDefaults standardUserDefaults] setObject:nil forKey:GLTripStartTimeDefaultsName];
    [[NSUserDefaults standardUserDefaults] setObject:nil forKey:GLTripStartLocationDefaultsName];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)writeTripToDB:(BOOL)autopause steps:(NSInteger)numberOfSteps {
    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        NSString *timestamp = [GLManager iso8601DateStringFromDate:[NSDate date]];
        NSDictionary *currentTrip = @{
                                      @"type": @"Feature",
                                      @"geometry": @{
                                              @"type": @"Point",
                                              @"coordinates": @[
                                                      [NSNumber numberWithDouble:self.lastLocation.coordinate.longitude],
                                                      [NSNumber numberWithDouble:self.lastLocation.coordinate.latitude]
                                                      ]
                                              },
                                      @"properties": @{
                                              @"timestamp": timestamp,
                                              @"type": @"trip",
                                              @"mode": self.currentTripMode,
                                              @"start": [GLManager iso8601DateStringFromDate:self.currentTripStart],
                                              @"end": timestamp,
                                              @"start_location": (self.tripStartLocationDictionary ?: [NSNull null]),
                                              @"end_location":(self.lastLocationDictionary ?: [NSNull null]),
                                              @"duration": [NSNumber numberWithDouble:self.currentTripDuration],
                                              @"distance": [NSNumber numberWithDouble:self.currentTripDistance],
                                              @"stopped_automatically": @(autopause),
                                              @"steps": [NSNumber numberWithInteger:numberOfSteps],
                                              @"wifi": [GLManager currentWifiHotSpotName],
                                              @"device_id": _deviceId
                                              }
                                      };
        if(autopause) {
            [self notify:@"Trip ended automatically" withTitle:@"Tracker"];
        }
        [accessor setDictionary:currentTrip forKey:[NSString stringWithFormat:@"%@-trip",timestamp]];
    }];
    
    _currentTripDistanceCached = 0;
    [self clearTripDB];
    [self.tripdb close];
    
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:GLTripStartTimeDefaultsName];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"Ended a %@ trip", self.currentTripMode);
}

#pragma mark - Properties

- (CLLocationManager *)locationManager {
    if (!_locationManager) {
        _locationManager = [[CLLocationManager alloc] init];
        _locationManager.delegate = self;
        _locationManager.desiredAccuracy = self.desiredAccuracy;
        _locationManager.distanceFilter = 1;
        _locationManager.allowsBackgroundLocationUpdates = YES;
        _locationManager.pausesLocationUpdatesAutomatically = self.pausesAutomatically;
        _locationManager.activityType = self.activityType;
    }
    
    return _locationManager;
}

- (CMMotionActivityManager *)motionActivityManager {
    if (!_motionActivityManager) {
        _motionActivityManager = [[CMMotionActivityManager alloc] init];
    }
    
    return _motionActivityManager;
}

- (NSString *)currentBatteryState {
    switch([UIDevice currentDevice].batteryState) {
        case UIDeviceBatteryStateUnknown:
            return @"unknown";
        case UIDeviceBatteryStateCharging:
            return @"charging";
        case UIDeviceBatteryStateFull:
            return @"full";
        case UIDeviceBatteryStateUnplugged:
            return @"unplugged";
    }
}

- (NSNumber *)currentBatteryLevel {
    return [NSNumber numberWithFloat:[UIDevice currentDevice].batteryLevel];
}

#pragma mark CLLocationManager

- (NSSet *)monitoredRegions {
    return self.locationManager.monitoredRegions;
}

- (BOOL)pausesAutomatically {
    if([self defaultsKeyExists:GLPausesAutomaticallyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLPausesAutomaticallyDefaultsName];
    } else {
        return NO;
    }
}
- (void)setPausesAutomatically:(BOOL)pausesAutomatically {
    [[NSUserDefaults standardUserDefaults] setBool:pausesAutomatically forKey:GLPausesAutomaticallyDefaultsName];
    [[NSUserDefaults standardUserDefaults] synchronize];
    self.locationManager.pausesLocationUpdatesAutomatically = pausesAutomatically;
}

- (BOOL)includeTrackingStats {
    if([self defaultsKeyExists:GLIncludeTrackingStatsDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLIncludeTrackingStatsDefaultsName];
    } else {
        return NO;
    }
}
- (void)setIncludeTrackingStats:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:GLIncludeTrackingStatsDefaultsName];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (CLLocationDistance)resumesAfterDistance {
    if([self defaultsKeyExists:GLResumesAutomaticallyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLResumesAutomaticallyDefaultsName];
    } else {
        return -1;
    }
}
- (void)setResumesAfterDistance:(CLLocationDistance)resumesAfterDistance {
    [[NSUserDefaults standardUserDefaults] setDouble:resumesAfterDistance forKey:GLResumesAutomaticallyDefaultsName];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (GLSignificantLocationMode)significantLocationMode {
    if([self defaultsKeyExists:GLSignificantLocationModeDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLSignificantLocationModeDefaultsName];
    } else {
        return kGLSignificantLocationDisabled;
    }
}
- (void)setSignificantLocationMode:(GLSignificantLocationMode)significantLocationMode {
    [[NSUserDefaults standardUserDefaults] setInteger:significantLocationMode forKey:GLSignificantLocationModeDefaultsName];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if(significantLocationMode != kGLSignificantLocationDisabled) {
        [self.locationManager startMonitoringSignificantLocationChanges];
    } else {
        [self.locationManager stopMonitoringSignificantLocationChanges];
    }
}

- (CLActivityType)activityType {
    if([self defaultsKeyExists:GLActivityTypeDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] integerForKey:GLActivityTypeDefaultsName];
    } else {
        return CLActivityTypeOther;
    }
}
- (void)setActivityType:(CLActivityType)activityType {
    [[NSUserDefaults standardUserDefaults] setInteger:activityType forKey:GLActivityTypeDefaultsName];
    [[NSUserDefaults standardUserDefaults] synchronize];
    self.locationManager.activityType = activityType;
}

- (CLLocationAccuracy)desiredAccuracy {
    if([self defaultsKeyExists:GLDesiredAccuracyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLDesiredAccuracyDefaultsName];
    } else {
        return kCLLocationAccuracyHundredMeters;
    }
}
- (void)setDesiredAccuracy:(CLLocationAccuracy)desiredAccuracy {
    NSLog(@"Setting desiredAccuracy: %f", desiredAccuracy);
    [[NSUserDefaults standardUserDefaults] setDouble:desiredAccuracy forKey:GLDesiredAccuracyDefaultsName];
    [[NSUserDefaults standardUserDefaults] synchronize];
    self.locationManager.desiredAccuracy = desiredAccuracy;
}

- (CLLocationDistance)defersLocationUpdates {
    if([self defaultsKeyExists:GLDefersLocationUpdatesDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLDefersLocationUpdatesDefaultsName];
    } else {
        return 0;
    }
}
- (void)setDefersLocationUpdates:(CLLocationDistance)distance {
    [[NSUserDefaults standardUserDefaults] setDouble:distance forKey:GLDefersLocationUpdatesDefaultsName];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if(distance > 0) {
        [self.locationManager allowDeferredLocationUpdatesUntilTraveled:distance timeout:[self.sendingInterval doubleValue]];
    } else {
        [self.locationManager disallowDeferredLocationUpdates];
    }
}

- (int)pointsPerBatch {
    if([self defaultsKeyExists:GLPointsPerBatchDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLPointsPerBatchDefaultsName];
    } else {
        return 200;
    }
}
- (void)setPointsPerBatch:(int)points {
    [[NSUserDefaults standardUserDefaults] setInteger:points forKey:GLPointsPerBatchDefaultsName];
    [[NSUserDefaults standardUserDefaults] synchronize];
    _pointsPerBatch = points;
}


#pragma mark GLManager

- (NSNumber *)sendingInterval {
    if(_sendingInterval)
        return _sendingInterval;
    
    _sendingInterval = (NSNumber *)[[NSUserDefaults standardUserDefaults] valueForKey:GLSendIntervalDefaultsName];
    if(_sendingInterval == nil) {
        _sendingInterval = [NSNumber numberWithInteger:300];
    }
    return _sendingInterval;
}

- (void)setSendingInterval:(NSNumber *)newValue {
    [[NSUserDefaults standardUserDefaults] setValue:newValue forKey:GLSendIntervalDefaultsName];
    [[NSUserDefaults standardUserDefaults] synchronize];
    _sendingInterval = newValue;
}

- (NSDate *)lastSentDate {
    return (NSDate *)[[NSUserDefaults standardUserDefaults] objectForKey:GLLastSentDateDefaultsName];
}

- (void)setLastSentDate:(NSDate *)lastSentDate {
    [[NSUserDefaults standardUserDefaults] setObject:lastSentDate forKey:GLLastSentDateDefaultsName];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - CLLocationManager Delegate Methods

- (void)locationManager:(CLLocationManager *)manager didVisit:(CLVisit *)visit {
    [[NSNotificationCenter defaultCenter] postNotificationName:GLNewDataNotification object:self];

    if(self.includeTrackingStats) {
        NSLog(@"Got a visit event: %@", visit);
        
        [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
            NSString *timestamp = [GLManager iso8601DateStringFromDate:[NSDate date]];
            NSDictionary *update = @{
                                      @"type": @"Feature",
                                      @"geometry": @{
                                              @"type": @"Point",
                                              @"coordinates": @[
                                                      [NSNumber numberWithDouble:visit.coordinate.longitude],
                                                      [NSNumber numberWithDouble:visit.coordinate.latitude]
                                                      ]
                                              },
                                      @"properties": @{
                                              @"timestamp": timestamp,
                                              @"action": @"visit",
                                              @"arrival_date": ([visit.arrivalDate isEqualToDate:[NSDate distantPast]] ? [NSNull null] : [GLManager iso8601DateStringFromDate:visit.arrivalDate]),
                                              @"departure_date": ([visit.departureDate isEqualToDate:[NSDate distantFuture]] ? [NSNull null] : [GLManager iso8601DateStringFromDate:visit.departureDate]),
                                              @"horizontal_accuracy": [NSNumber numberWithInt:visit.horizontalAccuracy],
                                              @"battery_state": [self currentBatteryState],
                                              @"battery_level": [self currentBatteryLevel],
                                              @"wifi": [GLManager currentWifiHotSpotName],
                                              @"device_id": _deviceId
                                              }
                                    };
            [accessor setDictionary:update forKey:[NSString stringWithFormat:@"%@-visit", timestamp]];
        }];

    }
    [self sendQueueIfTimeElapsed];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations {
    [[NSNotificationCenter defaultCenter] postNotificationName:GLNewDataNotification object:self];
    self.lastLocation = (CLLocation *)locations[locations.count-1];
    self.lastLocationDictionary = [self currentDictionaryFromLocation:self.lastLocation];
    
    // NSLog(@"Received %d locations", (int)locations.count);
    
    // NSLog(@"%@", locations);
    
    // Queue the point in the database
    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        
        NSString *activityType = @"";
        switch([GLManager sharedManager].activityType) {
            case CLActivityTypeOther:
                activityType = @"other";
                break;
            case CLActivityTypeAutomotiveNavigation:
                activityType = @"automotive_navigation";
                break;
            case CLActivityTypeFitness:
                activityType = @"fitness";
                break;
            case CLActivityTypeOtherNavigation:
                activityType = @"other_navigation";
                break;
        }
        
        for(int i=0; i<locations.count; i++) {
            CLLocation *loc = locations[i];
            NSString *timestamp = [GLManager iso8601DateStringFromDate:loc.timestamp];
            NSDictionary *update = [self currentDictionaryFromLocation:loc];
            if(self.includeTrackingStats) {
                NSMutableDictionary *properties = [update objectForKey:@"properties"];
                [properties setValue:[NSNumber numberWithBool:self.locationManager.pausesLocationUpdatesAutomatically] forKey:@"pauses"];
                [properties setValue:activityType forKey:@"activity"];
                [properties setValue:[NSNumber numberWithDouble:self.locationManager.desiredAccuracy] forKey:@"desired_accuracy"];
                [properties setValue:[NSNumber numberWithDouble:self.defersLocationUpdates] forKey:@"deferred"];
                [properties setValue:[NSNumber numberWithInt:self.significantLocationMode] forKey:@"significant_change"];
                [properties setValue:[NSNumber numberWithLong:locations.count] forKey:@"locations_in_payload"];
            }
            [accessor setDictionary:update forKey:timestamp];
            
            if([loc.timestamp timeIntervalSinceDate:self.currentTripStart] >= 0  // only if the location is newer than the trip start
               && loc.horizontalAccuracy <= 200 // only if the location is accurate enough
               ) {

                if(_storeNextLocationAsTripStart) {
                    [[NSUserDefaults standardUserDefaults] setObject:update forKey:GLTripStartLocationDefaultsName];
                    self.tripStartLocationDictionary = update;
                    _storeNextLocationAsTripStart = NO;
                }
                
                // If a trip is in progress, add to the trip's list too (for calculating trip distance)
                if(self.tripInProgress) {
                    [self.tripdb executeUpdate:@"INSERT INTO trips (timestamp, latitude, longitude) VALUES (?, ?, ?)", [NSNumber numberWithInt:[loc.timestamp timeIntervalSince1970]], [NSNumber numberWithDouble:loc.coordinate.latitude], [NSNumber numberWithDouble:loc.coordinate.longitude]];
                    _currentTripHasNewData = YES;
                }
            }


        }
        
    }];
    
    [self sendQueueIfTimeElapsed];
}

- (NSDictionary *)currentDictionaryFromLocation:(CLLocation *)loc {
    NSString *timestamp = [GLManager iso8601DateStringFromDate:loc.timestamp];
    NSDictionary *update = @{
             @"type": @"Feature",
             @"geometry": @{
                     @"type": @"Point",
                     @"coordinates": @[
                             [NSNumber numberWithDouble:loc.coordinate.longitude],
                             [NSNumber numberWithDouble:loc.coordinate.latitude]
                             ]
                     },
             @"properties": [NSMutableDictionary dictionaryWithDictionary:@{
                     @"timestamp": timestamp,
                     @"altitude": [NSNumber numberWithInt:(int)round(loc.altitude)],
                     @"speed": [NSNumber numberWithInt:(int)round(loc.speed)],
                     @"horizontal_accuracy": [NSNumber numberWithInt:(int)round(loc.horizontalAccuracy)],
                     @"vertical_accuracy": [NSNumber numberWithInt:(int)round(loc.verticalAccuracy)],
                     @"motion": [self motionArrayFromLastMotion],
                     @"battery_state": [self currentBatteryState],
                     @"battery_level": [self currentBatteryLevel],
                     @"wifi": [GLManager currentWifiHotSpotName],
                     }]
             };
    if(_deviceId && _deviceId.length > 0) {
        NSMutableDictionary *properties = [update objectForKey:@"properties"];
        [properties setValue:_deviceId forKey:@"device_id"];
    }
    return update;
}

- (NSArray *)motionArrayFromLastMotion {
    NSMutableArray *motion = [[NSMutableArray alloc] init];
    CMMotionActivity *motionActivity = [GLManager sharedManager].lastMotion;
    if(motionActivity.walking)
        [motion addObject:@"walking"];
    if(motionActivity.running)
        [motion addObject:@"running"];
    if(motionActivity.cycling)
        [motion addObject:@"cycling"];
    if(motionActivity.automotive)
        [motion addObject:@"driving"];
    if(motionActivity.stationary)
        [motion addObject:@"stationary"];
    return [NSArray arrayWithArray:motion];
}

- (void)locationManagerDidPauseLocationUpdates:(CLLocationManager *)manager {
    [self logAction:@"paused_location_updates"];
    
    [self notify:@"Location updates paused" withTitle:@"Paused"];
    
    // Create an exit geofence to help it resume automatically
    if(self.resumesAfterDistance > 0) {
        CLCircularRegion *region = [[CLCircularRegion alloc] initWithCenter:self.lastLocation.coordinate radius:self.resumesAfterDistance identifier:@"resume-from-pause"];
        region.notifyOnEntry = NO;
        region.notifyOnExit = YES;
        [self.locationManager startMonitoringForRegion:region];
    }
    
    // Send the queue now to flush all remaining points
    [self sendQueueIfNotInProgress];
    
    // If a trip was in progress, stop it now
    if(self.tripInProgress) {
        [self endTripFromAutopause:YES];
    }
}

-(void)locationManager:(CLLocationManager *)manager didExitRegion:(CLRegion *)region {
    [self logAction:@"exited_pause_region"];
    [self notify:@"Starting updates from exiting the geofence" withTitle:@"Resumed"];
    [self.locationManager stopMonitoringForRegion:region];
    [self enableTracking];
}

- (void)locationManagerDidResumeLocationUpdates:(CLLocationManager *)manager {
    [self logAction:@"resumed_location_updates"];
    [self notify:@"Location updates resumed" withTitle:@"Resumed"];
}

- (void)locationManager:(CLLocationManager *)manager didFinishDeferredUpdatesWithError:(nullable NSError *)error {
    [self logAction:@"did_finish_deferred_updates"];
}

#pragma mark - AppDelegate Methods

- (void)applicationDidEnterBackground {
    // [self logAction:@"did_enter_background"];
}

- (void)applicationWillTerminate {
    [self logAction:@"will_terminate"];
}

- (void)applicationWillResignActive {
    // [self logAction:@"will_resign_active"];
}

#pragma mark - Notifications

- (BOOL)notificationsEnabled {
    if([self defaultsKeyExists:GLNotificationsEnabledDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLNotificationsEnabledDefaultsName];
    } else {
        return NO;
    }
}
- (void)setNotificationsEnabled:(BOOL)enabled {
    if(enabled) {
        [self requestNotificationPermission];
    } else {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:GLNotificationsEnabledDefaultsName];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:GLNotificationPermissionRequestedDefaultsName];
    }
}

- (void)initializeNotifications {
    UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];
    notificationCenter.delegate = self;
    
    // If notifications were successfully requested previously, initialize again for this app launch
    if([[NSUserDefaults standardUserDefaults] boolForKey:GLNotificationPermissionRequestedDefaultsName]) {
        [self requestNotificationPermission];
    }
}

- (void)requestNotificationPermission {
    UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];

    UNAuthorizationOptions options = UNAuthorizationOptionAlert + UNAuthorizationOptionSound;
    [notificationCenter requestAuthorizationWithOptions:options
                                      completionHandler:^(BOOL granted, NSError * _Nullable error) {
                                          // If the user denies permission, set requested=NO so that if they ever enable it in settings again the permission will be requested again
                                          [[NSUserDefaults standardUserDefaults] setBool:granted forKey:GLNotificationPermissionRequestedDefaultsName];
                                          [[NSUserDefaults standardUserDefaults] setBool:granted forKey:GLNotificationsEnabledDefaultsName];
                                          [[NSUserDefaults standardUserDefaults] synchronize];
                                          if(!granted) {
                                              NSLog(@"User did not allow notifications");
                                          }
                                      }];
}

- (void)notify:(NSString *)message withTitle:(NSString *)title
{
    if([self notificationsEnabled]) {
        UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];
        
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = title;
        content.body = message;
        content.sound = [UNNotificationSound defaultSound];
        
        /* UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:1 repeats:NO]; */
        
        NSString *identifier = @"GLLocalNotification";
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                              content:content
                                                                              trigger:nil];
        
        [notificationCenter addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
            if (error != nil) {
                NSLog(@"Something went wrong: %@",error);
            } else {
                NSLog(@"Notification sent");
            }
        }];
    }
}

/* Force notifications to display as normal when the app is active */
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    
    completionHandler(UNNotificationPresentationOptionAlert);
}

#pragma mark - In-Flight Tracker

/*

 The goal of this code is to use the in-flight GPS tracker if available.
 If the phone is connected to an in-flight wifi system like "gogoinflight", then
 it should attempt to retrieve the GPS data from the plane.
 When available, this should take precedence over the phone's own location services.
 
 If the currently connected wifi name is "gogoinflight",
 then attempt to fetch the GPS data URL.
 If data is available, then stop local location updates.
 If the request fails, start local location updates again.
 If the currently connected wifi name is not "gogoinflight" then start local updates.
 
*/
 
- (void)startFlightTrackerTimer {
    self.flightTrackerTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                               target:self
                                                             selector:@selector(retrieveCurrentFlightData)
                                                             userInfo:nil
                                                              repeats:NO];
}

- (void)retrieveCurrentFlightData {
    // Check if the current wifi name matches a known flight provider
    if(true || [@"gogoinflight" isEqualToString:[GLManager currentWifiHotSpotName]]) {

        // Make a request to the in-flight data URL
        NSString *endpoint = @"http://airborne.gogoinflight.com/abp/ws/absServices/statusTray";
        [_flightHTTPClient GET:endpoint parameters:NULL progress:NULL success:^(NSURLSessionDataTask * _Nonnull task, id _Nullable responseObject) {
            // If we got in-flight data, stop local updates
            _stoppedFromInFlightTracker = YES;
            [self disableTracking];

            // Record this data point
            NSDictionary *info = [[responseObject objectForKey:@"Response"] objectForKey:@"flightInfo"];
            
            _currentFlightSummary = [NSString stringWithFormat:@"%@ %@ to %@\nTail number %@",
                 [info valueForKey:@"flightNumberInfo"],
                 [info valueForKey:@"departureAirportCodeIata"],
                 [info valueForKey:@"destinationAirportCodeIata"],
                 [info valueForKey:@"tailNumber"]
            ];
            
            // Create a fake datapoint for the UI to grab
            CLLocation *loc = [self currentLocationFromGogoDictionary:info];
            
            self.lastLocation = loc;
            self.lastLocationDictionary = [self currentDictionaryFromGogoDictionary:info];
            _lastMotionString = @"flying";
            
            [self writeCurrentLocationToHistory];
            
            self.currentTripMode = @"plane";

            // Start a new timer to check again
            [self startFlightTrackerTimer];
        } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
            NSLog(@"Error retrieving in-flight data");
            [self _resetFlightTrackerAndStartAgain];
        }];
        
    } else {
        [self _resetFlightTrackerAndStartAgain];
    }
}

- (void)writeCurrentLocationToHistory {
    [[NSNotificationCenter defaultCenter] postNotificationName:GLNewDataNotification object:self];

    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        NSString *timestamp = [GLManager iso8601DateStringFromDate:self.lastLocation.timestamp];
        NSDictionary *update = self.lastLocationDictionary;
        [accessor setDictionary:update forKey:timestamp];
    }];
    
    if(self.tripInProgress) {
        [self.tripdb executeUpdate:@"INSERT INTO trips (timestamp, latitude, longitude) VALUES (?, ?, ?)", [NSNumber numberWithInt:[self.lastLocation.timestamp timeIntervalSince1970]], [NSNumber numberWithDouble:self.lastLocation.coordinate.latitude], [NSNumber numberWithDouble:self.lastLocation.coordinate.longitude]];
        _currentTripHasNewData = YES;
    }
}

- (NSDictionary *)currentDictionaryFromGogoDictionary:(NSDictionary *)info {
    double latitude = [(NSNumber *)[info valueForKey:@"latitude"] doubleValue];
    double longitude = [(NSNumber *)[info valueForKey:@"longitude"] doubleValue];
    
    // Create the dictionary with our standard properties
    NSMutableDictionary *properties = [NSMutableDictionary dictionaryWithDictionary:@{
                                                                                      @"timestamp": [info valueForKey:@"utcTime"],
                                                                                      @"altitude": [NSNumber numberWithDouble:([(NSNumber *)[info valueForKey:@"altitude"] doubleValue] * FEET_TO_METERS)],
                                                                                      @"speed": [NSNumber numberWithDouble:([(NSNumber *)[info valueForKey:@"hspeed"] doubleValue] * MPH_to_METERSPERSECOND)],
                                                                                      @"horizontal_accuracy": @11,
                                                                                      @"motion": @[@"flying"],
                                                                                      @"battery_state": [self currentBatteryState],
                                                                                      @"battery_level": [self currentBatteryLevel],
                                                                                      @"wifi": [GLManager currentWifiHotSpotName],
                                                                                      @"source": @"gogo",
                                                                                      @"flight_data": info,
                                                                                      }];
    
    NSDictionary *update = @{
                             @"type": @"Feature",
                             @"geometry": @{
                                     @"type": @"Point",
                                     @"coordinates": @[
                                             [NSNumber numberWithDouble:longitude],
                                             [NSNumber numberWithDouble:latitude]
                                             ]
                                     },
                             @"properties": properties
                             };
    
    return update;
}

- (CLLocation *)currentLocationFromGogoDictionary:(NSDictionary *)info {
    double latitude = [(NSNumber *)[info valueForKey:@"latitude"] doubleValue];
    double longitude = [(NSNumber *)[info valueForKey:@"longitude"] doubleValue];
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(latitude, longitude);
    NSDate *timestamp = NSDate.date; // TODO: parse the ISO8601 timestamp from info

    CLLocation *loc = [[CLLocation alloc] initWithCoordinate:coord
                                                    altitude:[(NSNumber *)[info valueForKey:@"altitude"] doubleValue] * FEET_TO_METERS
                                          horizontalAccuracy:11
                                            verticalAccuracy:11
                                                      course:0
                                                       speed:[(NSNumber *)[info valueForKey:@"hspeed"] doubleValue] * MPH_to_METERSPERSECOND
                                                   timestamp:timestamp];
    return loc;
}

- (void)_resetFlightTrackerAndStartAgain {
    // If we had previously stopped updates because we had in-flight data, start them again
    if(_stoppedFromInFlightTracker) {
        [self enableTracking];
        _stoppedFromInFlightTracker = NO;
    }
    _lastMotionString = nil;
    _currentFlightSummary = nil;
    // Check for in-flight data again soon
    [self startFlightTrackerTimer];
}

#pragma mark -

- (BOOL)defaultsKeyExists:(NSString *)key {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [[[defaults dictionaryRepresentation] allKeys] containsObject:key];
}

+ (NSString *)currentWifiHotSpotName {
    NSString *wifiName = @"";
    NSArray *ifs = (__bridge_transfer id)CNCopySupportedInterfaces();
    for (NSString *ifnam in ifs) {
        NSDictionary *info = (__bridge_transfer id)CNCopyCurrentNetworkInfo((__bridge CFStringRef)ifnam);
        if (info[@"SSID"]) {
            wifiName = info[@"SSID"];
        }
    }
    return wifiName;
}

#pragma mark - FMDB

+ (NSString *)tripDatabasePath {
    NSString *docsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    return [docsPath stringByAppendingPathComponent:@"trips.sqlite"];
}

- (void)setUpTripDB {
    [self.tripdb open];
    if(![self.tripdb executeUpdate:@"CREATE TABLE IF NOT EXISTS trips (\
       id INTEGER PRIMARY KEY AUTOINCREMENT, \
       timestamp INTEGER, \
       latitude REAL, \
       longitude REAL \
     )"]) {
        NSLog(@"Error creating trip DB: %@", self.tripdb.lastErrorMessage);
    }
    [self.tripdb close];
}

- (void)clearTripDB {
    [self.tripdb executeUpdate:@"DELETE FROM trips"];
}


#pragma mark - LOLDB

+ (NSString *)cacheDatabasePath
{
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    return [caches stringByAppendingPathComponent:@"GLLoggerCache.sqlite"];
}

+ (id)objectFromJSONData:(NSData *)data error:(NSError **)error;
{
    return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:error];
}

+ (NSData *)dataWithJSONObject:(id)object error:(NSError **)error;
{
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
}

+ (NSString *)iso8601DateStringFromDate:(NSDate *)date {
    struct tm *timeinfo;
    char buffer[80];
    
    time_t rawtime = (time_t)[date timeIntervalSince1970];
    timeinfo = gmtime(&rawtime);
    
    strftime(buffer, 80, "%Y-%m-%dT%H:%M:%SZ", timeinfo);
    
    return [NSString stringWithCString:buffer encoding:NSUTF8StringEncoding];
}

@end
