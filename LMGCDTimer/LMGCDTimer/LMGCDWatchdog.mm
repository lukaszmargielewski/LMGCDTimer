//
//  LMGCDWatchdog.m
//  FF
//
//  Created by Lukasz Margielewski on 10/12/2014.
//
//

#import "LMGCDWatchdog.h"
#import "LMGCDTimer.h"

#include <sys/sysctl.h>
#include <sys/types.h>
#include <mach/mach.h>
#include <mach/processor_info.h>
#include <mach/mach_host.h>

#include <signal.h>
#include <pthread.h>
#include <execinfo.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#import "KSCrash.h"
///*
#import "KSMach.h"
#import "KSBacktrace.h"
#import "KSBacktrace_Private.h"
//*/
#include <map>
#include <utility>

using namespace std;

#include <mach/mach_time.h>


#define kMaxFamesSupported 128
#define kMaxThreadsSupported 30
#define kMaxLogFileSizeInBytes 1 * 1024 * 1024


static inline NSTimeInterval timeIntervalFromMach(uint64_t mach_time){
    
    mach_timebase_info_data_t info;
    
    //if (info.denom == 0) {
        (void) mach_timebase_info(&info);
    //}
    
    uint64_t nanos = mach_time * info.numer / info.denom;
    NSTimeInterval seconds = (double)nanos / NSEC_PER_SEC;
    
    return seconds;
    
}

typedef struct BacktraceStruct{

    uintptr_t backtrace[kMaxFamesSupported];
    int lenght;
    

}BacktraceStruct;

@interface LMGCDWatchdog()

@property (nonatomic) float cpuUsagePercent;
@property (nonatomic, strong) NSString *threadsStackTrace;

@end
@implementation LMGCDWatchdog{
    
    
    processor_info_array_t cpuInfo, prevCpuInfo;
    mach_msg_type_number_t numCpuInfo, numPrevCpuInfo;
    unsigned numCPUs;
    NSLock *CPUUsageLock;
    
    LMGCDTimer *_watchdogBackgoundTimer;
    
    uint64_t _time_start;
    
    dispatch_queue_t _watchdog_queue;
    BOOL _waiting_in_main_queue;
    BOOL _deadlock;
    
    map<int, BacktraceStruct>_threadsMap;
    map<int, int>_threadsStates;

    NSString        *_logFilePath;
    NSString        *_logDir;
    int             _fileDescriptor;
    
    uint64_t        _firstLogMachTime;
    NSDate          *_firstLogDate;
    NSTimeInterval  _firstLogTimeInterval;

    NSDateFormatter *_dateFormatter;
    NSDateFormatter *_dateFormatter2;
    void *backtrace[kMaxFamesSupported];
    
    NSDate *_creationDate;
    
    char queue_name[100];
    char thread_name[100];
    
    int backtraceLength;
    
    bool qn;
    bool tn;
    
    NSMutableArray *_asyncBlocks;
    NSMutableArray *_syncBlocks;
    
}
@synthesize queue = _queue;

+(instancetype)singleton{
    
    
    static dispatch_once_t pred;
    static LMGCDWatchdog *shared = nil;
    
    dispatch_once(&pred, ^{
        shared = [[LMGCDWatchdog alloc] init];
        
    });
    
    
    return shared;
}
-(void)dealloc{

    close(_fileDescriptor);
}
-(void)createQueue{
    
    // Create operation queue:
    
    if (_queue == NULL) {
        

    NSDictionary *infoDict = [[NSBundle mainBundle] infoDictionary];
    NSString *bundleId = infoDict[@"CFBundleIdentifier"];
    
    NSString *label = [NSString stringWithFormat:@"%@.LMGCDWatchdog", bundleId];
    NSUInteger maxBufferCount = sizeof(char) * (label.length + 1);
    
    char *_writeQueueLabel = (char *)malloc(maxBufferCount); // +1 for NULL termination
    
    BOOL ok = [label getCString:_writeQueueLabel maxLength:maxBufferCount encoding:NSUTF8StringEncoding];
    NSAssert(ok, @"Something wrong with LMGCDWatchdog queue label c string generation");
    
    _queue = dispatch_queue_create(_writeQueueLabel, DISPATCH_QUEUE_SERIAL);
    
    free(_writeQueueLabel);

    }
}

