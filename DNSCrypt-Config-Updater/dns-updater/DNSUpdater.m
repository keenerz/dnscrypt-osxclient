//
//  DNSUpdater.m
//  dns-updater
//
//  Created by OpenDNS, Inc. on 10/26/11.
//  Copyright (c) 2011 OpenDNS, Inc. All rights reserved.
//

#import "DNSGlobalSettings.h"
#import "DNSUpdater.h"

@implementation DNSUpdater

@synthesize state;
@synthesize wantedState;
@synthesize enableFallback;

ProxySpawner *_proxySpawner;
NSArray *resolversForLocalhost;
NSArray *resolversForOpenDNS;
NSArray *resolversList;
NSDictionary *settings;
DNSGlobalSettings *configuration;
CFHostRef hostR;
NSTimer *asyncResolutionTimer;
NSUInteger asyncResolutionFailures;

- (id) initWithProxySpawner: (ProxySpawner *) proxySpawner;
{
    if (! (self = [super init])) {
        return nil;
    }
    _proxySpawner = proxySpawner;
    state = wantedState = kDNS_CONFIGURATION_VANILLA;
    resolversForLocalhost = [NSArray arrayWithObjects: kRESOLVER_IP_LOCALHOST, nil];
    resolversForOpenDNS = [NSArray arrayWithObjects: kRESOLVER_IP_OPENDNS1, kRESOLVER_IP_OPENDNS2, nil];
    resolversList = [NSArray arrayWithObjects: resolversForLocalhost, resolversForOpenDNS, nil];
    settings = nil;
    configuration = [[DNSGlobalSettings alloc] init];
    hostR = nil;
    asyncResolutionTimer = nil;
    asyncResolutionFailures = 0U;
    enableFallback = NO;

    if ([configuration isRunningWithResolvers: resolversForLocalhost]) {
        NSLog(@"Current configuration is localhost, not vanilla");
        wantedState = state = kDNS_CONFIGURATION_LOCALHOST;
    } else if ([configuration isRunningWithResolvers: resolversForOpenDNS]) {
        NSLog(@"Current configuration is opendns, not vanilla");
        wantedState = state = kDNS_CONFIGURATION_OPENDNS;
    }
    return self;
}

- (void) update
{
    if ([configuration isRunningWithResolvers: resolversForLocalhost]) {
        if (state != kDNS_CONFIGURATION_LOCALHOST) {
            NSLog(@"Supposed state was not LOCALHOST but it actually is");
            state = kDNS_CONFIGURATION_UNKNOWN;
            wantedState = kDNS_CONFIGURATION_LOCALHOST;
            NSArray *proxyArguments = [NSArray arrayWithObjects: @"--resolver-address=" kRESOLVER_IP_DNSCRYPT, nil];
            [_proxySpawner startWithArguments: proxyArguments];
        }
    } else if ([configuration isRunningWithResolvers: resolversForOpenDNS]) {
        if (state != kDNS_CONFIGURATION_OPENDNS) {
            NSLog(@"Supposed state was not OPENDNS but it actually is");
            state = kDNS_CONFIGURATION_OPENDNS;
        }
    } else {
        if (state == kDNS_CONFIGURATION_LOCALHOST) {
            NSLog(@"Settings have been manually changed while not in vanilla mode");
        }
        state = kDNS_CONFIGURATION_VANILLA;
    }
    if (state == wantedState) {
        return;
    }

    [configuration backupExceptResolversList: resolversList];
    if (wantedState == kDNS_CONFIGURATION_VANILLA) {
        if ([configuration revertResolvers] == TRUE) {
            state = wantedState;
            NSLog(@"Back to a vanilla configuration");
        } else {
            NSLog(@"* loadSettings failed");
        }
    } else if (wantedState == kDNS_CONFIGURATION_LOCALHOST) {
        if ([configuration setResolvers: resolversForLocalhost] == TRUE) {
            state = wantedState;
            NSLog(@"Configuration switched to localhost");
        } else {
            NSLog(@"* setResolvers failed");
        }
    } else if (wantedState == kDNS_CONFIGURATION_OPENDNS) {
        if ([configuration setResolvers: resolversForOpenDNS] == TRUE) {
            state = wantedState;
            NSLog(@"Configuration switched to opendns");
        } else {
            NSLog(@"* setResolvers failed");
        }
    }
}

