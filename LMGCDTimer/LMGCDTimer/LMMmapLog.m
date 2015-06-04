//
//  LMMmapLog.m
//  FF
//
//  Created by Lukasz Margielewski on 21/01/2015.
//
//

#import "LMMmapLog.h"
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <string.h>
#include <mach/mach_time.h>


static const char* log_chars = "0123456789 :./";

#define kSpaceIndex     11
#define kColonIndex     12
#define kDotIndex       13
#define kSlashIndex     14

#define kMapSizeDefault 1024 // 1 Kb

static inline NSTimeInterval timeIntervalFromMach(uint64_t mach_time){
    
    mach_timebase_info_data_t info;
    
    //if (info.denom == 0) {
    (void) mach_timebase_info(&info);
    //}
    
    uint64_t nanos = mach_time * info.numer / info.denom;
    NSTimeInterval seconds = (double)nanos / NSEC_PER_SEC;
    
    return seconds;
    
}


@implementation LMMmapLog{

    uint64_t        _firstLogMachTime;
    NSDate          *_firstLogDate;
    NSTimeInterval  _firstLogTimeInterval;
    
    NSString        *_logFilePath;
    NSString        *_logDir;
    
    int _fileDescriptor;
    
    char    *map;
    size_t mapsize;
    size_t mappower2;
    size_t mappower2_1;
    size_t mapoffset;
    
    char *time_format;
    
    int start_yy;
    int start_mo;
    int start_dd;
    int start_hh;
    int start_mi;
    int start_se;
    int start_ms;
    
    NSDateFormatter *_dateFormatter;
}
@synthesize queue = _queue;

+(instancetype)singleton{
    
    
    static dispatch_once_t pred;
    static LMMmapLog *shared = nil;
    
    dispatch_once(&pred, ^{
        shared = [[LMMmapLog alloc] init];
        
    });
    
    
    return shared;
}


-(id)init{

    self = [super init];
    
    if (self) {
        
        [self commonInit];
    }
    return self;
}
-(void)commonInit{

    [self createQueue];
    
     NSFileManager *fm = [NSFileManager defaultManager];
    
    _logDir         = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"LMMapLog"];
    
    BOOL isDir = NO;
    
    if (![fm fileExistsAtPath:_logDir isDirectory:&isDir] || !isDir){
    
        NSError *err = nil;
        BOOL ok = [fm createDirectoryAtPath:_logDir withIntermediateDirectories:YES attributes:nil error:&err];
        if (!ok || err) {
            NSLog(@"erro creating log dir: %@", err);
        }
    
    }
    _logFilePath    = [_logDir stringByAppendingPathComponent:@"logs.txt"];
    
    time_format = malloc(sizeof(char) * 25);
    
    _dateFormatter = [[NSDateFormatter alloc] init];
    _dateFormatter.dateFormat = @"yyyy/MM/dd HH:mm:ss.SSS  ";
    

    isDir = NO;
    
    if (![fm fileExistsAtPath:_logFilePath isDirectory:&isDir] || isDir) {
        
        BOOL OK = [fm createFileAtPath:_logFilePath contents:nil attributes:nil];
        if (!OK) {
            _logFilePath = nil;
        }
    }
}

-(void)dealloc{
 
    [self unmap];

    free(time_format);
}
-(void)unmap{

    // Write it now to disk
    if (msync(map, mapoffset, MS_SYNC) == -1)
    {
        perror("Could not sync the file to disk");
    }

    
    // Don't forget to free the mmapped memory
    if (munmap(map, mapoffset) == -1)
    {
        close(_fileDescriptor);
        perror("Error un-mmapping the file");
        exit(EXIT_FAILURE);
    }
    
    // Un-mmaping doesn't close the file, so we still need to do that.
    close(_fileDescriptor);
}
-(BOOL)firstTimeLog{

    if (_firstLogDate == nil) {
        
        size_t pagesize         = sysconf(_SC_PAGESIZE);
        uint32_t pagescount = (ceil((double)kMapSizeDefault / (double)pagesize));
        mapsize                 = pagescount * pagesize;
        
        // From: http://stackoverflow.com/a/27915457/229229
        // And: http://graphics.stanford.edu/~seander/bithacks.html#RoundUpPowerOf2
        
        
        /*
         
         We know that for example modulo of power of two can be expressed like this:
         
         x % 2 inpower n == x & (2 inpower n - 1).
         Examples:
         
         x % 2 == x & 1
         x % 4 == x & 3
         x % 8 == x & 7
         
         */
        
        mappower2 = 1;
        while(mappower2 < mapsize)
            mappower2*=2;
        
        if (mappower2 > mapsize) {
            mappower2 /= 2;
        }
        
        mappower2_1 = mappower2 - 1;

        printf("initializing map size: %li (power 2 low: %li) offset: %zu at path: %s\n", mapsize, mappower2_1, mapoffset, [_logFilePath fileSystemRepresentation]);
        printf("def size: %i, pagesize: %li, pages count: %u mapsize: %li\n", kMapSizeDefault, pagesize, pagescount, mapsize);
        
        
        /* Open a file for writing.
         *  - Creating the file if it doesn't exist.
         *  - Truncating it to 0 size if it already exists. (not really needed)
         *
         * Note: "O_WRONLY" mode is not sufficient when mmaping.
         */
        
        _fileDescriptor = open([_logFilePath fileSystemRepresentation], O_RDWR | O_CREAT , (mode_t)0600);
        
        if (_fileDescriptor == -1)
        {
            printf("Error opening file for writing: %s", [_logFilePath fileSystemRepresentation]);
            mapoffset = 0;
            return NO;
        }
        

        size_t fileSize = mapsize * sizeof(char);
        
        /* Stretch the file size to the size of the (mmapped) array of ints
         */
        off_t result = lseek(_fileDescriptor, fileSize-1, SEEK_SET);
        if (result == -1) {
            close(_fileDescriptor);
            perror("Error calling lseek() to 'stretch' the file");
            return NO;
        }
        
        /* Something needs to be written at the end of the file to
         * have the file actually have the new size.
         * Just writing an empty string at the current file position will do.
         *
         * Note:
         *  - The current position in the file is at the end of the stretched
         *    file due to the call to lseek().
         *  - An empty string is actually a single '\0' character, so a zero-byte
         *    will be written at the last byte of the file.
         */
        result = write(_fileDescriptor, "", 1);
        if (result != 1) {
            close(_fileDescriptor);
            perror("Error writing last byte of the file");
            return NO;
        }
        
        /* Now the file is ready to be mmapped.
         */
        map = mmap(0, fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, _fileDescriptor, 0);
        if (map == MAP_FAILED) {
            close(_fileDescriptor);
            perror("Error mmapping the file");
            return NO;
        }
        
        
        
        
        _firstLogDate           = [NSDate date];
        _firstLogTimeInterval   = _firstLogDate.timeIntervalSince1970;
        _firstLogMachTime       = mach_absolute_time();
        
        printf("initialized map size: %li (power 2 low: %li) offset: %zu at path: %s", mapsize, mappower2_1, mapoffset, [_logFilePath fileSystemRepresentation]);
        
    }
    
    return YES;
    
}