-(void)createWatchdogQueue{
    
    // Create operation queue:
    
    if(_watchdog_queue == NULL){
    NSDictionary *infoDict = [[NSBundle mainBundle] infoDictionary];
    NSString *bundleId = infoDict[@"CFBundleIdentifier"];
    
    NSString *label = [NSString stringWithFormat:@"%@.LMGCDWatchdog.watchdog", bundleId];
    NSUInteger maxBufferCount = sizeof(char) * (label.length + 1);
    
    char *_writeQueueLabel = (char *)malloc(maxBufferCount); // +1 for NULL termination
    
    BOOL ok = [label getCString:_writeQueueLabel maxLength:maxBufferCount encoding:NSUTF8StringEncoding];
    NSAssert(ok, @"Something wrong with LMGCDWatchdog queue label c string generation");
    
    _watchdog_queue = dispatch_queue_create(_writeQueueLabel, DISPATCH_QUEUE_SERIAL);
    
    //dispatch_set_target_queue(_watchdog_queue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
    free(_writeQueueLabel);
    }
    
}
-(void)createLogFile{

    NSFileManager *fm = [NSFileManager defaultManager];
    
    if (!_logDir) {
    
        _logDir         = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"LMCGDWatchdog"];
        
    }
    
    BOOL isDir = NO;
    
    if (![fm fileExistsAtPath:_logDir isDirectory:&isDir] || !isDir){
        
        NSError *err = nil;
        BOOL ok = [fm createDirectoryAtPath:_logDir withIntermediateDirectories:YES attributes:nil error:&err];
        if (!ok || err) {
            //DLog(@"error creating log dir: %@", err);
        }
        
    }

    
    _firstLogDate           = [NSDate date];
    _firstLogMachTime       = mach_absolute_time();
    _firstLogTimeInterval   = _firstLogDate.timeIntervalSince1970;
    
    NSString *fileName = [[_dateFormatter2 stringFromDate:_firstLogDate] stringByAppendingPathExtension:@"log"];
    _logFilePath = [_logDir stringByAppendingPathComponent:fileName];
    
    isDir = NO;
    
    if (![fm fileExistsAtPath:_logFilePath isDirectory:&isDir] || isDir) {
        
        BOOL OK = [fm createFileAtPath:_logFilePath contents:nil attributes:nil];
        if (!OK) {
            _logFilePath = nil;
        }
    }
    
    if (_logFilePath) {
        //DLog(@"created file path: %@", _logFilePath);
        close(_fileDescriptor);
        _fileDescriptor = open([_logFilePath fileSystemRepresentation], O_WRONLY | O_APPEND);
    }
}

-(id)init{
    
    self = [super init];
    
    if (self){
        
        
        int mib[2U] = { CTL_HW, HW_NCPU };
        size_t sizeOfNumCPUs = sizeof(numCPUs);
        int status = sysctl(mib, 2U, &numCPUs, &sizeOfNumCPUs, NULL, 0U);
        if(status)
            numCPUs = 1;
        
        CPUUsageLock = [[NSLock alloc] init];
    
        _dateFormatter = [[NSDateFormatter alloc] init];
        _dateFormatter.dateFormat = @"yyyy/MM/dd HH:mm:ss.SSS";
        
        _dateFormatter2 = [[NSDateFormatter alloc] init];
        _dateFormatter2.dateFormat = @"yyyy_MM_dd_HH-mm-ss";
        
        _creationDate           = [NSDate date];
        [self createQueue];
        
    }
    return self;
}


#pragma mark - Watchdog:

-(void)startWatchDog{

    
    if(_watchdogBackgoundTimer.running)return;
    
    if (!_logFilePath) {
        [self createLogFile];
    }
    
        __weak LMGCDWatchdog *weakSelf = self;
        if (!_watchdogBackgoundTimer) {
            
            
            if (_watchdog_queue == NULL) {
                [self createWatchdogQueue];
            }
            
            _watchdogBackgoundTimer = [LMGCDTimer timerWithInterval:.5 duration:0 leeway:0.1 repeat:YES startImmidiately:YES queue:_watchdog_queue block:^{
                
                [weakSelf watchdogOperation];
                
            }];
            
            _watchdogBackgoundTimer.name = @"watchdog";
        }else{
            
            _watchdogBackgoundTimer.interval = .5;
            [_watchdogBackgoundTimer resume];
        }
}
-(void)stopWatchDog{
    
        [_watchdogBackgoundTimer pause];
    
}

#pragma mark - Private:

