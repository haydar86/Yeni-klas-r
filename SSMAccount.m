//
//  SSMAccount.m
//  Sosumi
//
//  Created by Tyler Hall on 11/28/10.
//  Copyright 2010 Click On Tyler, LLC. All rights reserved.
//

#import "SSMAccount.h"
#import "SSMDevice.h"
#import "GTMHTTPFetcher.h"
#import "NSData+Base64.h"
#import "JSON.h"
#import "NetworkSpinner.h"

#define SINFO(title, subtitle)	[NSDictionary dictionaryWithObjectsAndKeys:title, @"title", subtitle, @"subtitle", nil]

@implementation SSMAccount 

@synthesize username;
@synthesize password;
@synthesize devices;
@synthesize partition;
@synthesize isUpdating;
@synthesize isRefreshing;
@synthesize treeNode;

- (id)init
{
	self = [super init];
	
	self.devices = [[NSMutableDictionary alloc] init];
    refreshTimerInterval = 10.0;

	return self;
}

- (NSString *)name
{
	return self.username;
}

- (NSString *)apiStringsForMethod:(NSString *)method
{
	NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"SosumiAPI" ofType:@"plist"]];
	return [dict valueForKey:method];
}

- (void)beginUpdatingDevices
{
	self.isUpdating = YES;
	refreshTimer = [[NSTimer alloc] initWithFireDate:[NSDate date] interval:refreshTimerInterval target:self selector:@selector(refresh) userInfo:nil repeats:YES];
	[[NSRunLoop mainRunLoop] addTimer:refreshTimer forMode:NSDefaultRunLoopMode];
}

- (void)stopUpdatingDevices
{
	self.isUpdating = NO;
	[refreshTimer invalidate];
}

- (void)refresh
{
	self.isRefreshing = YES;
	[NetworkSpinner queue];

	if(!self.partition) {
		[self getPartition];
		return;
	}

	GTMHTTPFetcher *fetcher = [self getPreparedFetcherWithMethod:@"initClient"];

	NSString *postStr = [self apiStringsForMethod:@"initClient"];
	[fetcher setPostData:[postStr dataUsingEncoding:NSUTF8StringEncoding]];

	[fetcher beginFetchWithCompletionHandler:^(NSData *retrievedData, NSError *error) {
		if(error != nil) {
			NSLog(@"%@", error);
			self.isRefreshing = NO;
			[NetworkSpinner dequeue];
		}
		else {
			NSDictionary *json = [[[NSString alloc] initWithData:retrievedData encoding:NSUTF8StringEncoding] JSONValue];
			// NSLog(@"%@", json);

            // So we don't get throttled for hammering.
            // https://github.com/tylerhall/MacSosumi/issues/8
            NSDictionary *serverContext = json[@"serverContext"];
            if(serverContext) {
                refreshTimerInterval = [[serverContext valueForKey:@"callbackIntervalInMS"] floatValue] / 1000;
            } else {
                refreshTimerInterval = 30.0;
            }
            
			NSArray *rawDevices = json[@"content"];
			if(rawDevices) {
				for(NSDictionary *rawDevice in rawDevices) {
					
					SSMDevice *device;
					BOOL found = NO;
					NSMutableArray *childNodes = [self.treeNode mutableChildNodes];
					for(int i = 0; i < [childNodes count]; i++) {
						if([[(SSMDevice *)[childNodes[i] representedObject] deviceId] isEqualToString:rawDevice[@"id"]]) {
							found = YES;
							device = [childNodes[i] representedObject]; 
							break;
						}
					}

					if(!found) {
						device = [[SSMDevice alloc] init];
					}

					device.parent = self;
					device.isLocating = [rawDevice[@"isLocating"] boolValue];
					device.deviceClass = rawDevice[@"deviceClass"];
					device.deviceModel = rawDevice[@"deviceModel"];
					device.deviceStatus = rawDevice[@"deviceStatus"];
					device.deviceId = rawDevice[@"id"];
					device.name = rawDevice[@"name"];
					device.isCharging = [(NSString *)rawDevice[@"batteryStatus"] isEqualToString:@"Charging"];
					device.batteryLevel = rawDevice[@"batteryLevel"];

					id location = rawDevice[@"location"];
					if(location != [NSNull null]) {
						device.locationTimestamp = [NSDate dateWithTimeIntervalSince1970:[(NSNumber *)[location valueForKey:@"timeStamp"] doubleValue] / 1000];
						device.locationType = location[@"positionType"];
						device.horizontalAccuracy = location[@"horizontalAccuracy"];
						device.locationFinished = [[location valueForKey:@"locationFinished"] boolValue];
						device.longitude = location[@"longitude"];
						device.latitude = location[@"latitude"];
					}
					[self.devices setValue:device forKey:device.deviceId];
					
					if(!found) {
						NSTreeNode *deviceTreeNode = [NSTreeNode treeNodeWithRepresentedObject:device];
						[[self.treeNode mutableChildNodes] addObject:deviceTreeNode];
					}
				}
			}
			self.isRefreshing = NO;
			[NetworkSpinner dequeue];
			[[NSNotificationCenter defaultCenter] postNotificationName:@"DEVICES_DID_UPDATE" object:self];
		}
	}];
}