-(void)createQueue{
    
    // Create operation queue:
    
    if (_queue == NULL) {
        
        
        NSDictionary *infoDict = [[NSBundle mainBundle] infoDictionary];
        NSString *bundleId = infoDict[@"CFBundleIdentifier"];
        
        NSString *label = [NSString stringWithFormat:@"%@.LMMmapLog", bundleId];
        NSUInteger maxBufferCount = sizeof(char) * (label.length + 1);
        
        char *_writeQueueLabel = (char *)malloc(maxBufferCount); // +1 for NULL termination
        
        BOOL ok = [label getCString:_writeQueueLabel maxLength:maxBufferCount encoding:NSUTF8StringEncoding];
        NSAssert(ok, @"Something wrong with LMMmapLog queue label c string generation");
        
        _queue = dispatch_queue_create(_writeQueueLabel, DISPATCH_QUEUE_SERIAL);
        
        free(_writeQueueLabel);
        
    }
}


+(void)log:( const char *) format, ...{

    [[LMMmapLog singleton] log:format];
}

-(void)log:( const char *) text{

    
    //text = "Decimals: %d %ld\n", 1977, 650000L;
    
    uint64_t tss = mach_absolute_time();
    
    dispatch_async(_queue, ^{
    
         uint64_t ts = mach_absolute_time();
        
        if (!_firstLogDate)[self firstTimeLog];

        uint64_t ts1 = mach_absolute_time();
        uint64_t    dt      = _firstLogMachTime - tss;
        double      dt_sec  = timeIntervalFromMach(dt);

        size_t textIndexDate = 0;
        size_t textIndex = 0;
        
        size_t offset_before = mapoffset;
        
        /*
        uint64_t ts2 = mach_absolute_time();
        NSDate *date = [_firstLogDate dateByAddingTimeInterval:dt_sec];
        const char *dddd = [[_dateFormatter stringFromDate:date] UTF8String];
        uint64_t ts3 = mach_absolute_time();
        
        
        
        
        
        map[mapoffset] = '\n';
        mapoffset++;
        
        while ((map[mapoffset] = dddd[textIndexDate])) {
            
            textIndexDate++;
            mapoffset++;
            mapoffset &= mappower2_1;
        }
        
        */
        
        while ((map[mapoffset] = text[textIndex])) {
            
            textIndex++;
            mapoffset++;
            mapoffset &= mappower2_1;
        }
        

        size_t totalCharsWritten = textIndex + textIndexDate + 1; // +1 for newline char (above):
        size_t end_no_wrap = offset_before + totalCharsWritten;
        
        if (end_no_wrap >= mapsize) { // module ocured (was wrapped around)
            
            // Write it now to disk
            if (msync(&map[offset_before], mapsize - offset_before, MS_ASYNC) == -1)
            {
                perror("Could not sync the file to disk 1");
            }
            
            if (msync(map, mapoffset, MS_ASYNC) == -1)
            {
                perror("Could not sync the file to disk 2");
            }
            
            
        }else{
        
            // Write it now to disk
            if (msync(&map[offset_before], totalCharsWritten, MS_ASYNC) == -1)
            {
                perror("Could not sync the file to disk 3");
            }
        }
        
        
        
        uint64_t te = mach_absolute_time();
        uint64_t cpu_cycles = te - ts1;
        //uint64_t dC = ts3 - ts2;
        
        //double ppp = ((double)dC / (double)cpu_cycles) * 100.0;
        
        printf("\nwrite cycles: %lli (%f sec) for text '%s'\n", cpu_cycles, timeIntervalFromMach(cpu_cycles), text);
        //printf("\nwrite cycles: %lli (%f sec) for text '%s'| date form cycles: %lli (%.2f%%)\n", cpu_cycles, timeIntervalFromMach(cpu_cycles),  text, dC, ppp);
        
    });
}

@end