-(void)watchdogOperation{
    
    
    if(!_waiting_in_main_queue){
    
        _waiting_in_main_queue = YES;
        _time_start = mach_absolute_time();
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            _waiting_in_main_queue = NO;
            
            if (_deadlock) {
                
                uint64_t tNow = mach_absolute_time();
                _deadlock = NO;                
                NSTimeInterval seconds = timeIntervalFromMach(tNow - _time_start);
                
                [_delegate LMGCDWatchdog:self deadlockDidFinishWithduration:seconds];
            }
        });

    }else{
    
        if (!_deadlock) {
            _deadlock = YES;
            [self ksCrashThreadInfo];
            //[self threadsInfo];
            [self cpuInfo];
            
            [_delegate LMGCDWatchdogDidDetectLongerDeadlock:self cpuUsagePercent:_cpuUsagePercent];
            
            //printf("<!");
        }

    }
    
}


#pragma mark - Info methods:
-(void)ksCrashThreadInfo{

}
-(float)cpuInfo{
    
    natural_t numCPUsU = 0U;
    kern_return_t err = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUsU, &cpuInfo, &numCpuInfo);
    if(err == KERN_SUCCESS) {
        
        [CPUUsageLock lock];
        
        float inUseAll = 0, totalAll = 0;
        
        float ticks_user;
        float ticks_syst;
        float ticks_nice;
        float ticks_idle;

        
        for(unsigned i = 0U; i < numCPUs; ++i) {
            
            float inUse, total;
            
            int cpui = (CPU_STATE_MAX * i);
            
            if(prevCpuInfo) {
                
                ticks_user = (cpuInfo[cpui + CPU_STATE_USER]    - prevCpuInfo[cpui + CPU_STATE_USER]);
                ticks_syst = (cpuInfo[cpui + CPU_STATE_SYSTEM]  - prevCpuInfo[cpui + CPU_STATE_SYSTEM]);
                ticks_nice = (cpuInfo[cpui + CPU_STATE_NICE]    - prevCpuInfo[cpui + CPU_STATE_NICE]);
                ticks_idle = (cpuInfo[cpui + CPU_STATE_IDLE]    - prevCpuInfo[cpui + CPU_STATE_IDLE]);
                
            } else {
                
                ticks_user = (cpuInfo[cpui + CPU_STATE_USER]);
                ticks_syst = (cpuInfo[cpui + CPU_STATE_SYSTEM]);
                ticks_nice = (cpuInfo[cpui + CPU_STATE_NICE]);
                ticks_idle = (cpuInfo[cpui + CPU_STATE_IDLE]);
                
            }
            
            total = (ticks_user + ticks_syst + ticks_nice + ticks_idle);
            
            inUse = (ticks_user); // Add whatever oyu choose:  + ticks_syst + ticks_nice
            
            inUseAll += inUse;
            totalAll += total;
            
        }
        
        _cpuUsagePercent = (inUseAll / totalAll) * 100.0;
        
        [CPUUsageLock unlock];
        
        if(prevCpuInfo) {
            size_t prevCpuInfoSize = sizeof(integer_t) * numPrevCpuInfo;
            vm_deallocate(mach_task_self(), (vm_address_t)prevCpuInfo, prevCpuInfoSize);
        }
        
        prevCpuInfo = cpuInfo;
        numPrevCpuInfo = numCpuInfo;
        
        cpuInfo = NULL;
        numCpuInfo = 0U;
        
        _cpuUsagePercent = (inUseAll / totalAll) * 100;

        dprintf(_fileDescriptor, "- CPU usage: %f %%\n", _cpuUsagePercent);
        
        return _cpuUsagePercent;
        
    } else {
        //DDLogCInfo(@"cpu sample error!");
    }
    

    return -1;
    
}
-(void)threadsInfo{
    
    uint64_t ts     = mach_absolute_time();
    const task_t    this_task = mach_task_self();
    const thread_t  this_thread = mach_thread_self();
    
    kern_return_t kr;
    
    thread_act_array_t threads;
    mach_msg_type_number_t thread_count;
    
    kr = task_threads(this_task, &threads, &thread_count);
    
    
    // 1. Get a list of all threads:
    
    if (kr != KERN_SUCCESS) {
        
        thread_count = 0;
        printf("error getting threads: %s", mach_error_string(kr));
    
        return;
    }

    
    for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
        
        thread_t thread = threads[i];
        
        if (this_thread == thread)continue;
        
        if((kr = thread_suspend(thread)) != KERN_SUCCESS)continue;
        
        backtraceLength = ksbt_backtraceThread(thread, (uintptr_t*)backtrace, sizeof(backtrace));

        qn = ksmach_getThreadQueueName(thread, queue_name, 100);
        tn = ksmach_getThreadName(thread, thread_name, 100);
    
        dprintf(_fileDescriptor, "\n*   %i thread %i (%s) queue: %s\n", i, thread, thread_name, queue_name);
        backtrace_symbols_fd(backtrace, backtraceLength, _fileDescriptor);
    
        if((kr = thread_resume(thread)) != KERN_SUCCESS){}
        
        mach_port_deallocate(this_task, thread);
    }
    
    uint64_t dt = ts - _firstLogMachTime;
    double dt_sec = timeIntervalFromMach(dt);
    time_t raw_time = _firstLogTimeInterval + dt_sec;
    
    dprintf(_fileDescriptor, "-------------------\n- time: %s-------------------\n", ctime(&raw_time));
    //printf("\n -- %s --- (%llu / %f sec) \n", ctime(&raw_time), dt, dt_sec);
    
    
    mach_port_deallocate(this_task, this_thread);
    vm_deallocate(this_task, (vm_address_t)threads, sizeof(thread_t) * thread_count);

    uint64_t te     = mach_absolute_time();
    //dprintf(_fileDescriptor, "\n---------\n- time: %s\n---------\n\n", ctime(&raw_time));
    printf("\nthread info cycles: %llu / time: %f sec\n", te - ts, timeIntervalFromMach(te - ts));
    
    off_t file_size = lseek(_fileDescriptor, 0, SEEK_END);
    
    if (file_size > kMaxLogFileSizeInBytes) {
        [self createLogFile];
        [self getLogFilesBeforeCreation];
    }
}

