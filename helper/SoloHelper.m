// SoloHelper: runs inside /usr/bin/perl (an Apple-signed process that mediaremoted
// still serves since macOS 15.4). Loaded via DynaLoader, never returns.
//
// stdout (JSON lines):
//   {"type":"now","bundle":"com.spotify.client","pid":123,"playing":1,"quiet":0}
//     quiet=1: state right after an override; consumers should not react to it
//   {"type":"sendto","bundle":"...","command":1,"elected":true,"restored":{"bundle":"...","ok":true}}
//   {"type":"log","msg":"..."}
// stdin (text lines):
//   send <cmd>             command to the elected now-playing app
//   sendto <bundle> <cmd>  EXPERIMENTAL: temporarily override the elected app, send, clear
//   reset                  clear any override
//   refresh                re-emit current state
// EOF on stdin -> clear override, exit.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>
#include <pthread.h>

typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef void (*GetBoolFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));
typedef NSString *(*ClientStrFn)(id);
typedef Boolean (*SendFn)(uint32_t, CFDictionaryRef);
typedef void (*SetBoolFn)(Boolean);
typedef void (*SetStrFn)(CFStringRef);

static RegisterFn MRRegister;
static GetClientFn MRGetClient;
static GetBoolFn MRGetIsPlaying;
static GetPIDFn MRGetPID;
static ClientStrFn MRClientBundle, MRClientParentBundle;
static SendFn MRSend;
static SetBoolFn MRSetOverrideEnabled;
static SetStrFn MRSetOverriddenApp;

static dispatch_queue_t workQueue;      // serializes state + commands
static dispatch_queue_t callbackQueue;  // MediaRemote replies (never blocked on)
static BOOL busy = NO;                  // suppress emits while an override is active
static NSString *lastBundle = nil;
static int lastPlaying = -1;

static void emit(NSDictionary *obj) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
  if (!data) return;
  @synchronized([NSNull null]) {
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
  }
}

static void logMsg(NSString *msg) { emit(@{@"type" : @"log", @"msg" : msg}); }

// Synchronous snapshot of the elected app. Must NOT be called on callbackQueue.
static NSDictionary *snapshot(void) {
  __block NSString *bundle = nil;
  __block Boolean playing = false;
  __block int pid = 0;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  MRGetClient(callbackQueue, ^(id client) {
    if (client) {
      NSString *parent = MRClientParentBundle ? MRClientParentBundle(client) : nil;
      bundle = parent.length ? parent : MRClientBundle(client);
    }
    dispatch_semaphore_signal(sem);
  });
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
  MRGetIsPlaying(callbackQueue, ^(Boolean p) {
    playing = p;
    dispatch_semaphore_signal(sem);
  });
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
  MRGetPID(callbackQueue, ^(int p) {
    pid = p;
    dispatch_semaphore_signal(sem);
  });
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
  return @{@"bundle" : bundle ?: [NSNull null], @"playing" : @(playing), @"pid" : @(pid)};
}

// Runs on workQueue.
static void refresh(BOOL force, BOOL quiet) {
  if (busy) return;
  NSDictionary *s = snapshot();
  id bundle = s[@"bundle"];
  if (bundle == [NSNull null]) bundle = nil;
  int playing = [s[@"playing"] boolValue] ? 1 : 0;
  if (!force && playing == lastPlaying &&
      ((bundle == nil && lastBundle == nil) || [bundle isEqual:lastBundle]))
    return;
  lastBundle = bundle;
  lastPlaying = playing;
  emit(@{@"type" : @"now", @"bundle" : bundle ?: [NSNull null], @"pid" : s[@"pid"],
         @"playing" : @(playing), @"quiet" : @(quiet)});
}

// Disabling alone leaves the overridden app elected; the app must be unset too.
static void clearOverride(void) {
  if (MRSetOverriddenApp) MRSetOverriddenApp(NULL);
  if (MRSetOverrideEnabled) MRSetOverrideEnabled(false);
}

static BOOL waitForElected(NSString *bundle) {
  for (int i = 0; i < 20; i++) {  // up to ~1s
    NSString *b = snapshot()[@"bundle"];
    if ([b isKindOfClass:NSString.class] && [b isEqualToString:bundle]) return YES;
    usleep(50 * 1000);
  }
  return NO;
}

