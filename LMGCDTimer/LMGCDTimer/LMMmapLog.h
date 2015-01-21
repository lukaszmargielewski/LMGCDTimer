//
//  LMMmapLog.h
//  FF
//
//  Created by Lukasz Margielewski on 21/01/2015.
//
//

#import <Foundation/Foundation.h>


#ifdef LMMmapLogEnabled

#define DDLogCInfo(...) DDLogCInfo(__VA_ARGS__)
#define DDLogCWarn(...) DDLogCWarn(__VA_ARGS__)
#define DDLogCError(...) DDLogCError(__VA_ARGS__)

#else

#define DDLogCInfo(...) do {} while (0)
#define DDLogCWarn(...) do {} while (0)
#define DDLogCError(...) do {} while (0)

#endif


@interface LMMmapLog : NSObject

@end