- (void)getPartition
{
	GTMHTTPFetcher *fetcher = [self getPreparedFetcherWithMethod:@"initClient"];
	
	NSString *postStr = [self apiStringsForMethod:@"getPartition"];
	[fetcher setPostData:[postStr dataUsingEncoding:NSUTF8StringEncoding]];

	[fetcher beginFetchWithCompletionHandler:^(NSData *retrievedData, NSError *error) {
		if(error != nil) {
			if([[fetcher responseHeaders] valueForKey:@"X-Apple-MMe-Host"]) {
				self.partition = [[fetcher responseHeaders] valueForKey:@"X-Apple-MMe-Host"];
				[NetworkSpinner dequeue];
				[self refresh];
			} else {
				NSLog(@"Could not login to FMIP");
				self.isRefreshing = NO;
				[NetworkSpinner dequeue];
			}

		} else {
			NSLog(@"Could not login to FMIP");
			self.isRefreshing = NO;
			[NetworkSpinner dequeue];
		}
	}];
}

- (void)sendMessage:(NSString *)message withSubject:(NSString *)subject andAlarm:(BOOL)alarm toDevice:(NSString *)deviceId;
{
	GTMHTTPFetcher *fetcher = [self getPreparedFetcherWithMethod:@"sendMessage"];
	
	NSMutableString *postStr = [[self apiStringsForMethod:@"sendMessage"]  mutableCopy];
	[postStr replaceOccurrencesOfString:@"{{device}}" withString:deviceId options:NSCaseInsensitiveSearch range:NSMakeRange(0, [postStr length])];
	[postStr replaceOccurrencesOfString:@"{{subject}}" withString:subject options:NSCaseInsensitiveSearch range:NSMakeRange(0, [postStr length])];
	[postStr replaceOccurrencesOfString:@"{{message}}" withString:message options:NSCaseInsensitiveSearch range:NSMakeRange(0, [postStr length])];
	[postStr replaceOccurrencesOfString:@"{{alarm}}" withString:(alarm ? @"true" : @"false") options:NSCaseInsensitiveSearch range:NSMakeRange(0, [postStr length])];

	[fetcher setPostData:[postStr dataUsingEncoding:NSUTF8StringEncoding]];

	[NetworkSpinner queue];
	[fetcher beginFetchWithCompletionHandler:^(NSData *retrievedData, NSError *error) {
		[NetworkSpinner dequeue];
	}];
}

- (void)remoteLockDevice:(NSString *)deviceId withPasscode:(NSString *)passcode
{
	GTMHTTPFetcher *fetcher = [self getPreparedFetcherWithMethod:@"remoteLock"];
	
	NSMutableString *postStr = [[self apiStringsForMethod:@"remoteLock"]  mutableCopy];
	[postStr replaceOccurrencesOfString:@"{{device}}" withString:deviceId options:NSCaseInsensitiveSearch range:NSMakeRange(0, [postStr length])];
	[postStr replaceOccurrencesOfString:@"{{code}}" withString:passcode options:NSCaseInsensitiveSearch range:NSMakeRange(0, [postStr length])];

	[fetcher setPostData:[postStr dataUsingEncoding:NSUTF8StringEncoding]];

	[NetworkSpinner queue];
	[fetcher beginFetchWithCompletionHandler:^(NSData *retrievedData, NSError *error) {
		[NetworkSpinner dequeue];
	}];
}

- (GTMHTTPFetcher *)getPreparedFetcherWithMethod:(NSString *)method
{
	NSString *urlStr;

	if(!self.partition)
		urlStr = [NSString stringWithFormat:@"https://fmipmobile.icloud.com/fmipservice/device/%@/%@", self.username, method];
	else
		urlStr = [NSString stringWithFormat:@"https://%@/fmipservice/device/%@/%@", self.partition, self.username, method];

	NSURL *url = [NSURL URLWithString:urlStr];
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
	[request addValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
	[request addValue:@"2.0" forHTTPHeaderField:@"X-Apple-Find-Api-Ver"];
	[request addValue:@"UserIdGuest" forHTTPHeaderField:@"X-Apple-Authscheme"];
	[request addValue:@"1.2" forHTTPHeaderField:@"X-Apple-Realm-Support"];
	[request addValue:@"Find iPhone/1.1 MeKit (iPad: iPhone OS/4.2.1)" forHTTPHeaderField:@"User-agent"];
	[request addValue:@"iPad" forHTTPHeaderField:@"X-Client-Name"];
	[request addValue:@"0cf3dc501ff812adb0b202baed4f37274b210853" forHTTPHeaderField:@"X-Client-Uuid"];
	[request addValue:@"en-us" forHTTPHeaderField:@"Accept-Language"];

	NSData *userPwd = [[NSString stringWithFormat:@"%@:%@", self.username, self.password] dataUsingEncoding:NSASCIIStringEncoding];
	[request addValue:[NSString stringWithFormat:@"Basic %@", [userPwd base64EncodedString]] forHTTPHeaderField:@"Authorization"];

	GTMHTTPFetcher *fetcher = [GTMHTTPFetcher fetcherWithRequest:request];
	[fetcher setUserData:SINFO(method, [[[fetcher mutableRequest] URL] absoluteString])];
	
	return fetcher;
}

@end
