//
//  LMMmapLog.h
//  FF
//
//  Created by Lukasz Margielewski on 21/01/2015.
//
//

#import <Foundation/Foundation.h>


@interface LMMmapLog : NSObject

/**
 * Logging Primitive.
 *
 * This method is used by the macros above.
 * It is suggested you stick with the macros as they're easier to use.
 **/
@property (nonatomic, readonly) dispatch_queue_t queue;

+(void)log:( const char *) format, ...;




@end