// Runs on workQueue. The override is system-wide and persists beyond this process,
// so it is always cleared before returning.
static void sendTo(NSString *bundle, uint32_t cmd) {
  if (!MRSetOverrideEnabled || !MRSetOverriddenApp) {
    logMsg(@"sendto: override symbols missing");
    return;
  }
  busy = YES;
  id before = snapshot()[@"bundle"];
  MRSetOverrideEnabled(true);
  MRSetOverriddenApp((__bridge CFStringRef)bundle);
  BOOL elected = waitForElected(bundle);
  if (elected) {
    MRSend(cmd, NULL);
    usleep(150 * 1000);
  }
  // Clearing the override leaves the target elected. Hand the election back to the
  // app that had it, otherwise its later play/pause changes go unreported.
  BOOL restored = NO;
  if ([before isKindOfClass:NSString.class] && ![before isEqualToString:bundle]) {
    MRSetOverriddenApp((__bridge CFStringRef)before);
    restored = waitForElected(before);
  }
  clearOverride();
  usleep(150 * 1000);
  busy = NO;
  emit(@{@"type" : @"sendto", @"bundle" : bundle, @"command" : @(cmd), @"elected" : @(elected),
         @"restored" : before == [NSNull null] ? [NSNull null] : @{@"bundle" : before, @"ok" : @(restored)}});
  refresh(YES, YES);  // state after the override; not a user action
}

static void handleLine(NSString *line) {
  NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
  if (parts.count == 0) return;
  NSString *op = parts[0];
  if ([op isEqualToString:@"send"] && parts.count == 2) {
    MRSend((uint32_t)parts[1].intValue, NULL);
  } else if ([op isEqualToString:@"sendto"] && parts.count == 3) {
    sendTo(parts[1], (uint32_t)parts[2].intValue);
  } else if ([op isEqualToString:@"reset"]) {
    clearOverride();
    usleep(300 * 1000);
    refresh(YES, NO);
  } else if ([op isEqualToString:@"refresh"]) {
    refresh(YES, NO);
  } else {
    logMsg([@"unknown command: " stringByAppendingString:line]);
  }
}

static void *readStdin(void *unused) {
  char *buf = NULL;
  size_t cap = 0;
  while (getline(&buf, &cap, stdin) > 0) {
    NSString *line = [[NSString stringWithUTF8String:buf]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (line.length) dispatch_async(workQueue, ^{ handleLine(line); });
  }
  // Parent gone: never leave the override behind.
  dispatch_sync(workQueue, ^{ clearOverride(); });
  exit(0);
  return NULL;
}

static void *sym(void *h, const char *name) {
  void *p = dlsym(h, name);
  if (!p) fprintf(stderr, "SoloHelper: missing symbol %s\n", name);
  return p;
}

// Called by perl as an XSUB: void(PerlInterpreter*, CV*). Arguments are ignored.
__attribute__((visibility("default"))) void solo_helper_main(void *perl, void *cv) {
  @autoreleasepool {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) {
      fprintf(stderr, "SoloHelper: cannot load MediaRemote\n");
      exit(2);
    }
    MRRegister = sym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    MRGetClient = sym(h, "MRMediaRemoteGetNowPlayingClient");
    MRGetIsPlaying = sym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    MRGetPID = sym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
    MRClientBundle = sym(h, "MRNowPlayingClientGetBundleIdentifier");
    MRClientParentBundle = dlsym(h, "MRNowPlayingClientGetParentAppBundleIdentifier");
    MRSend = sym(h, "MRMediaRemoteSendCommand");
    MRSetOverrideEnabled = dlsym(h, "MRMediaRemoteSetNowPlayingApplicationOverrideEnabled");
    MRSetOverriddenApp = dlsym(h, "MRMediaRemoteSetOverriddenNowPlayingApplication");
    if (!MRRegister || !MRGetClient || !MRGetIsPlaying || !MRGetPID || !MRClientBundle || !MRSend)
      exit(3);

    workQueue = dispatch_queue_create("solo.work", DISPATCH_QUEUE_SERIAL);
    callbackQueue = dispatch_queue_create("solo.callbacks", DISPATCH_QUEUE_SERIAL);

    // A previous helper may have been killed mid-override.
    clearOverride();

    MRRegister(callbackQueue);
    const char *names[] = {
        "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        "kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(*names); i++) {
      CFStringRef *name = dlsym(h, names[i]);
      if (!name) continue;
      [NSNotificationCenter.defaultCenter addObserverForName:(__bridge NSString *)*name
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification *n) {
                                                    dispatch_async(workQueue, ^{ refresh(NO, NO); });
                                                  }];
    }

    // Safety net for missed notifications.
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, workQueue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(timer, ^{ refresh(NO, NO); });
    dispatch_resume(timer);

    pthread_t t;
    pthread_create(&t, NULL, readStdin, NULL);
  }
  CFRunLoopRun();
}