- (void) periodicallyUpdate
{
    [self update];
    [NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(periodicallyUpdate) object: nil];
    [self performSelector: @selector(periodicallyUpdate) withObject: nil afterDelay: kINTERVAL_BETWEEN_CONFIG_UPDATES];
}

- (void) fallback
{
    NSLog(@"Falling back to vanilla configuration");
    wantedState = kDNS_CONFIGURATION_VANILLA;
}

- (BOOL) asyncResolutionFailed
{
    asyncResolutionFailures++;
    if (asyncResolutionFailures >= kASYNC_RESOLUTION_MAX_ATTEMPTS) {
        [self fallback];
        return TRUE;
    }
    return FALSE;
}

- (void) asyncResolutionSuccess
{
    asyncResolutionFailures = 0U;
}

static void asyncResolutionDone(CFHostRef hostReplyR, CFHostInfoType typeInfo, const CFStreamError *error, void *info)
{
    DNSUpdater *self = (__bridge DNSUpdater *) info;
    [asyncResolutionTimer invalidate];
    Boolean hasBeenResolved;
    CFArrayRef addresses = CFHostGetAddressing(hostReplyR, &hasBeenResolved);
    if (hasBeenResolved == TRUE && addresses != nil) {
        NSLog(@"Test query has been resolved");
    }
    CFHostUnscheduleFromRunLoop(hostReplyR, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
    CFHostSetClient(hostReplyR, NULL, NULL);
    CFRelease(hostReplyR);
    assert(hostReplyR == hostR);
    hostR = nil;
    [self asyncResolutionSuccess];
    [self performSelector: @selector(performAsyncResolution) withObject: self afterDelay: kINTERVAL_BETWEEN_DELAYED_PROBES];
}

- (void) asyncResolutionTimeout
{
    NSLog(@"async resolution timeout");
    CFHostCancelInfoResolution(hostR, kCFHostAddresses);
    CFHostUnscheduleFromRunLoop(hostR, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
    CFHostSetClient(hostR, NULL, NULL);
    CFRelease(hostR);
    hostR = nil;
    if ([self asyncResolutionFailed] == FALSE) {
        [self performSelector: @selector(performAsyncResolution) withObject: self afterDelay: kDELAY_BETWEEN_ASYNC_RESOLUTION_ATTEMPTS];
        NSLog(@"Performing a new resolution attempt");
    }
}

- (void) performAsyncResolution
{
    if (enableFallback == NO) {
        return;
    }
    if (hostR) {
        [self performSelector: @selector(performAsyncResolution) withObject: self afterDelay: kINTERVAL_BETWEEN_ASYNC_RESOLUTION_RETRIES];
        return;
    }
    NSLog(@"Starting async resolution");
    CFHostClientContext context = { 0, (__bridge void *) self, CFRetain, CFRelease, NULL };
    CFStringRef name = (__bridge CFStringRef) kHOST_NAME_FOR_PROBES;
    hostR = CFHostCreateWithName(kCFAllocatorDefault, name);
    CFHostSetClient(hostR, asyncResolutionDone, &context);
    CFHostScheduleWithRunLoop(hostR, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
    CFStreamError error;
    CFHostStartInfoResolution(hostR, kCFHostAddresses, &error);
    asyncResolutionTimer = [NSTimer scheduledTimerWithTimeInterval: kASYNC_RESOLUTION_TIMEOUT target: self selector: @selector(asyncResolutionTimeout) userInfo: nil repeats: NO];
}

- (void) configurationChanged
{
    NSLog(@"CONFIGURATION_CHANGED notification received");
    if (enableFallback == NO) {
        return;
    }
    [self performSelector: @selector(performAsyncResolution) withObject: self afterDelay: kINTERVAL_BEFORE_ASYNC_RESOLUTION];
}

- (void) start
{
    [[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(configurationChanged) name:@"CONFIGURATION_CHANGED" object: nil];
    [self periodicallyUpdate];
}

@end