-(BOOL)threadsAnalytics{
    
    /* Threads */
    
    uint64_t ts     = mach_absolute_time();
    const task_t    this_task = mach_task_self();
    const thread_t  this_thread = mach_thread_self();
    
    kern_return_t kr;
    
    thread_act_array_t threads;
    mach_msg_type_number_t thread_count;
    
    kr = task_threads(this_task, &threads, &thread_count);
    
    
    // 1. Get a list of all threads:
    
    if (kr != KERN_SUCCESS) {
        printf("error getting threads: %s", mach_error_string(kr));
        return NO;
    }
    
    // 2. Get callstacks of all threads but not this:
    
    for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
        
        thread_t thread = threads[i];
        
        if (this_thread == thread)continue;
        
        thread_info_data_t     thinfo;
        mach_msg_type_number_t thread_info_count;
        thread_info_count = THREAD_INFO_MAX;
        
        kr = thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)thinfo, &thread_info_count);
        if(kr != KERN_SUCCESS)continue;
           
        thread_basic_info_t basic_info_th;
        basic_info_th = (thread_basic_info_t)thinfo;
        
        if((kr = thread_suspend(thread)) != KERN_SUCCESS)continue;
        
        BacktraceStruct bs;
        bs.lenght = ksbt_backtraceThread(thread, (uintptr_t* const)bs.backtrace, sizeof(bs.backtrace));
        
        if((kr = thread_resume(thread)) != KERN_SUCCESS){}

        
        
        BacktraceStruct bsPrev = _threadsMap[thread];
        
        int c = MIN(bsPrev.lenght, bs.lenght);
        
        //printf("\nthread: %i \n", thread);
        if (c > 0) {
          
            // Prev:
            for(int a = 0; a < bsPrev.lenght; a++){
            
                uintptr_t pointer_prev = bsPrev.backtrace[a];
                //printf("%lu ", pointer_prev);
                
            }
            
            //printf("\n");
            //char** strs = backtrace_symbols((void * const *)(bsPrev.backtrace), bsPrev.lenght);
            
            for(int a = 0; a < bsPrev.lenght; ++a) {
                //if(bsPrev.backtrace[a])
                   // printf("%s\n", strs[a]);
            }
            //free(strs);
            
            // This:
            
            //printf("\n");
            for(int a = 0; a < bs.lenght; a++){
                
                uintptr_t pointer_this = bs.backtrace[a];
                //printf("%lu ", pointer_this);
            }
            
            //printf("\n");
            //strs = backtrace_symbols((void * const *)(bs.backtrace), bs.lenght);
            
            for(int a = 0; a < bs.lenght; ++a) {
                //if(bs.backtrace[a])
                    //printf("%s\n", strs[a]);
            }
            //free(strs);
            
            //printf("\n");
            
            if (bs.lenght != bsPrev.lenght) {
                //printf("\n diffrence!!! \n");
            }
            
        }
        
        //CFDictionarySetValue(_threadsDict, (void *)thread, (void *)&bs);
        
        _threadsMap[thread] = bs;
        
        mach_port_deallocate(this_task, thread);
    }

    
    //printf("\n *************** \n");
    
    mach_port_deallocate(this_task, this_thread);
    vm_deallocate(this_task, (vm_address_t)threads, sizeof(thread_t) * thread_count);
    
    uint64_t te = mach_absolute_time();
    
    printf("\n analytics sec: %f (%llu)" , timeIntervalFromMach(te - ts), te - ts);
    return NO;
}
-(BOOL)threadsAnalyticsSimple{
    
    /* Threads */
    
    uint64_t ts     = mach_absolute_time();
    const task_t    this_task = mach_task_self();
    const thread_t  this_thread = mach_thread_self();
    
    kern_return_t kr;
    
    thread_act_array_t threads;
    mach_msg_type_number_t thread_count;
    
    kr = task_threads(this_task, &threads, &thread_count);
    
    
    // 1. Get a list of all threads:
    
    if (kr != KERN_SUCCESS) {
        printf("error getting threads: %s", mach_error_string(kr));
        return NO;
    }
    
    // 2. Get callstacks of all threads but not this:
    
    for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
        
        thread_t thread = threads[i];
        
        if (this_thread == thread)continue;
        
        thread_info_data_t     thinfo;
        mach_msg_type_number_t thread_info_count = THREAD_INFO_MAX;
        
        kr = thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)thinfo, &thread_info_count);
        if(kr != KERN_SUCCESS)continue;
        
        thread_basic_info_t basic_info_th = (thread_basic_info_t)thinfo;
        integer_t run_state = basic_info_th->run_state;
        
        /*
        
        arm_unified_thread_state state;
        mach_msg_type_number_t state_count = ARM_UNIFIED_THREAD_STATE_COUNT;
        kr = thread_get_state(thread, ARM_UNIFIED_THREAD_STATE, (thread_state_t) &state, &state_count);

        */
        /*
        STRUCT_MCONTEXT_L machineContext;
        
        if(!ksmach_threadState(thread, &machineContext))
        {
            return 0;
        }
        */

        if (run_state != _threadsStates[thread]) {
            
            char const *sss;
            char const *pref;
            switch (run_state) {
                case TH_STATE_RUNNING:
                {
                    
                    sss = "running";
                    pref = "--- > ";
                }
                    break;
                case TH_STATE_STOPPED:
                {
                
                    sss = "stopped";
                    pref = "--- < ";
                }
                    
                    break;
                case TH_STATE_WAITING:
                {
                
                    sss = "waiting";
                    pref = "--- < ";
                
                }
                    //printf("\nthread %u is TH_STATE_WAITING", thread);
                    break;
                case TH_STATE_UNINTERRUPTIBLE:
                {
                    sss = "TH_STATE_UNINTERRUPTIBLE";
                    pref = "--- ! ";
                }
                    //printf("\nthread %u is TH_STATE_UNINTERRUPTIBLE", thread);
                    break;
                case TH_STATE_HALTED:
                    //printf("\nthread %u is TH_STATE_HALTED", thread);
                    sss = "halted";
                    pref = "--- # ";
                    break;
                default:
                    sss  = "unknown";
                    pref = "--- ? ";
                    break;
            }
            
            char queue_name[100];
            char thread_name[100];
            
            //bool qn = ksmach_getThreadQueueName(thread, queue_name, 100);
            //bool tn = ksmach_getThreadName(thread, thread_name, 100);
            
            NSString *aaa = [NSString stringWithFormat:@" %s thread %u (name: %s) (queue: %s) is %s | threads: %i", pref, thread, thread_name, queue_name, sss, thread_count];
            
        
            //printf("\n --- thread %u (name: %s) (queue: %s) is %s", thread, thread_name, queue_name, sss);
            [_delegate LMGCDWatchdog:self didDetectThreadStateChange:aaa];
        }
        
        
        
        _threadsStates[thread] = run_state;
        
        
        mach_port_deallocate(this_task, thread);
    }
    
    
    //printf("\n *************** \n");
    
    mach_port_deallocate(this_task, this_thread);
    vm_deallocate(this_task, (vm_address_t)threads, sizeof(thread_t) * thread_count);
    
    uint64_t te = mach_absolute_time();
    
    //printf("\n analytics sec: %f (%llu)\n\n" , timeIntervalFromMach(te - ts), te - ts);
    return NO;
}


#pragma mark - Log files:

-(NSArray *)getAllLogFilesSorted{
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    NSError *err = nil;
    NSArray *fff = [self getALlLogFiles];
    
    fff = [fff sortedArrayUsingComparator:^NSComparisonResult(NSString *path1, NSString *path2){
    
        NSError *err = nil;
        NSDictionary *attributes1 = [fileManager attributesOfItemAtPath:path1 error:&err];
        NSDictionary *attributes2 = [fileManager attributesOfItemAtPath:path2 error:&err];
        
        if (attributes1 && attributes2) {
            
            NSDate *date1 = [attributes1 fileCreationDate];
            NSDate *date2 = [attributes2 fileCreationDate];
            
            if (date1 && date2) {
                
                return  [date1 compare:date2];
            }
        }
        
        return NSOrderedSame;
        
    }];
    
    //DLog(@"all log files sorted(%lu): %@", fff.count, fff);
    return fff;
}


-(NSArray *)getALlLogFiles{

    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    NSError *err = nil;
    NSArray *fff = [fileManager contentsOfDirectoryAtPath:_logDir error:&err];
    fff =  [fff filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"pathExtension = 'log'"]];
    NSMutableArray *results = [[NSMutableArray alloc] initWithCapacity:fff.count];
    
    for (NSString *fileName in fff) {
        
        NSString *aPath = [_logDir stringByAppendingPathComponent:fileName];
        
        if (_logFilePath && [_logFilePath isEqualToString:aPath]) {
            continue;
        }

        [results addObject:aPath];
    }
    
     //DLog(@"all log files (%lu): %@", results.count, results);
    return results;
}
-(NSArray *)getLogFilesBeforeCreation{

    NSArray *all = [self getALlLogFiles];
    
    NSMutableArray *results = [[NSMutableArray alloc] initWithCapacity:all.count];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    //DLog(@"all log files (%lu): %@", all.count, all);
    
    for (NSString *filePath in all) {
        
        NSError *err = nil;
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:filePath
                                                                 error:&err];
        
        if (attributes) {
        
            NSDate *date = [attributes fileCreationDate];
            
            if (date && [date compare:_creationDate] == NSOrderedAscending) {
                [results addObject:filePath];
            }
        }
        
        
    }
    //DLog(@"bef log files (%lu): %@", (unsigned long)results.count, results);
    
    return results;
}

-(void)deleteOldLogFiles{

    close(_fileDescriptor);
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    NSArray *allToDelete = [self getALlLogFiles];
    
    for(NSString *filePath in allToDelete){
    
        if (_logFilePath && [_logFilePath isEqualToString:filePath]) {
            continue;
        }
        
        NSError *error = nil;
        [fileManager removeItemAtPath:filePath error:&error];
    }
    
    [self createLogFile];
}


+(void)addAsyncBlockName:(NSString *)blockName{

    [[LMGCDWatchdog singleton] addAsyncBlockName:blockName];

}
+(void)removeAsyncBlockName:(NSString *)blockName{

    [[LMGCDWatchdog singleton] removeAsyncBlockName:blockName];
}

+(void)addSyncBlockName:(NSString *)blockName{

    [[LMGCDWatchdog singleton] addSyncBlockName:blockName];
}
+(void)removeSyncBlockName:(NSString *)blockName{

    [[LMGCDWatchdog singleton] removeSyncBlockName:blockName];
    
}



-(void)addAsyncBlockName:(NSString *)blockName{
    
    if(!_asyncBlocks)
        _asyncBlocks = [[NSMutableArray alloc] initWithCapacity:50];
    
    //NSLog(@"async start: %@", blockName);
    
    [_asyncBlocks addObject:blockName];
}
-(void)removeAsyncBlockName:(NSString *)blockName{
    
    [_asyncBlocks removeObject:blockName];
    //NSLog(@"async end: %@", blockName);
}

-(void)addSyncBlockName:(NSString *)blockName{
    
    //NSLog(@"sync start: %@", blockName);
    [_syncBlocks addObject:blockName];
}
-(void)removeSyncBlockName:(NSString *)blockName{
    
    [_syncBlocks removeObject:blockName];
    //NSLog(@"sync end: %@", blockName);
}


@end



